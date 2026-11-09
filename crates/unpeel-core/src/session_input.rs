//! Safe text delivery into hosted agent terminals.
//!
//! This is the single implementation of the bracketed-paste + settle +
//! double-Enter recipe used by Sessions MCP, secure remote input, and typed
//! Host actions such as screenshot requests. UI clients send semantic actions;
//! they never construct terminal escape sequences themselves.

use crate::session_host::{self, SessionHostCommand, WriteOrigin, DRAFT_ERROR, TYPED_SINCE_ERROR};
use std::thread;
use std::time::Duration;

/// Delay between pasting text and pressing Enter so agent TUIs finish
/// processing the bracketed paste.
pub const TEXT_SETTLE_DELAY_MS: u64 = 250;
/// Longer settle when pasted text contains file paths, which some TUIs attach
/// asynchronously before the prompt can be submitted.
pub const TEXT_SETTLE_DELAY_PATH_MS: u64 = 900;
/// Some full-screen agent TUIs swallow the first Enter after a paste.
pub const ENTER_FOLLOWUP_DELAY_MS: u64 = 80;

/// Provider-neutral request used by every Host implementation.
pub const SCREENSHOT_REQUEST_PROMPT: &str = "Please capture the current visual result with the Unpeel Browser tool's screenshot action, setting gallery to true so it is saved as a screenshot artifact in this session's gallery. If this task has no visual result, say so instead.";

pub fn sanitize_paste_text(text: &str) -> String {
    text.replace("\r\n", "\n")
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .collect()
}

pub fn encode_bracketed_paste(text: &str) -> String {
    format!("\x1b[200~{text}\x1b[201~")
}

pub fn looks_like_it_contains_a_path(text: &str) -> bool {
    text.split_whitespace()
        .any(|word| word.len() > 1 && word.contains('/'))
}

/// Fork-only (#61): keys this recent mean the user is at the keyboard. The
/// Inbox's quiet window for typing is the same.
pub const TYPING_QUIET_MS: u64 = 3_000;

/// Fork-only (#61): where the "is typing" window starts for a send at `now`.
/// The manifest's `last_input_at` can lag a key by up to ~2.5 s, so the send
/// asks the PTY core, which sees the key at once, with this as its
/// `unless_typed_since`.
pub fn typing_window_start(now: u64) -> u64 {
    now.saturating_sub(TYPING_QUIET_MS)
}

/// Fork-only (#61): why the PTY core refused a guarded write.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The user typed within the window: they are at the keyboard.
    Typing,
    /// The input line holds what the user typed and has not sent.
    Draft,
}

impl Refusal {
    fn from_core_error(error: &str) -> Option<Self> {
        match error {
            TYPED_SINCE_ERROR => Some(Self::Typing),
            DRAFT_ERROR => Some(Self::Draft),
            _ => None,
        }
    }

    /// The word and the next step an agent's result gives its caller.
    pub fn explain(&self, session_id: &str) -> String {
        match self {
            Self::Typing => format!(
                "Not sent (typing): the user typed in session {session_id} within the last \
{} s. Nothing was written. Send again once they have stopped.",
                TYPING_QUIET_MS / 1_000
            ),
            Self::Draft => format!(
                "Not sent (draft): session {session_id} has input the user typed and has not \
sent. Nothing was written. Look at it with read_screen, and send again once they have sent or \
cleared it. Ask them if it stays."
            ),
        }
    }
}

/// Fork-only (#38): who a write speaks for, its socket timeout, and the
/// guards that refuse it because of the user's typing.
#[derive(Debug, Clone, Copy)]
struct WriteTerms {
    origin: WriteOrigin,
    timeout: Option<Duration>,
    unless_typed_since: Option<u64>,
    unless_draft: bool,
}

impl WriteTerms {
    fn program(timeout: Option<Duration>) -> Self {
        Self {
            origin: WriteOrigin::Program,
            timeout,
            unless_typed_since: None,
            unless_draft: false,
        }
    }

    /// Fork-only (#61): an agent's write, refused while the user is typing
    /// since `since` or has a draft on the line.
    fn guarded(since: u64) -> Self {
        Self {
            unless_typed_since: Some(since),
            unless_draft: true,
            ..Self::program(None)
        }
    }
}

/// `Ok(Some(_))`: the session host refused the write because of the user's
/// typing (fork-only, #38, #61).
fn write_to_session(
    session_id: &str,
    data: &str,
    terms: WriteTerms,
) -> Result<Option<Refusal>, String> {
    let command = SessionHostCommand::Write {
        data: data.to_string(),
        write_id: None,
        origin: terms.origin,
        unless_typed_since: terms.unless_typed_since,
        unless_draft: terms.unless_draft,
    };
    let sent = match terms.timeout {
        Some(timeout) => session_host::send_command_with_timeout(session_id, &command, timeout),
        None => session_host::send_command(session_id, &command),
    };
    match sent {
        Ok(()) => Ok(None),
        Err(error) => Refusal::from_core_error(&error).map(Some).ok_or(error),
    }
}

