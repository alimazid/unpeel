//! Fork-only: when the user last typed into a session (#38), and whether
//! what they typed still waits on the input line (#61). The Inbox drain and
//! an agent's sends must never land on a half-typed prompt, and the screen
//! alone cannot tell an empty prompt from a paused draft. The PTY core
//! records the time of every write that comes from the user and can change
//! an input line, and the session manifest carries it as `last_input_at`.
//! For the draft it also keeps the line as it was before the first key the
//! user has not sent, since only the core sees that key arrive, and follows
//! what their text and Backspace leave there (#65): a draft whose keys were
//! erased, or taken by a program that moved on, is no draft.

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

/// Why the PTY core refused a guarded `Write` (#38, #61).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The user typed at or after its `unless_typed_since`.
    Typing,
    /// Its `unless_draft`: the input line holds what the user typed and has
    /// not sent.
    Draft,
}

impl Refusal {
    pub fn wire_code(self) -> &'static str {
        match self {
            Self::Typing => TYPED_SINCE_ERROR,
            Self::Draft => DRAFT_ERROR,
        }
    }

    /// The refusal a session host's error names, if it names one.
    pub fn from_wire(error: &str) -> Option<Self> {
        [Self::Typing, Self::Draft]
            .into_iter()
            .find(|refusal| refusal.wire_code() == error)
    }
}

/// How long the program must have drawn nothing before the draft guard ends
/// a draft on what the screen shows (#65). A redraw can be caught between
/// its writes, with the input line erased or the cursor where output is
/// being drawn.
pub(crate) const QUIET_BEFORE_ENDING: std::time::Duration = std::time::Duration::from_millis(500);

/// Where the cursor sits: which screen, and its row counted from the top of
/// scrollback, so a row keeps its number while the screen scrolls.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CursorAt {
    pub(crate) alternate: bool,
    pub(crate) row: u64,
}

/// What the draft guard reads off the screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InputScreen {
    /// A select menu is up: keys answer it, not the input line.
    pub(crate) menu: bool,
    /// The cursor's row without suggested input: a proposed reply comes and
    /// goes on its own and is never the user's.
    pub(crate) line: String,
    pub(crate) cursor_at: CursorAt,
    /// The last character drawn before the cursor, blanks skipped. `None`
    /// while the cursor is hidden: the program has not put it where it
    /// means.
    pub(crate) before_cursor: Option<char>,
    /// Nothing drawn for [`QUIET_BEFORE_ENDING`] and no synchronized update
    /// open: the screen is not caught mid-redraw.
    pub(crate) quiet: bool,
}

/// What the user typed and has not sent.
#[derive(Debug, Clone)]
struct Draft {
    /// The line before its first key.
    line_before: String,
    /// Where the cursor was at that key.
    started_at: CursorAt,
    /// What its keys left on the line while only text and Backspace typed
    /// it (see [`typed_after`]). `None` once the count could not follow a
    /// key: then only finding the line as it was ends the draft. Text a menu
    /// took is in it too, since text keys read no screen; Backspace does,
    /// so a menu's never counts. What the line shows of theirs is then always
    /// among these characters.
    typed: Option<String>,
    /// A quiet screen last showed a program took its keys. That holds while
    /// the screen is busy, so a send's own paste echoing does not make the
    /// draft come back before its Enter; any key of theirs undoes it.
    taken: bool,
}

impl Draft {
    /// The draft `bytes` start on `screen`, unless they erase themselves.
    fn start(screen: InputScreen, bytes: &[u8]) -> Option<Self> {
        let typed = typed_after(String::new(), bytes);
        (typed.as_deref() != Some("")).then_some(Self {
            line_before: screen.line,
            started_at: screen.cursor_at,
            typed,
            taken: false,
        })
    }

    /// The draft after `bytes`; `None` once they erased every key of it.
    fn typed_on(self, bytes: &[u8]) -> Option<Self> {
        let typed = self.typed.and_then(|typed| typed_after(typed, bytes));
        (typed.as_deref() != Some("")).then_some(Self {
            typed,
            taken: false,
            ..self
        })
    }

    /// Whether a program took the keys and moved on, read off a quiet
    /// screen: the cursor has left the row they were typed on, and what it
    /// follows is none of the characters typed. Either alone is a draft: one
    /// that wraps or whose input box moves, or a program that redraws its
    /// line in place (a changed prompt, masked echo). A hidden cursor or only
    /// blanks typed tell nothing.
    fn taken_by_program(&self, screen: &InputScreen) -> bool {
        let Some(typed) = self
            .typed
            .as_deref()
            .filter(|typed| !typed.trim().is_empty())
        else {
            return false;
        };
        screen.cursor_at != self.started_at
            && screen
                .before_cursor
                .is_some_and(|shown| !typed.contains(shown))
    }
}

