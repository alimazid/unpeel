//! Fork-only: when the user last typed into a session (#38), and whether
//! what they typed still waits on the input line (#61). The Inbox drain and
//! an agent's sends must never land on a half-typed prompt, and the screen
//! alone cannot tell an empty prompt from a paused draft. The PTY core
//! records the time of every write that comes from the user and can change
//! an input line, and the session manifest carries it as `last_input_at`.
//! For the draft it also keeps the line as it was before the first key the
//! user has not sent, since only the core sees that key arrive.

use serde::{Deserialize, Serialize};

/// Who a control-socket `Write` speaks for. Clients that predate the field
/// send none and count as the user, so an unknown writer holds the Inbox
/// rather than being pasted over.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WriteOrigin {
    /// The user: the attach stream, the Mac app, the phone.
    #[default]
    User,
    /// Unpeel or an agent: the Inbox paste, MCP `send_text`/`send_keys`,
    /// a preset's initial prompt, the screenshot request.
    Program,
}

impl WriteOrigin {
    pub fn is_user(&self) -> bool {
        *self == Self::User
    }
}

/// The session host's error for a `Write` it refused because the user
/// typed at or after its `unless_typed_since`. A wire code that PTY cores of
/// every build answer with, since a core outlives upgrades: never reword it.
pub const TYPED_SINCE_ERROR: &str = "typed_since";

/// The session host's error for a `Write` it refused because of its
/// `unless_draft`: the input line holds what the user typed and has not sent.
/// A wire code, like [`TYPED_SINCE_ERROR`]: never reword it.
pub const DRAFT_ERROR: &str = "draft";

/// What the draft guard reads off the screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InputScreen {
    /// A select menu is up: keys answer it, not the input line.
    pub(crate) menu: bool,
    /// The cursor's row without suggested input: a proposed reply comes and
    /// goes on its own and is never the user's.
    pub(crate) line: String,
}

/// When the user last typed into one session and what that left on the line,
/// kept by the PTY core under the session's runtime lock.
#[derive(Debug, Default, Clone)]
pub(crate) struct TypingClock {
    typed_at: Option<u64>,
    /// The line before the first key the user has not sent. `None`: nothing
    /// of theirs is waiting.
    line_before_typing: Option<String>,
}

impl TypingClock {
    /// One write about to reach the PTY at `now`, before it can echo. The
    /// screen is read only when the key can start or end a draft.
    pub(crate) fn note(
        &mut self,
        origin: WriteOrigin,
        bytes: &[u8],
        now: u64,
        screen: impl FnOnce() -> InputScreen,
    ) {
        if !origin.is_user() || !is_typing(bytes) {
            return;
        }
        self.typed_at = Some(now);
        let enter = ends_in_enter(bytes);
        // A key on a draft already started, or Enter with none, changes
        // nothing.
        if self.line_before_typing.is_some() != enter {
            return;
        }
        let screen = screen();
        if !screen.menu {
            self.line_before_typing = (!enter).then_some(screen.line);
        }
    }

    pub(crate) fn typed_at(&self) -> Option<u64> {
        self.typed_at
    }

    /// The user typed at or after `since`.
    pub(crate) fn typed_since(&self, since: u64) -> bool {
        self.typed_at.is_some_and(|at| at >= since)
    }

    /// Whether the line holds input the user has not sent. A menu over it
    /// takes the keys, so it does not count. Finding the line as it was ends
    /// the draft, so a program's later text there is not taken for theirs.
    pub(crate) fn has_draft(&mut self, screen: impl FnOnce() -> InputScreen) -> bool {
        let Some(before) = self.line_before_typing.as_ref() else {
            return false;
        };
        let screen = screen();
        if screen.menu {
            return false;
        }
        if screen.line == *before {
            self.line_before_typing = None;
            return false;
        }
        true
    }

    /// The program that held the input line changed, and what was on it went
    /// with that program.
    pub(crate) fn forget_draft(&mut self) {
        self.line_before_typing = None;
    }
}

/// Whether the user's write ends by pressing plain Enter, which sends the
/// line. Alt+Enter, Shift+Enter and Ctrl+J add a line to it instead. A
/// backslash continuation reads as sent until the next key.
fn ends_in_enter(bytes: &[u8]) -> bool {
    match bytes {
        [.., 0x1b, b'\r'] => false,
        [.., b'\r'] => true,
        _ => bytes.ends_with(b"\x1b[13u") || bytes.ends_with(b"\x1b[13;1u"),
    }
}

/// Whether `bytes` can change an input line: keys, text (dictation
/// included) and the user's own paste do. The terminal's own reports do
/// not: mouse reports (an agent with any-motion tracking gets one per
/// pointer move), focus in/out, and replies to terminal queries.
pub(crate) fn is_typing(bytes: &[u8]) -> bool {
    let mut rest = bytes;
    while let Some((&first, after)) = rest.split_first() {
        if first != 0x1b {
            return true;
        }
        match report_len(after) {
            Some(len) => rest = &after[len..],
            None => return true,
        }
    }
    false
}