/// Deliver already-sanitized text through the terminal prompt recipe.
/// Callers are responsible for their own authorization/write gate.
pub fn deliver_sanitized_text(
    session_id: &str,
    sanitized: &str,
    submit: bool,
) -> Result<(), String> {
    deliver_sanitized_text_with_timeout(session_id, sanitized, submit, WriteTerms::program(None))
        .map(|_| ())
}

/// Fork-only (#38): text the user typed elsewhere (the phone's text box);
/// it counts as their typing in the session.
pub fn deliver_sanitized_text_as_user(
    session_id: &str,
    sanitized: &str,
    submit: bool,
) -> Result<(), String> {
    let terms = WriteTerms {
        origin: WriteOrigin::User,
        ..WriteTerms::program(None)
    };
    deliver_sanitized_text_with_timeout(session_id, sanitized, submit, terms).map(|_| ())
}

/// Fork-only (#38): how a guarded paste went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardedPaste {
    Submitted,
    /// The user typed before the paste: nothing was written.
    NotPasted(Refusal),
    /// The user typed after the paste: it waits on the line, unsubmitted.
    NotSubmitted,
}

/// Fork-only (#38): the Inbox's paste. The same recipe, but the session
/// host refuses each write once the user has typed at or after `since`, so
/// a half-typed prompt is never submitted with the paste. A host that
/// predates the guard writes everything ([`GuardedPaste::Submitted`]).
pub fn paste_unless_typed(
    session_id: &str,
    sanitized: &str,
    since: u64,
    timeout: Duration,
) -> Result<GuardedPaste, String> {
    let terms = WriteTerms {
        unless_typed_since: Some(since),
        ..WriteTerms::program(Some(timeout))
    };
    deliver_sanitized_text_with_timeout(session_id, sanitized, true, terms)
}

/// Fork-only (#61): an agent's `send_text`. The PTY core refuses it, with
/// nothing written, while the user is typing or has a draft on the line. It
/// asks the core rather than reading the screen first, so nothing can slip in
/// between a look and the write. A host that predates a guard writes anyway.
pub fn paste_unless_user_is_typing(
    session_id: &str,
    sanitized: &str,
    submit: bool,
) -> Result<GuardedPaste, String> {
    let terms = WriteTerms::guarded(typing_window_start(crate::state::current_timestamp_ms()));
    deliver_sanitized_text_with_timeout(session_id, sanitized, submit, terms)
}

/// Fork-only (#61): one key of an agent's `send_keys`, under the same guards.
/// A menu takes the keys, so a draft under one does not refuse them. `since`
/// comes from [`typing_window_start`] once per call, so the user's first key
/// stops the rest of the sequence.
pub fn write_key_unless_user_is_typing(
    session_id: &str,
    sequence: &str,
    since: u64,
) -> Result<Option<Refusal>, String> {
    write_to_session(session_id, sequence, WriteTerms::guarded(since))
}

fn deliver_sanitized_text_with_timeout(
    session_id: &str,
    sanitized: &str,
    submit: bool,
    terms: WriteTerms,
) -> Result<GuardedPaste, String> {
    paste_recipe(sanitized, submit, |data| {
        write_to_session(session_id, data, terms)
    })
}

/// The bracketed paste, a settle, then Enter twice. Fork-only (#38):
/// `write` answers `Ok(Some(_))` when the session host refused it.
fn paste_recipe(
    sanitized: &str,
    submit: bool,
    mut write: impl FnMut(&str) -> Result<Option<Refusal>, String>,
) -> Result<GuardedPaste, String> {
    if !sanitized.is_empty() {
        if let Some(refusal) = write(&encode_bracketed_paste(sanitized))? {
            return Ok(GuardedPaste::NotPasted(refusal));
        }
    }
    if submit {
        let settle = if looks_like_it_contains_a_path(sanitized) {
            TEXT_SETTLE_DELAY_PATH_MS
        } else {
            TEXT_SETTLE_DELAY_MS
        };
        thread::sleep(Duration::from_millis(settle));
        if let Some(refusal) = write("\r")? {
            return Ok(if sanitized.is_empty() {
                GuardedPaste::NotPasted(refusal)
            } else {
                GuardedPaste::NotSubmitted
            });
        }
        thread::sleep(Duration::from_millis(ENTER_FOLLOWUP_DELAY_MS));
        // The first Enter submitted the paste; a refused second one only
        // keeps the user's new keys from being submitted too.
        write("\r")?;
    }
    Ok(GuardedPaste::Submitted)
}

/// Sanitize and submit one user-visible prompt to a hosted session.
pub fn deliver_prompt(session_id: &str, text: &str) -> Result<(), String> {
    let sanitized = sanitize_paste_text(text);
    if sanitized.trim().is_empty() {
        return Err("prompt is empty after removing control characters".into());
    }
    deliver_sanitized_text(session_id, &sanitized, true)
}

pub fn request_screenshot(session_id: &str) -> Result<(), String> {
    request_screenshot_with_optional_timeout(session_id, None)
}

