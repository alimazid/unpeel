//! Fork-only: when a person last typed into a session (#38). The Inbox
//! drain must never paste onto a half-typed prompt, and the screen alone
//! cannot tell an empty prompt from a paused draft. The PTY core records
//! the time of every write that comes from a person and can change an input
//! line, and the session manifest carries it as `last_input_at`.

use serde::{Deserialize, Serialize};

/// Who a control-socket `Write` speaks for. Clients that predate the field
/// send none and count as the user, so an unknown writer holds the Inbox
/// rather than being pasted over.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WriteOrigin {
    /// A person: the attach stream, the Mac app, the phone.
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

/// The session host's answer to a `Write` it refused because a person
/// typed at or after its `unless_typed_since`.
pub const TYPED_SINCE_ERROR: &str = "a person typed into the session; nothing was written";

/// When a person last typed into one session, kept by the PTY core under
/// the session's runtime lock.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct TypingClock {
    typed_at: Option<u64>,
}

impl TypingClock {
    /// One write that reached the PTY at `now`.
    pub(crate) fn note(&mut self, origin: WriteOrigin, bytes: &[u8], now: u64) {
        if origin.is_user() && is_typing(bytes) {
            self.typed_at = Some(now);
        }
    }

    pub(crate) fn typed_at(&self) -> Option<u64> {
        self.typed_at
    }

    /// A person typed at or after `since`.
    pub(crate) fn typed_since(&self, since: u64) -> bool {
        self.typed_at.is_some_and(|at| at >= since)
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
        clock.note(WriteOrigin::Program, b"pasted by the Inbox\r", 100);
        assert_eq!(clock.typed_at(), None);
        clock.note(WriteOrigin::User, b"\x1b[I", 200);
        assert_eq!(clock.typed_at(), None, "a focus report");
        clock.note(WriteOrigin::User, b"h", 300);
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
                ..
            }
        ));
        let user = SessionHostCommand::Write {
            data: "x".into(),
            write_id: None,
            origin: WriteOrigin::User,
            unless_typed_since: None,
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
        };
        assert_eq!(
            serde_json::to_value(&enter).unwrap(),
            serde_json::json!({
                "type": "write", "data": "\r", "origin": "program", "unless_typed_since": 5
            })
        );
    }
}
