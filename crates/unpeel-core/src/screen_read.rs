//! The agent-facing text of a viewport snapshot, for `sessions read_screen`
//! and `inspect`'s screen tail: the rendered rows, right-trimmed, except that
//! suggested input — text the program drew faint at the cursor, such as
//! Claude Code's proposed reply (`TerminalViewportSnapshot::suggested_input`)
//! — is bracketed so a reader can tell it from typed input. Plain text
//! carries no styling, and the two look identical without the brackets.
//! `wait_for_text` keeps matching the unmarked rows.

use crate::terminal_viewport::TerminalViewportSnapshot;

const SUGGESTED_OPEN: &str = "⟪suggested: ";
const SUGGESTED_CLOSE: &str = "⟫";

/// The snapshot's rows as newline-terminated text, the suggested input (if
/// any) wrapped in `⟪suggested: …⟫`.
pub fn screen_text(snapshot: &TerminalViewportSnapshot) -> String {
    let marked = snapshot
        .suggested_input
        .as_ref()
        .filter(|_| snapshot.suggested_input_text().is_some());
    let mut body = String::new();
    for (index, row) in snapshot.viewport_rows.iter().enumerate() {
        match marked.filter(|suggested| usize::from(suggested.row) == index) {
            Some(suggested) => {
                let (start, end) = (suggested.byte_start as usize, suggested.byte_end as usize);
                body.push_str(&row.text[..start]);
                body.push_str(SUGGESTED_OPEN);
                body.push_str(&row.text[start..end]);
                body.push_str(SUGGESTED_CLOSE);
                body.push_str(row.text[end..].trim_end());
            }
            None => body.push_str(row.text.trim_end()),
        }
        body.push('\n');
    }
    body
}

/// One line explaining the marker, for a read's header; `None` when the
/// screen shows no suggested input.
pub fn suggested_input_note(snapshot: &TerminalViewportSnapshot) -> Option<String> {
    let text = snapshot.suggested_input_text()?;
    Some(format!(
        "suggested_input={text:?}: the program drew this dimmed at the cursor (a proposed \
reply or placeholder), marked {SUGGESTED_OPEN}…{SUGGESTED_CLOSE} below. Nobody typed it: \
never report it as the user's reply, and do not press Enter on it (that may submit it)."
    ))
}

#[cfg(test)]
mod tests {
    use super::{screen_text, suggested_input_note};
    use crate::terminal_viewport::render_terminal_viewport_from_bytes;

    #[test]
    fn brackets_the_suggestion_and_leaves_other_rows_plain() {
        let snapshot = render_terminal_viewport_from_bytes(
            "\x1b[2m▎\x1b[22m quoted\r\n❯\u{a0}\x1b[2mleave the epic\x1b[22m\x1b[2;3H".as_bytes(),
            30,
            3,
            0,
            false,
            0,
            None,
        );

        assert_eq!(
            screen_text(&snapshot),
            "▎ quoted\n❯\u{a0}⟪suggested: leave the epic⟫\n\n"
        );
        let note = suggested_input_note(&snapshot).expect("note");
        assert!(note.starts_with("suggested_input=\"leave the epic\": "));
        assert!(note.contains("Nobody typed it"));
    }

    #[test]
    fn typed_input_is_left_unmarked() {
        let snapshot = render_terminal_viewport_from_bytes(
            "❯\u{a0}fix the bug".as_bytes(),
            30,
            2,
            0,
            false,
            0,
            None,
        );

        assert_eq!(screen_text(&snapshot), "❯\u{a0}fix the bug\n\n");
        assert_eq!(suggested_input_note(&snapshot), None);
    }

    #[test]
    fn keeps_text_after_the_suggestion_on_its_row() {
        let snapshot = render_terminal_viewport_from_bytes(
            b"> \x1b[2mghost\x1b[22m  (tab)\x1b[1;3H",
            30,
            1,
            0,
            false,
            0,
            None,
        );

        assert_eq!(screen_text(&snapshot), "> ⟪suggested: ghost⟫  (tab)\n");
    }

    #[test]
    fn a_range_that_does_not_fit_its_row_is_ignored() {
        let mut snapshot = render_terminal_viewport_from_bytes(
            b"> \x1b[2mab\x1b[22m\x1b[1;3H",
            10,
            1,
            0,
            false,
            0,
            None,
        );
        let suggested = snapshot.suggested_input.as_mut().expect("suggested input");
        suggested.byte_end = 99;

        assert_eq!(screen_text(&snapshot), "> ab\n");
        assert_eq!(suggested_input_note(&snapshot), None);
    }
}
