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
    pub(crate) last_char_before_cursor: Option<char>,
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
                .last_char_before_cursor
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
        let text_key = !enter && !bytes.iter().copied().any(is_backspace);
        match self.draft.as_ref() {
            // Enter with no draft, or a key the count no longer follows,
            // changes nothing.
            None if enter => return,
            Some(draft) if !enter && draft.typed.is_none() => return,
            Some(_) if text_key => {
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
            byte if is_backspace(byte) => {
                text.pop()?;
                after
            }
            0x1b => after.get(report_len(after)?..)?,
            0x00..=0x1f => return None,
            _ => {
                let end = rest
                    .iter()
                    .position(|&byte| byte < 0x20 || is_backspace(byte))
                    .unwrap_or(rest.len());
                text.push_str(std::str::from_utf8(&rest[..end]).ok()?);
                &rest[end..]
            }
        };
    }
    Some(text)
}

/// Backspace, as a terminal sends it: DEL, or Ctrl+H.
fn is_backspace(byte: u8) -> bool {
    matches!(byte, 0x7f | 0x08)
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
mod tests;