/// When the user last typed into one session and what that left on the line,
/// kept by the PTY core under the session's runtime lock.
#[derive(Debug, Default, Clone)]
pub(crate) struct TypingClock {
    typed_at: Option<u64>,
    /// `None`: nothing of theirs is waiting.
    draft: Option<Draft>,
}

impl TypingClock {
    /// One write about to reach the PTY at `now`, before it can echo. The
    /// screen is read only when the key can start or end a draft: the first
    /// key, Enter, and a Backspace the count follows.
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
        let erases = bytes.iter().any(|byte| matches!(byte, 0x7f | 0x08));
        let counted = self.draft.as_ref().map(|draft| draft.typed.is_some());
        match (counted, enter) {
            // Enter with no draft, or a key the count no longer follows,
            // changes nothing.
            (None, true) | (Some(false), false) => return,
            (Some(true), false) if !erases => {
                self.draft = self.draft.take().and_then(|draft| draft.typed_on(bytes));
                return;
            }
            _ => {}
        }
        let screen = screen();
        if screen.menu {
            return;
        }
        self.draft = match self.draft.take() {
            _ if enter => None,
            None => Draft::start(screen, bytes),
            Some(draft) => draft.typed_on(bytes),
        };
    }

    pub(crate) fn typed_at(&self) -> Option<u64> {
        self.typed_at
    }

    /// The user typed at or after `since`.
    pub(crate) fn typed_since(&self, since: u64) -> bool {
        self.typed_at.is_some_and(|at| at >= since)
    }

    /// Whether the line holds input the user has not sent. A menu over it
    /// takes the keys, so it does not count. Only a quiet screen can end a
    /// draft: finding the line as it was ends it, so a program's later text
    /// there is not taken for theirs, and so does finding a program took its
    /// keys, until they type again.
    pub(crate) fn has_draft(&mut self, screen: impl FnOnce() -> InputScreen) -> bool {
        let Some(draft) = self.draft.as_mut() else {
            return false;
        };
        let screen = screen();
        if screen.menu {
            return false;
        }
        if screen.quiet {
            if screen.line == draft.line_before {
                self.draft = None;
                return false;
            }
            draft.taken = draft.taken_by_program(&screen);
        }
        !draft.taken
    }

    /// The program that held the input line changed, and what was on it went
    /// with that program.
    pub(crate) fn forget_draft(&mut self) {
        self.draft = None;
    }
}

