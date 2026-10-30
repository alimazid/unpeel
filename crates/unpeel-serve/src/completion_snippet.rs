//! Fork-only: the short text a "finished" notification shows instead of a
//! bare "Finished" — the agent's own done summary (OSC 7501 `msg`) or the
//! opening of its final reply (the Stop hook's `last_assistant_message`).
//!
//! The reply is untrusted provider output: control, bidi-override, and
//! other invisible format characters are dropped, light Markdown is
//! flattened to prose, fenced code and tables are skipped, and the result is
//! cut on a word boundary.

/// Longest snippet, in characters. A macOS banner shows about two lines and
/// Notification Center expands to roughly this much.
pub const MAX_SNIPPET_CHARS: usize = 240;

/// Bytes of a hook's final reply kept for later summarizing; the rest of a
/// long reply can never reach the snippet.
pub const MAX_RAW_MESSAGE_BYTES: usize = 8 * 1024;

/// The body for a finished notification: the program's own summary from the
/// `done` report that made the edge, else the opening of the turn's final
/// reply; `None` keeps the generic "Finished".
pub fn finished_body(edge_msg: Option<&str>, hook_message: Option<&str>) -> Option<String> {
    edge_msg
        .and_then(snippet)
        .or_else(|| hook_message.and_then(snippet))
}

/// How long after its Stop a reply may still label a finished edge. The
/// edge follows the Stop within a scan or two; anything older belongs to an
/// earlier turn whose notification never took it.
pub const MAX_REPLY_AGE_MS: u64 = 30_000;

/// The latest final reply per Session, scoped to the turn that produced it:
/// a Stop records its reply (or forgets the old one when it has none), the
/// next turn or a cancelled or failed one drops it, and the finished
/// notification takes it once while it is fresh.
#[derive(Debug, Default)]
pub struct CompletionMessages {
    /// Session id → (bounded reply, receipt in unix ms).
    by_session: std::collections::HashMap<String, (String, u64)>,
}

impl CompletionMessages {
    /// Fold one accepted hook event by its wire name. Subagent stops
    /// normalize to `HookSeen` and never touch the parent's reply.
    pub fn observe(
        &mut self,
        session_id: &str,
        raw_event: &str,
        message: Option<&str>,
        received_at_ms: u64,
    ) {
        match crate::activity::normalize_event_name(raw_event).as_str() {
            // SessionEnd shares Stop's canonical name but ends no turn.
            "Stop" if is_session_end(raw_event) => {}
            "Stop" => match message {
                Some(message) => {
                    self.by_session.insert(
                        session_id.to_owned(),
                        (bounded_raw(message), received_at_ms),
                    );
                }
                None => {
                    self.by_session.remove(session_id);
                }
            },
            "Start" | "UserPromptSubmit" | "StopCancelled" | "StopFailure" => {
                self.by_session.remove(session_id);
            }
            _ => {}
        }
    }

    /// The reply for a finished edge at `now_ms`, consumed either way.
    pub fn take(&mut self, session_id: &str, now_ms: u64) -> Option<String> {
        let (message, received_at_ms) = self.by_session.remove(session_id)?;
        (now_ms.saturating_sub(received_at_ms) <= MAX_REPLY_AGE_MS).then_some(message)
    }

    pub fn retain(&mut self, mut live: impl FnMut(&str) -> bool) {
        self.by_session.retain(|id, _| live(id));
    }
}

/// The notification text for `raw`, or `None` when nothing readable is left.
pub fn snippet(raw: &str) -> Option<String> {
    let mut prose = String::new();
    for paragraph in paragraphs(&sanitize(raw)) {
        if prose.chars().count() > MAX_SNIPPET_CHARS {
            break;
        }
        if !prose.is_empty() {
            prose.push(' ');
        }
        prose.push_str(&paragraph);
    }
    let prose = prose.split_whitespace().collect::<Vec<_>>().join(" ");
    (!prose.is_empty()).then(|| truncate_on_word(&prose, MAX_SNIPPET_CHARS))
}