/// Remote request variant: each control-socket round trip is bounded so a
/// wedged session Host cannot pin an HTTP/Relay/FFI worker indefinitely.
pub fn request_screenshot_with_timeout(session_id: &str, timeout: Duration) -> Result<(), String> {
    request_screenshot_with_optional_timeout(session_id, Some(timeout))
}

fn request_screenshot_with_optional_timeout(
    session_id: &str,
    timeout: Option<Duration>,
) -> Result<(), String> {
    if session_id.is_empty()
        || session_id.contains('/')
        || session_id.contains("..")
        || session_id.contains('\\')
    {
        return Err("invalid session id".into());
    }
    let sanitized = sanitize_paste_text(SCREENSHOT_REQUEST_PROMPT);
    deliver_sanitized_text_with_timeout(session_id, &sanitized, true, WriteTerms::program(timeout))
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_is_provider_neutral_and_names_the_artifact_contract() {
        assert!(SCREENSHOT_REQUEST_PROMPT.contains("Unpeel Browser tool"));
        assert!(SCREENSHOT_REQUEST_PROMPT.contains("screenshot artifact"));
        assert!(!SCREENSHOT_REQUEST_PROMPT.contains("Claude"));
        assert!(!SCREENSHOT_REQUEST_PROMPT.contains("Codex"));
    }

    /// The recipe against a session host that refuses every write after
    /// the first `allowed`.
    fn paste_with_refusals_after(allowed: usize) -> (Result<GuardedPaste, String>, Vec<String>) {
        recipe_with_refusals_after("batch", allowed, Refusal::Typing)
    }

    fn recipe_with_refusals_after(
        text: &str,
        allowed: usize,
        refusal: Refusal,
    ) -> (Result<GuardedPaste, String>, Vec<String>) {
        let mut written = Vec::new();
        let result = paste_recipe(text, true, |data| {
            if written.len() >= allowed {
                return Ok(Some(refusal));
            }
            written.push(data.to_owned());
            Ok(None)
        });
        (result, written)
    }

    #[test]
    fn the_refusal_says_why_nothing_was_written() {
        let (result, written) = recipe_with_refusals_after("batch", 0, Refusal::Draft);
        assert_eq!(result, Ok(GuardedPaste::NotPasted(Refusal::Draft)));
        assert!(written.is_empty());
        // A bare Enter on someone's draft: nothing was pasted either.
        let (result, written) = recipe_with_refusals_after("", 0, Refusal::Draft);
        assert_eq!(result, Ok(GuardedPaste::NotPasted(Refusal::Draft)));
        assert!(written.is_empty());
    }

    #[test]
    fn refusals_name_a_stable_word_and_what_to_do() {
        let typing = Refusal::Typing.explain("s1");
        assert!(typing.starts_with("Not sent (typing):"), "{typing}");
        assert!(typing.contains("s1") && typing.contains("Nothing was written"));
        let draft = Refusal::Draft.explain("s1");
        assert!(draft.starts_with("Not sent (draft):"), "{draft}");
        assert!(draft.contains("read_screen") && draft.contains("Nothing was written"));
    }

    #[test]
    fn a_core_error_code_maps_to_its_refusal() {
        assert_eq!(
            Refusal::from_core_error("typed_since"),
            Some(Refusal::Typing)
        );
        assert_eq!(Refusal::from_core_error("draft"), Some(Refusal::Draft));
        assert_eq!(Refusal::from_core_error("Write error: EIO"), None);
    }

    #[test]
    fn the_typing_window_reaches_back_from_now() {
        assert_eq!(typing_window_start(10_000), 7_000);
        assert_eq!(typing_window_start(1), 0);
    }

    #[test]
    fn a_refused_write_stops_the_guarded_paste() {
        let (result, written) = paste_with_refusals_after(0);
        assert_eq!(result, Ok(GuardedPaste::NotPasted(Refusal::Typing)));
        assert!(written.is_empty());
        let (result, written) = paste_with_refusals_after(1);
        assert_eq!(result, Ok(GuardedPaste::NotSubmitted));
        assert_eq!(
            written,
            ["\x1b[200~batch\x1b[201~"],
            "pasted, never submitted"
        );
        // The first Enter went through: the paste was submitted.
        let (result, written) = paste_with_refusals_after(2);
        assert_eq!(result, Ok(GuardedPaste::Submitted));
        assert_eq!(written.len(), 2);
        let (result, written) = paste_with_refusals_after(3);
        assert_eq!(result, Ok(GuardedPaste::Submitted));
        assert_eq!(written.len(), 3);
    }

    #[test]
    fn paste_helpers_preserve_text_and_strip_terminal_controls() {
        let sanitized = sanitize_paste_text("hi\r\nthere\x1b[31m end\x07");
        assert_eq!(sanitized, "hi\nthere[31m end");
        assert_eq!(encode_bracketed_paste("hello"), "\x1b[200~hello\x1b[201~");
        assert!(looks_like_it_contains_a_path("look at src/lib/foo.ts"));
        assert!(!looks_like_it_contains_a_path("capture the result"));
    }
}