/// The text the user's keys leave on the line after `text`: text adds to
/// it, Backspace takes its last character off (where several draw as one,
/// the rest stay, which can only make a draft end later). `None` for a key
/// the count cannot follow: any other key (arrows, Tab, Escape, control
/// keys, a paste, which an input box may show as a placeholder), and
/// Backspace with nothing of theirs left, which erases what was there before.
fn typed_after(mut text: String, bytes: &[u8]) -> Option<String> {
    let mut rest = bytes;
    while let Some((&first, after)) = rest.split_first() {
        rest = match first {
            0x7f | 0x08 => {
                text.pop()?;
                after
            }
            0x1b => after.get(report_len(after)?..)?,
            0x00..=0x1f => return None,
            _ => {
                let end = rest
                    .iter()
                    .position(|byte| *byte < 0x20 || *byte == 0x7f)
                    .unwrap_or(rest.len());
                text.push_str(std::str::from_utf8(&rest[..end]).ok()?);
                &rest[end..]
            }
        };
    }
    Some(text)
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
        for refusal in [Refusal::Typing, Refusal::Draft] {
            assert_eq!(Refusal::from_wire(refusal.wire_code()), Some(refusal));
        }
        assert_eq!(Refusal::from_wire("Write error: EIO"), None);
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
        on_row(0, line)
    }

    /// `line` on `row` of a quiet screen, the cursor after its last
    /// character.
    fn on_row(row: u64, line: &str) -> InputScreen {
        InputScreen {
            menu: false,
            line: line.to_owned(),
            cursor_at: CursorAt {
                alternate: false,
                row,
            },
            before_cursor: line.trim_end().chars().last(),
            quiet: true,
        }
    }

    fn menu() -> InputScreen {
        InputScreen {
            menu: true,
            ..prompt("  1. Yes")
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
        assert!(!clock.has_draft(|| prompt("> ")), "back as it was");
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
        assert!(
            clock.has_draft(|| on_row(6, "> hi")),
            "and still there in a box drawn lower"
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
    fn erasing_every_key_ends_the_draft_though_the_kept_line_was_stale() {
        // #65: the key after Enter reached the core before the program
        // redrew the line, so the line kept is the one just sent.
        let mut clock = TypingClock::default();
        typed(&mut clock, b"hi", prompt("> "));
        typed(&mut clock, b"\r", prompt("> hi"));
        typed(&mut clock, b"x", prompt("> hi"));
        assert!(clock.has_draft(|| prompt("> x")), "the key is theirs");
        typed(&mut clock, b"\x7f", prompt("> x"));
        assert!(!clock.has_draft(|| prompt("> ")));
        typed(&mut clock, b"y", prompt("> "));
        assert!(clock.has_draft(|| prompt("> y")));
        assert!(
            !clock.has_draft(|| prompt("> ")),
            "the next line kept is fresh"
        );
    }

    #[test]
    fn text_and_backspace_are_counted_and_a_report_beside_them_is_skipped() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"\x1b[Iab", prompt("> "));
        typed(&mut clock, b"\x7f", prompt("> ab"));
        assert!(clock.has_draft(|| on_row(3, "> a")), "one left");
        typed(&mut clock, b"\x08", prompt("> a"));
        assert!(!clock.has_draft(|| on_row(3, "> x")));
        typed(&mut clock, b"a\x7f", prompt("> "));
        assert!(
            !clock.has_draft(|| on_row(3, "> x")),
            "erased in the same write"
        );
    }

    #[test]
    fn a_key_the_count_cannot_follow_leaves_the_kept_line_to_end_the_draft() {
        let keys: [&[u8]; 7] = [
            b"\x1b[D",
            b"\t",
            b"\x15",
            b"\x1b",
            b"\x1b\r",
            b"\x1b[200~pasted\x1b[201~",
            b"\x7f\x7f\x7f",
        ];
        for key in keys {
            let mut clock = TypingClock::default();
            typed(&mut clock, b"ab", prompt("> "));
            typed(&mut clock, key, prompt("> ab"));
            typed(&mut clock, b"\x7f\x7f", prompt("> ab"));
            let key = String::from_utf8_lossy(key);
            assert!(clock.has_draft(|| on_row(4, "$")), "{key:?}");
            assert!(!clock.has_draft(|| prompt("> ")), "{key:?}");
        }
        // Backspace first erases what was on the line before.
        let mut clock = TypingClock::default();
        typed(&mut clock, b"\x7f", prompt("> /com"));
        assert!(clock.has_draft(|| on_row(4, "> /co")));
    }

    #[test]
    fn a_backspace_at_a_menu_over_a_draft_is_not_counted() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"h", prompt("> "));
        typed(&mut clock, b"\x7f", menu());
        assert!(!clock.has_draft(menu));
        assert!(clock.has_draft(|| on_row(4, "> h")), "the menu took it");
    }

    #[test]
    fn text_a_menu_took_is_counted_but_hides_no_draft() {
        // Text keys read no screen, so `2` at a menu counts as typed.
        let mut clock = TypingClock::default();
        typed(&mut clock, b"hi", prompt("> "));
        clock.note(WriteOrigin::User, b"2", 2, unread);
        assert!(clock.has_draft(|| on_row(5, "> hi")), "the box moved down");
        typed(&mut clock, b"\x7f", on_row(5, "> hi"));
        assert!(clock.has_draft(|| on_row(5, "> h")));
        typed(&mut clock, b"\x7f", on_row(5, "> h"));
        assert!(!clock.has_draft(|| on_row(5, ">")), "erased");
    }

    #[test]
    fn backspace_over_a_character_drawn_from_several_ends_the_draft_late() {
        let mut clock = TypingClock::default();
        typed(&mut clock, "s\u{ed}".as_bytes(), prompt("> "));
        typed(&mut clock, b"\x7f\x7f", prompt("> s\u{ed}"));
        assert!(!clock.has_draft(|| on_row(2, "> x")), "accented, erased");
        // A thumbs-up with a skin tone is two characters and one Backspace.
        typed(&mut clock, "a\u{1f44d}\u{1f3fd}".as_bytes(), prompt("> "));
        typed(&mut clock, b"\x7f", prompt("> a\u{1f44d}\u{1f3fd}"));
        assert!(clock.has_draft(|| on_row(2, "> a")));
        typed(&mut clock, b"\x7f", prompt("> a"));
        assert!(clock.has_draft(|| on_row(0, "> x")), "one stays counted");
        assert!(!clock.has_draft(|| prompt("> ")), "back as it was");
    }

    #[test]
    fn a_key_a_program_took_is_no_draft_once_it_moved_on() {
        // #65: a one-key prompt acts on `y` without Enter, says so, and the
        // shell prompts two rows down.
        let mut clock = TypingClock::default();
        typed(&mut clock, b"y", on_row(3, "Delete it? [y/n]"));
        assert!(!clock.has_draft(|| on_row(5, "$")));
        assert_eq!(clock.typed_at(), Some(1), "they still typed");
        // What they type at the new prompt is a draft until erased.
        typed(&mut clock, b"ls", on_row(5, "$"));
        assert!(clock.has_draft(|| on_row(5, "$ ls")));
        typed(&mut clock, b"\x7f\x7f", on_row(5, "$ ls"));
        assert!(!clock.has_draft(|| on_row(5, "$")));
    }

    #[test]
    fn a_send_after_a_program_took_the_key_is_not_refused_while_it_echoes() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"y", on_row(3, "Delete it? [y/n]"));
        assert!(!clock.has_draft(|| on_row(5, "$")));
        let pasted = InputScreen {
            quiet: false,
            ..on_row(5, "$ echo sent")
        };
        assert!(!clock.has_draft(|| pasted.clone()), "the paste's Enter");
        clock.note(WriteOrigin::User, b"x", 2, unread);
        assert!(clock.has_draft(|| pasted), "a key of theirs since");
    }

    #[test]
    fn a_draft_that_wraps_onto_more_rows_stays() {
        let mut clock = TypingClock::default();
        let text = format!("{} the end ", "x".repeat(70));
        typed(&mut clock, text.as_bytes(), on_row(9, "> "));
        assert!(clock.has_draft(|| on_row(10, "x the end")));
        assert!(
            clock.has_draft(|| on_row(10, "    the end")),
            "an input box that indents the rows it continues on"
        );
        let caret_starts_the_row = InputScreen {
            before_cursor: None,
            ..on_row(11, "")
        };
        assert!(clock.has_draft(|| caret_starts_the_row));
    }

    #[test]
    fn a_draft_stays_while_output_moves_its_input_box() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"fix it", on_row(20, "\u{276f}\u{a0}"));
        assert!(clock.has_draft(|| on_row(26, "\u{276f}\u{a0}fix it")));
        // A redraw caught between its writes: the cursor sits where output is
        // being drawn, or is hidden until the frame is done.
        let mid_redraw = InputScreen {
            quiet: false,
            ..on_row(24, "\u{23fa} Done")
        };
        assert!(clock.has_draft(|| mid_redraw));
        let hidden = InputScreen {
            before_cursor: None,
            ..on_row(24, "\u{23fa} Done")
        };
        assert!(clock.has_draft(|| hidden));
        let erased_before_drawn = InputScreen {
            quiet: false,
            ..on_row(27, "\u{276f}")
        };
        assert!(clock.has_draft(|| erased_before_drawn));
        assert!(clock.has_draft(|| on_row(27, "\u{276f}\u{a0}fix it")));
    }

    #[test]
    fn a_draft_stays_under_masked_echo() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"hunter2", on_row(2, "Password:"));
        assert!(clock.has_draft(|| on_row(2, "Password: *******")));
    }

    #[test]
    fn a_draft_stays_when_the_program_redraws_its_prompt_in_place() {
        // Claude Code takes a leading `!` into bash mode and redraws the
        // prompt; a program may draw its own glyph there.
        let mut clock = TypingClock::default();
        typed(&mut clock, b"!", on_row(7, "\u{276f}\u{a0}"));
        assert!(clock.has_draft(|| on_row(7, "!")));
        assert!(clock.has_draft(|| on_row(7, "$")));
        typed(&mut clock, b"ls", on_row(7, "!"));
        assert!(clock.has_draft(|| on_row(7, "! ls")));
    }

    #[test]
    fn a_draft_stays_on_another_screen_until_it_is_quiet_there() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"q", on_row(23, ":"));
        let alternate = |quiet| InputScreen {
            cursor_at: CursorAt {
                alternate: true,
                row: 23,
            },
            quiet,
            ..on_row(23, "$")
        };
        assert!(clock.has_draft(|| alternate(false)), "still drawing");
        assert!(!clock.has_draft(|| alternate(true)), "the pager quit");
    }

    #[test]
    fn the_line_as_it_was_ends_a_draft_only_on_a_quiet_screen() {
        let mut clock = TypingClock::default();
        typed(&mut clock, b"hi", prompt("> "));
        typed(&mut clock, b"\x1b[D", prompt("> hi"));
        let mid_redraw = InputScreen {
            quiet: false,
            ..prompt("> ")
        };
        assert!(
            clock.has_draft(|| mid_redraw),
            "erased before it is drawn again"
        );
        assert!(clock.has_draft(|| prompt("> hi")));
        assert!(!clock.has_draft(|| prompt("> ")));
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