/// Cap a raw reply before it is queued, on a character boundary.
pub fn bounded_raw(raw: &str) -> String {
    if raw.len() <= MAX_RAW_MESSAGE_BYTES {
        return raw.to_owned();
    }
    let mut end = MAX_RAW_MESSAGE_BYTES;
    while !raw.is_char_boundary(end) {
        end -= 1;
    }
    raw[..end].to_owned()
}

fn is_session_end(raw_event: &str) -> bool {
    raw_event
        .chars()
        .filter(|c| !matches!(c, '-' | '_' | ' '))
        .collect::<String>()
        .eq_ignore_ascii_case("sessionend")
}

/// Invisible format characters: bidi controls, zero-width characters, soft
/// hyphen, BOM, interlinear annotations, variation selectors, and the tag
/// block — anything that could hide text in a banner or pad its length.
fn is_invisible_format(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{0600}'..='\u{0605}'
            | '\u{061C}'
            | '\u{06DD}'
            | '\u{070F}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FE00}'..='\u{FE0F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
            | '\u{E0000}'..='\u{E007F}'
            | '\u{E0100}'..='\u{E01EF}'
    )
}

/// Keep line structure (any line or paragraph separator becomes `\n`), turn
/// tabs into spaces, and drop every other control and invisible character.
fn sanitize(raw: &str) -> String {
    raw.replace("\r\n", "\n")
        .chars()
        .filter_map(|c| match c {
            '\n' | '\r' | '\u{2028}' | '\u{2029}' => Some('\n'),
            '\t' => Some(' '),
            c if c.is_control() || is_invisible_format(c) => None,
            c => Some(c),
        })
        .collect()
}

/// Prose paragraphs, Markdown flattened; fenced code and tables skipped.
fn paragraphs(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current: Vec<String> = Vec::new();
    let mut in_fence = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
            flush(&mut current, &mut out);
            continue;
        }
        if in_fence || trimmed.starts_with('|') || is_rule(trimmed) {
            continue;
        }
        if trimmed.is_empty() {
            flush(&mut current, &mut out);
            continue;
        }
        let flattened = flatten_inline(strip_block_marker(trimmed));
        if !flattened.is_empty() {
            current.push(flattened);
        }
    }
    flush(&mut current, &mut out);
    out
}

fn flush(current: &mut Vec<String>, out: &mut Vec<String>) {
    if !current.is_empty() {
        out.push(current.join(" "));
        current.clear();
    }
}

/// `---`, `***`, `___` horizontal rules.
fn is_rule(line: &str) -> bool {
    line.len() >= 3
        && ['-', '*', '_']
            .iter()
            .any(|&mark| line.chars().all(|c| c == mark || c == ' '))
}

/// Drop a heading, quote, or list marker at the start of a line.
fn strip_block_marker(line: &str) -> &str {
    let hashes = line.chars().take_while(|&c| c == '#').count();
    let line = if hashes > 0 && (line.len() == hashes || line[hashes..].starts_with(' ')) {
        line[hashes..].trim_start()
    } else {
        line
    };
    let line = line.trim_start_matches('>').trim_start();
    for bullet in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] {
        if let Some(rest) = line.strip_prefix(bullet) {
            return rest.trim_start();
        }
    }
    let digits = line.chars().take_while(char::is_ascii_digit).count();
    if digits > 0 {
        let rest = &line[digits..];
        if let Some(rest) = rest.strip_prefix(". ").or_else(|| rest.strip_prefix(") ")) {
            return rest.trim_start();
        }
    }
    line
}

/// `[text](url)` → `text`; emphasis and code markers removed.
fn flatten_inline(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    // Each pass either consumes a link or moves to the one `[` that can
    // still open it, so the scan stays linear on adversarial brackets.
    while let Some(open) = rest.find('[') {
        let after = &rest[open + 1..];
        let Some(close) = after.find("](") else {
            break; // No later link can complete either.
        };
        if let Some(inner) = after[..close].rfind('[') {
            // Only the last `[` before `](` can open this link.
            out.push_str(&rest[..open + 1 + inner]);
            rest = &after[inner..];
            continue;
        }
        let target = &after[close + 2..];
        let Some(end) = target.find(')') else {
            break;
        };
        out.push_str(&rest[..open]);
        out.push_str(&after[..close]);
        rest = &target[end + 1..];
    }
    out.push_str(rest);
    out.replace("**", "")
        .replace("__", "")
        .replace('`', "")
        .trim()
        .to_owned()
}