/// The length, after its ESC, of the terminal report at the start of
/// `after`; `None` for a key (a lone Escape, Alt+key, a CSI or SS3 key).
fn report_len(after: &[u8]) -> Option<usize> {
    match after.first()? {
        b'[' => csi_report_len(&after[1..]).map(|len| len + 1),
        // OSC, DCS, APC, PM, SOS replies. Unterminated, it is Alt+key.
        b']' | b'P' | b'_' | b'^' | b'X' => string_len(&after[1..]).map(|len| len + 1),
        _ => None,
    }
}

/// A CSI only the terminal sends: a mouse report, focus in/out, or a reply
/// (private-marker replies, cursor position, status, window, attributes,
/// mode reports). Keys (arrows, `~` keys, kitty `u` keys, the user's
/// bracketed paste) are `None`. An unfinished CSI is no key either.
fn csi_report_len(body: &[u8]) -> Option<usize> {
    if body.first() == Some(&b'M') {
        // X10 mouse: `CSI M` and three raw bytes.
        return Some(body.len().min(4));
    }
    let Some(end) = body.iter().position(|byte| (0x40..=0x7e).contains(byte)) else {
        return Some(body.len());
    };
    let (parameters, final_byte) = (&body[..end], body[end]);
    let private = parameters
        .first()
        .is_some_and(|byte| matches!(byte, b'?' | b'>' | b'<' | b'='));
    let focus = parameters.is_empty() && matches!(final_byte, b'I' | b'O');
    let reply = matches!(final_byte, b'R' | b'n' | b't' | b'c')
        || (final_byte == b'y' && parameters.contains(&b'$'));
    (private || focus || reply).then_some(end + 1)
}

