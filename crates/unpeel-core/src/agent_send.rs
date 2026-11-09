//! Fork-only (#61, ADR 0011): an agent's `send_text` and `send_keys` never
//! land on what the user is typing. Every write asks the target's PTY core,
//! which sees each key at once and keeps the line from before the user's
//! first unsent key, to refuse it while the user typed in the last
//! [`TYPING_QUIET_MS`] or left a draft. The core decides under its own lock,
//! so nothing slips in between a look at the screen and the write. A refused
//! send writes nothing and is never queued: the caller learns why and sends
//! again later.

use crate::session_input::{self, GuardedPaste, Refusal};

/// Keys this recent mean the user is at the keyboard. The Inbox's quiet
/// window for typing (`inbox_rules::QUIET_MS`) is as long.
pub const TYPING_QUIET_MS: u64 = 3_000;

/// Where the "is typing" window starts for a send at `now`. The manifest's
/// `last_input_at` can lag a key by up to ~2.5 s, so the send leaves the
/// check to the PTY core with this as its `unless_typed_since`.
pub fn typing_window_start(now: u64) -> u64 {
    now.saturating_sub(TYPING_QUIET_MS)
}

/// The caller's result for a refused write: a stable phrase, then what to do.
pub fn explain(refusal: Refusal, session_id: &str) -> String {
    match refusal {
        Refusal::Typing => format!(
            "Not sent (typing): the user typed in session {session_id} within the last {} s. \
Nothing was written. Send again once they have stopped.",
            TYPING_QUIET_MS / 1_000
        ),
        Refusal::Draft => format!(
            "Not sent (draft): session {session_id} has input the user typed and has not sent. \
Nothing was written. Look at it with read_screen, and send again once they have sent or \
cleared it. If it stays, ask them; if the line shows nothing of theirs, ask them to press \
Enter there."
        ),
    }
}

fn not_submitted(session_id: &str) -> String {
    format!(
        "Not submitted (typing): the user started typing in session {session_id} while the text \
was being pasted, so it waits on their line with their keys and Enter was not pressed. Don't \
send it again."
    )
}

/// Appended to a result when the target's PTY core predates the guard (no
/// `draft_guard` in its manifest), so the send was written unchecked.
fn unguarded_note(guarded: bool) -> &'static str {
    if guarded {
        ""
    } else {
        " (unguarded: this Session's PTY core predates the draft guard, so the send did not \
check whether the user was typing; read_screen first, or have the user resume the Session)"
    }
}

fn core_has_draft_guard(session_id: &str) -> bool {
    crate::session_host::load_manifest(session_id).is_some_and(|manifest| manifest.draft_guard)
}

/// `send_text`'s delivery of already-sanitized text. `Ok` carries the note
/// for the caller's result.
pub fn deliver_text(session_id: &str, text: &str, submit: bool) -> Result<&'static str, String> {
    let since = typing_window_start(crate::state::current_timestamp_ms());
    match session_input::paste_unless_user_is_typing(session_id, text, submit, since)? {
        GuardedPaste::Submitted => Ok(unguarded_note(core_has_draft_guard(session_id))),
        GuardedPaste::NotPasted(refusal) => Err(explain(refusal, session_id)),
        GuardedPaste::NotSubmitted => Err(not_submitted(session_id)),
    }
}

/// `send_keys`'s writes: one typing window for the whole call, taken after
/// the write gate (which can wait on the user's approval), so the user's
/// first key stops the rest of the sequence.
pub struct Keys<'a> {
    session_id: &'a str,
    since: u64,
    total: usize,
}

impl<'a> Keys<'a> {
    pub fn start(session_id: &'a str, total: usize) -> Self {
        Self {
            session_id,
            since: typing_window_start(crate::state::current_timestamp_ms()),
            total,
        }
    }

    /// Write the key at `index`; a refusal says how many went in before it.
    pub fn write(&self, index: usize, sequence: &str) -> Result<(), String> {
        match session_input::write_key_unless_user_is_typing(self.session_id, sequence, self.since)?
        {
            None => Ok(()),
            Some(refusal) => Err(format!(
                "Sent {index} of {} keys. {}",
                self.total,
                explain(refusal, self.session_id)
            )),
        }
    }

    /// The note for the caller's result once every key went in.
    pub fn note(&self) -> &'static str {
        unguarded_note(core_has_draft_guard(self.session_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusals_name_a_stable_phrase_and_what_to_do() {
        let typing = explain(Refusal::Typing, "s1");
        assert!(typing.starts_with("Not sent (typing):"), "{typing}");
        assert!(typing.contains("s1") && typing.contains("Nothing was written"));
        let draft = explain(Refusal::Draft, "s1");
        assert!(draft.starts_with("Not sent (draft):"), "{draft}");
        assert!(draft.contains("read_screen") && draft.contains("Nothing was written"));
        assert!(draft.contains("press Enter"), "the user's way out");
        let late = not_submitted("s1");
        assert!(late.starts_with("Not submitted (typing):"), "{late}");
        assert!(late.contains("Don't send it again"));
    }

    #[test]
    fn only_a_core_without_the_guard_is_named_in_the_result() {
        assert_eq!(unguarded_note(true), "");
        assert!(unguarded_note(false).starts_with(" (unguarded:"));
    }

    #[test]
    fn the_typing_window_reaches_back_from_now() {
        assert_eq!(typing_window_start(10_000), 7_000);
        assert_eq!(typing_window_start(1), 0);
    }
}
