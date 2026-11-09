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
    let old: SessionHostCommand = serde_json::from_str(r#"{"type":"write","data":"x"}"#).unwrap();
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

/// [`on_row`], under `row_above`.
fn below(row: u64, row_above: &str, line: &str) -> InputScreen {
    InputScreen {
        row_above: row_above.to_owned(),
        ..on_row(row, line)
    }
}

/// `line` on `row` of a quiet screen, the cursor after its last
/// character.
fn on_row(row: u64, line: &str) -> InputScreen {
    InputScreen {
        menu: false,
        line: line.to_owned(),
        row_above: String::new(),
        cursor_at: CursorAt {
            alternate: false,
            row,
        },
        last_char_before_cursor: line.trim_end().chars().last(),
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
    assert!(!clock.has_draft(|| below(5, "deleted", "$")));
    assert_eq!(clock.typed_at(), Some(1), "they still typed");
    assert!(
        clock.has_draft(|| below(5, "your file is gone", "$")),
        "the row above may show it: late, not early"
    );
    let mut spaced = TypingClock::default();
    typed(&mut spaced, b"y ", on_row(3, "Delete it? [y/n]"));
    assert!(
        !spaced.has_draft(|| below(5, "all deleted", "$")),
        "blanks are no one's"
    );
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
        last_char_before_cursor: None,
        ..on_row(11, "")
    };
    assert!(clock.has_draft(|| caret_starts_the_row));
}

#[test]
fn a_draft_stays_when_the_cursor_waits_after_a_border_on_its_next_row() {
    // A TUI draws `│` down the side of its input box. After a space that
    // wraps the line, or text that fills a row, the cursor waits at the
    // start of the next row: the character before it is the border.
    let mut clock = TypingClock::default();
    typed(&mut clock, b"hello world ", on_row(9, "\u{2502} >"));
    assert!(clock.has_draft(|| below(10, "\u{2502} > hello world \u{2502}", "\u{2502}")));
    typed(&mut clock, b"again", on_row(10, "\u{2502}"));
    assert!(clock.has_draft(|| below(10, "\u{2502} > hello world \u{2502}", "\u{2502} again")));
}

#[test]
fn a_masked_draft_stays_when_its_input_box_moves() {
    let mut clock = TypingClock::default();
    typed(&mut clock, b"hunter2", on_row(2, "Password:"));
    assert!(clock.has_draft(|| below(3, "ok.", "Password: *******")));
    assert!(clock.has_draft(|| below(3, "ok.", "Password: \u{2022}\u{2022}")));
    assert!(clock.has_draft(|| below(3, "ok.", "Password: \u{25aa}\u{25aa}")));
    assert!(clock.has_draft(|| below(3, "ok.", "Password: \u{25a0}\u{25a0}")));
}

#[test]
fn a_click_inside_a_draft_stops_the_count() {
    // The cursor can land anywhere in it, so what the cursor follows says
    // nothing of the keys any more: the draft waits for its line to return.
    let mut clock = TypingClock::default();
    typed(&mut clock, b"ab", on_row(2, "\u{2502} \u{276f}"));
    clock.note(WriteOrigin::User, b"\x1b[<0;5;3M\x1b[<0;5;3m", 2, unread);
    assert_eq!(clock.typed_at(), Some(1), "a click is no typing");
    clock.note(WriteOrigin::User, b"\x7f", 3, unread);
    let at_its_start = InputScreen {
        last_char_before_cursor: Some('\u{276f}'),
        ..below(4, "\u{2500}\u{2500}", "\u{2502} \u{276f} ab")
    };
    assert!(clock.has_draft(|| at_its_start));
    let mut x10 = TypingClock::default();
    typed(&mut x10, b"y", on_row(3, "Delete it? [y/n]"));
    x10.note(WriteOrigin::User, b"\x1b[M !!", 2, unread);
    assert!(x10.has_draft(|| below(5, "deleted", "$")));
}

#[test]
fn the_pointer_or_the_wheel_moving_keeps_the_count() {
    let mut clock = TypingClock::default();
    typed(&mut clock, b"y", on_row(3, "Delete it? [y/n]"));
    clock.note(WriteOrigin::User, b"\x1b[<35;5;3M\x1b[<64;5;3M", 2, unread);
    clock.note(WriteOrigin::User, b"\x1b[M`!!\x1b[MC!!", 3, unread);
    assert!(!clock.has_draft(|| below(5, "deleted", "$")));
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
        last_char_before_cursor: None,
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