/// The length of a string body through its BEL or ST terminator.
fn string_len(body: &[u8]) -> Option<usize> {
    let mut index = 0;
    while index < body.len() {
        match body[index] {
            0x07 => return Some(index + 1),
            0x1b if body.get(index + 1) == Some(&b'\\') => return Some(index + 2),
            _ => index += 1,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_host::SessionHostCommand;

    #[test]
    fn keys_text_and_pastes_are_typing() {
        let inputs: [&[u8]; 12] = [
            b"a",
            b"can yo",
            b"\x7f",
            b"\r",
            b"\x1b",
            b"\x1b[A",
            b"\x1bOA",
            b"\x1bb",
            b"\x1b[97;5u",
            b"\x1b[3~",
            "dictado: \u{bf}qu\u{e9} tal?".as_bytes(),
            b"\x1b[200~pasted text\x1b[201~",
        ];
        for input in inputs {
            assert!(is_typing(input), "{:?}", String::from_utf8_lossy(input));
        }
    }

    #[test]
    fn the_terminals_own_reports_are_not_typing() {
        let inputs: [&[u8]; 14] = [
            b"",
            b"\x1b[<35;10;5M\x1b[<35;11;5M",
            b"\x1b[<0;10;5m",
            b"\x1b[M #!",
            b"\x1b[I",
            b"\x1b[O",
            b"\x1b[?62;22c",
            b"\x1b[>1;10;0c",
            b"\x1b[12;40R",
            b"\x1b[?1u",
            b"\x1b[?2004;1$y",
            b"\x1b]11;rgb:0000/0000/0000\x1b\\",
            b"\x1b]10;rgb:ffff/ffff/ffff\x07",
            b"\x1bP>|ghostty 1.2\x1b\\",
        ];
        for input in inputs {
            assert!(!is_typing(input), "{:?}", String::from_utf8_lossy(input));
        }
    }

    #[test]
    fn a_report_next_to_a_key_is_typing() {
        assert!(is_typing(b"\x1b[Ia"));
        assert!(is_typing(b"\x1b[<35;1;1Mx"));
        assert!(is_typing(b"x\x1b]11;rgb:0/0/0\x07"));
    }

    #[test]
    fn alt_with_a_report_introducer_is_still_a_key() {
        assert!(is_typing(b"\x1bP"), "Alt+P");
        assert!(is_typing(b"\x1b]"), "Alt+]");
    }

    #[test]
    fn only_a_persons_typing_moves_the_clock() {
        let mut clock = TypingClock::default();
        clock.note(WriteOrigin::Program, b"pasted by the Inbox\r", 100, unread);
        assert_eq!(clock.typed_at(), None);
        clock.note(WriteOrigin::User, b"\x1b[I", 200, unread);
        assert_eq!(clock.typed_at(), None, "a focus report");
        clock.note(WriteOrigin::User, b"h", 300, || prompt("> "));
        assert_eq!(clock.typed_at(), Some(300));
        assert!(clock.typed_since(300));
        assert!(!clock.typed_since(301));
    }

    #[test]
    fn a_write_without_an_origin_is_the_users_and_serializes_as_before() {
        let old: SessionHostCommand =
            serde_json::from_str(r#"{"type":"write","data":"x"}"#).unwrap();
        assert!(matches!(
            old,
            SessionHostCommand::Write {
                origin: WriteOrigin::User,
                unless_typed_since: None,
                unless_draft: false,
                ..
            }
        ));
        assert_eq!(TYPED_SINCE_ERROR, "typed_since", "a wire code");
        assert_eq!(DRAFT_ERROR, "draft", "a wire code");
        let user = SessionHostCommand::Write {
            data: "x".into(),
            write_id: None,
            origin: WriteOrigin::User,
            unless_typed_since: None,
            unless_draft: false,
        };
        assert_eq!(
            serde_json::to_value(&user).unwrap(),
            serde_json::json!({ "type": "write", "data": "x" })
        );
        let enter = SessionHostCommand::Write {
            data: "\r".into(),
            write_id: None,
            origin: WriteOrigin::Program,
            unless_typed_since: Some(5),
            unless_draft: true,
        };
        assert_eq!(
            serde_json::to_value(&enter).unwrap(),
            serde_json::json!({
                "type": "write", "data": "\r", "origin": "program",
                "unless_typed_since": 5, "unless_draft": true
            })
        );
    }

    fn prompt(line: &str) -> InputScreen {
        InputScreen {
            menu: false,
            line: line.to_owned(),
        }
    }

    fn menu() -> InputScreen {
        InputScreen {
            menu: true,
            line: "  1. Yes".to_owned(),
        }
    }

    /// For a step that must not read the screen.
    fn unread() -> InputScreen {
        panic!("the screen was read")
    }

    fn typed(clock: &mut TypingClock, bytes: &[u8], screen: InputScreen) {
        clock.note(WriteOrigin::User, bytes, 1, || screen);
    }

    #[test]
    fn what_the_user_typed_is_a_draft_until_the_line_is_back() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"h", prompt("> "));
        clock.note(WriteOrigin::User, b"i", 2, unread);
        assert!(clock.has_draft(|| prompt("> hi")));
        assert!(clock.has_draft(|| prompt("> hi")), "asking changes nothing");
        assert!(!clock.has_draft(|| prompt("> ")), "erased");
        // Program text on the line after that is not theirs (a multi-key
        // send_keys, a paste left unsubmitted).
        assert!(!clock.has_draft(|| prompt("> /com")));
    }

    #[test]
    fn a_program_write_or_a_terminal_report_starts_no_draft() {
        let mut clock = TypingClock::default();
        clock.note(WriteOrigin::Program, b"pasted", 1, unread);
        clock.note(WriteOrigin::User, b"\x1b[<35;10;5M", 2, unread);
        clock.note(WriteOrigin::User, b"\x1b[I", 3, unread);
        assert!(!clock.has_draft(|| prompt("> pasted")));
    }

    #[test]
    fn enter_sends_the_draft_and_the_next_key_reads_the_line_again() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"hi", prompt("> "));
        typed(&mut clock, b"\r", prompt("> hi"));
        assert!(
            !clock.has_draft(|| prompt("$ ")),
            "whatever the line is now"
        );
        typed(&mut clock, b"x", prompt("$ "));
        assert!(clock.has_draft(|| prompt("$ x")));
        assert!(!clock.has_draft(|| prompt("$ ")));
    }

    #[test]
    fn keys_at_a_menu_start_no_draft_and_leave_the_one_under_it() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"1", menu());
        typed(&mut clock, b"\r", menu());
        assert!(!clock.has_draft(|| prompt("> ")), "answered a menu");

        typed(&mut clock, b"hi", prompt("> "));
        typed(&mut clock, b"\x1b[B", menu());
        typed(&mut clock, b"\r", menu());
        assert!(!clock.has_draft(menu), "keys go to the menu");
        assert!(
            clock.has_draft(|| prompt("> hi")),
            "the draft is still there"
        );
    }

    #[test]
    fn a_draft_does_not_outlive_the_program_that_held_the_line() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"\x03", prompt("> "));
        clock.forget_draft();
        assert!(!clock.has_draft(|| prompt("$ ")));
        assert_eq!(clock.typed_at(), Some(1), "they still typed");
    }

    #[test]
    fn only_plain_enter_sends_the_line() {
        for sends in [&b"\r"[..], b"hi\r", b"\x1b[13u", b"\x1b[13;1u"] {
            assert!(ends_in_enter(sends), "{:?}", String::from_utf8_lossy(sends));
        }
        for keeps in [
            &b"h"[..],
            b"\n",
            b"\x1b\r",
            b"\x1b[13;2u",
            b"\x1b[200~a\rb\x1b[201~",
        ] {
            assert!(
                !ends_in_enter(keeps),
                "{:?}",
                String::from_utf8_lossy(keeps)
            );
        }
    }
}