fn truncate_on_word(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_owned();
    }
    // Leave room for the ellipsis.
    let cut: String = text.chars().take(max_chars - 1).collect();
    let cut = match cut.rfind(' ') {
        Some(space) if space > cut.len() / 2 => &cut[..space],
        _ => cut.as_str(),
    };
    format!(
        "{}…",
        cut.trim_end_matches(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | ':'))
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_reply_is_kept() {
        assert_eq!(
            snippet("Fixed the parser.").as_deref(),
            Some("Fixed the parser.")
        );
    }

    #[test]
    fn markdown_is_flattened_to_prose() {
        let raw = "## Summary\n\n**Done.** Fixed the `parse_row` bug in \
                   [the parser](https://example.com/p).\n\n- added a test\n- ran `cargo test`";
        assert_eq!(
            snippet(raw).as_deref(),
            Some(
                "Summary Done. Fixed the parse_row bug in the parser. added a test ran cargo test"
            )
        );
    }

    #[test]
    fn fenced_code_and_tables_are_skipped() {
        let raw = "Changed one call:\n\n```rust\nlet x = 1;\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAll green.";
        assert_eq!(
            snippet(raw).as_deref(),
            Some("Changed one call: All green.")
        );
    }

    #[test]
    fn long_reply_is_cut_on_a_word_with_an_ellipsis() {
        let raw = "word ".repeat(200);
        let out = snippet(&raw).unwrap();
        assert!(out.chars().count() <= MAX_SNIPPET_CHARS, "{}", out.len());
        assert!(out.ends_with("word…"), "{out}");
    }

    #[test]
    fn stops_reading_paragraphs_once_full() {
        let first = "a ".repeat(130);
        let raw = format!("{first}\n\nSECOND\n\nTHIRD");
        let out = snippet(&raw).unwrap();
        assert!(!out.contains("THIRD"), "{out}");
    }

    #[test]
    fn control_and_bidi_characters_are_removed() {
        assert_eq!(
            snippet("ok\u{202E}txt.exe\u{0007} done\tnow").as_deref(),
            Some("oktxt.exe done now")
        );
    }

    #[test]
    fn invisible_format_characters_are_removed() {
        assert_eq!(
            snippet("a\u{200B}b\u{FEFF}c\u{E0041}\u{00AD}d\u{2060}").as_deref(),
            Some("abcd")
        );
        assert_eq!(snippet("\u{200B}\u{200D}\u{FE0F}"), None);
    }

    #[test]
    fn carriage_returns_and_unicode_separators_break_lines() {
        assert_eq!(
            snippet("one\r\ntwo\rthree\u{2028}four\u{2029}five").as_deref(),
            Some("one two three four five")
        );
    }

    #[test]
    fn a_hash_without_a_space_is_not_a_heading() {
        assert_eq!(snippet("#123 fixed").as_deref(), Some("#123 fixed"));
        assert_eq!(snippet("### Title").as_deref(), Some("Title"));
    }

    #[test]
    fn adversarial_brackets_stay_fast() {
        let started = std::time::Instant::now();
        let opens = format!("{}](", "[".repeat(MAX_RAW_MESSAGE_BYTES));
        let pairs = "[](".repeat(MAX_RAW_MESSAGE_BYTES / 3);
        assert!(snippet(&opens).is_some());
        assert!(snippet(&pairs).is_some());
        assert!(started.elapsed() < std::time::Duration::from_millis(200));
    }

    #[test]
    fn empty_or_unreadable_input_has_no_snippet() {
        assert_eq!(snippet(""), None);
        assert_eq!(snippet("  \n\n \t "), None);
        assert_eq!(snippet("```\ncode only\n```"), None);
        assert_eq!(snippet("---\n\u{202E}"), None);
    }

    #[test]
    fn unmatched_brackets_survive() {
        assert_eq!(
            snippet("see [note and a(b) [x](y)").as_deref(),
            Some("see [note and a(b) x")
        );
    }

    #[test]
    fn numbered_lists_and_quotes_lose_their_markers() {
        assert_eq!(
            snippet("1. first\n2) second\n> quoted").as_deref(),
            Some("first second quoted")
        );
    }

    #[test]
    fn bounded_raw_cuts_on_a_char_boundary() {
        let raw = "é".repeat(MAX_RAW_MESSAGE_BYTES);
        let out = bounded_raw(&raw);
        assert!(out.len() <= MAX_RAW_MESSAGE_BYTES);
        assert!(out.chars().all(|c| c == 'é'));
        assert_eq!(bounded_raw("short"), "short");
    }

    #[test]
    fn stop_message_is_kept_for_its_turn_only() {
        let mut messages = CompletionMessages::default();
        messages.observe("s1", "UserPromptSubmit", None, 1_000);
        messages.observe("s1", "Stop", Some("Fixed it."), 2_000);
        assert_eq!(messages.take("s1", 2_100).as_deref(), Some("Fixed it."));
        // Taken once: a later edge without a new Stop falls back.
        assert_eq!(messages.take("s1", 2_200), None);
    }

    #[test]
    fn a_stale_reply_never_labels_a_later_edge() {
        let mut messages = CompletionMessages::default();
        messages.observe("s1", "Stop", Some("old turn"), 1_000);
        assert_eq!(messages.take("s1", 1_000 + MAX_REPLY_AGE_MS + 1), None);
        messages.observe("s1", "Stop", Some("fresh"), 1_000);
        assert_eq!(
            messages.take("s1", 1_000 + MAX_REPLY_AGE_MS).as_deref(),
            Some("fresh")
        );
    }

    #[test]
    fn a_new_turn_or_cancellation_drops_the_old_message() {
        for clearing in ["Start", "UserPromptSubmit", "StopCancelled", "StopFailure"] {
            let mut messages = CompletionMessages::default();
            messages.observe("s1", "Stop", Some("old turn"), 1);
            messages.observe("s1", clearing, None, 2);
            assert_eq!(messages.take("s1", 3), None, "{clearing}");
        }
    }

    #[test]
    fn other_events_and_session_end_keep_the_message() {
        let mut messages = CompletionMessages::default();
        messages.observe("s1", "Stop", Some("reply"), 1);
        messages.observe("s1", "SubagentStop", Some("subagent text"), 2);
        messages.observe("s1", "PermissionRequest", None, 3);
        messages.observe("s1", "SessionEnd", None, 4);
        messages.observe("s1", "session_end", None, 4);
        messages.observe("s2", "Stop", Some("other session"), 5);
        assert_eq!(messages.take("s1", 6).as_deref(), Some("reply"));
    }

    #[test]
    fn a_stop_without_a_reply_forgets_the_previous_one() {
        let mut messages = CompletionMessages::default();
        messages.observe("s1", "Stop", Some("turn one"), 1);
        messages.observe("s1", "stop", None, 2);
        assert_eq!(messages.take("s1", 3), None);
    }

    #[test]
    fn retain_drops_departed_sessions() {
        let mut messages = CompletionMessages::default();
        messages.observe("gone", "Stop", Some("a"), 1);
        messages.observe("live", "Stop", Some("b"), 1);
        messages.retain(|id| id == "live");
        assert_eq!(messages.take("gone", 2), None);
        assert_eq!(messages.take("live", 2).as_deref(), Some("b"));
    }

    #[test]
    fn finished_body_prefers_the_programs_done_summary() {
        assert_eq!(
            finished_body(Some("applied 2 review nits"), Some("**Long** reply")).as_deref(),
            Some("applied 2 review nits")
        );
        assert_eq!(
            finished_body(None, Some("**Long** reply")).as_deref(),
            Some("Long reply")
        );
        assert_eq!(finished_body(Some("  "), Some("```\nx\n```")), None);
        assert_eq!(finished_body(None, None), None);
    }
}
