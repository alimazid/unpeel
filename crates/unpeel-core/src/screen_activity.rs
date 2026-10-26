//! Screen-derived busy/idle for recognized agents whose Unpeel integration
//! is not installed (the Herdr-style fallback tier).
//!
//! Hooks stay the authority: this classifier is consulted only while a
//! Session has no hook latch. Each runtime package that opts in declares
//! `[screen]` rules in its `runtime.toml` (`lifecycle.fallback = "screen"`):
//! `working` markers are substrings a working agent shows near the bottom
//! of its screen (a spinner line, "esc to interrupt"), `idle_prompt` markers
//! are what the first non-blank characters of its input prompt line look
//! like. The Host runs this against the parsed viewport on its existing
//! 500 ms scan and edge-writes the verdict into the manifest; the worker
//! turns it into a lower-confidence status that never sends completion
//! notifications.

use serde::{Deserialize, Serialize};

/// How many non-blank lines from the bottom of the screen the rules see.
/// Agent status lines and prompts live at the bottom; anything above is
/// conversation and must not keep a Session "working".
const BOTTOM_WINDOW_LINES: usize = 15;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScreenActivity {
    Working,
    Idle,
}

impl ScreenActivity {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Idle => "idle",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "working" => Some(Self::Working),
            "idle" => Some(Self::Idle),
            _ => None,
        }
    }
}

/// The rules the catalog declares for `legacy_slug`, when that runtime opts
/// into the screen fallback.
pub fn rules_for_runtime(
    legacy_slug: &str,
) -> Option<&'static crate::runtime_catalog::RuntimeScreenRules> {
    let runtime = crate::runtime_catalog::builtin_runtime_catalog().by_legacy_slug(legacy_slug)?;
    if runtime.lifecycle.fallback != crate::runtime_catalog::RuntimeLifecycleFallback::Screen {
        return None;
    }
    runtime.screen.as_ref()
}

/// Classify a parsed screen. `None` means the rules recognized nothing, so
/// the previous verdict stands.
pub fn classify(
    screen_text: &str,
    rules: &crate::runtime_catalog::RuntimeScreenRules,
) -> Option<ScreenActivity> {
    let bottom: Vec<&str> = screen_text
        .lines()
        .rev()
        .filter(|line| !line.trim().is_empty())
        .take(BOTTOM_WINDOW_LINES)
        .collect();
    if bottom.is_empty() {
        return None;
    }
    let working = bottom.iter().any(|line| {
        let lowered = line.to_lowercase();
        rules
            .working
            .iter()
            .any(|marker: &String| lowered.contains(&marker.to_lowercase()))
    });
    if working {
        return Some(ScreenActivity::Working);
    }
    let idle = bottom.iter().any(|line| {
        let trimmed = line.trim_start();
        rules
            .idle_prompt
            .iter()
            .any(|marker: &String| trimmed.starts_with(marker.as_str()))
    });
    idle.then_some(ScreenActivity::Idle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_catalog::RuntimeScreenRules;

    fn claude_rules() -> RuntimeScreenRules {
        RuntimeScreenRules {
            working: vec!["… (".into(), "esc to interrupt".into()],
            idle_prompt: vec!["❯".into()],
        }
    }

    #[test]
    fn claude_working_line_wins_over_the_always_visible_prompt() {
        // Captured from Claude Code 2.1.27x: the input prompt stays on
        // screen while the spinner line runs above it.
        let working = "✽ Levitating… (1m 52s · ↓ 5.1k tokens)\n  ⎿  Tip: Use /btw\n────\n❯\n────\n  ⏵⏵ auto mode on";
        assert_eq!(
            classify(working, &claude_rules()),
            Some(ScreenActivity::Working)
        );
        let muse_like = "◇ Double checking (5s · esc to interrupt)\n── Voice input ──\n❯";
        assert_eq!(
            classify(muse_like, &claude_rules()),
            Some(ScreenActivity::Working)
        );
        let idle =
            "✻ Brewed for 3s · done 10:05 AM\n   97533 tokens\n────\n❯\n────\n  ⏵⏵ auto mode on";
        assert_eq!(classify(idle, &claude_rules()), Some(ScreenActivity::Idle));
    }

    #[test]
    fn unknown_screens_leave_the_previous_verdict_alone() {
        assert_eq!(classify("", &claude_rules()), None);
        assert_eq!(
            classify("just some shell output\n$ ", &claude_rules()),
            None
        );
        // A working marker far above the bottom window is conversation, not
        // status.
        let mut lines = vec!["old: Thinking… (9s)".to_string()];
        lines.extend((0..20).map(|i| format!("line {i}")));
        assert_eq!(classify(&lines.join("\n"), &claude_rules()), None);
    }

    #[test]
    fn codex_prompt_and_working_shapes() {
        let rules = RuntimeScreenRules {
            working: vec!["esc to interrupt".into(), "• Working".into()],
            idle_prompt: vec!["›".into()],
        };
        let idle = "────\n⠁      ⠄\n› Ask Codex to do anything\n  gpt-6-astra xhigh · ~/Dev/unpeel";
        assert_eq!(classify(idle, &rules), Some(ScreenActivity::Idle));
        let working = "• Working (12s • Esc to interrupt)\n› ";
        assert_eq!(classify(working, &rules), Some(ScreenActivity::Working));
    }

    #[test]
    fn catalog_rules_exist_only_behind_the_screen_fallback() {
        assert!(rules_for_runtime("claude").is_some());
        assert!(rules_for_runtime("codex").is_some());
        assert!(rules_for_runtime("pi").is_none());
        assert!(rules_for_runtime("not-a-runtime").is_none());
    }

    /// Bottoms of real Codewhale 0.10.2 screens.
    #[test]
    fn codewhale_composer_footer_and_approval_shapes() {
        let rules = rules_for_runtime("codewhale").expect("codewhale screen rules");
        let idle =
            "● stub reply\n╭────╮\n│❯ Type a message…      │\n│                  [·] │\n╰────╯\n \
                    ● ask  Shift+Tab to change   work (Tab)   Work bar (Ctrl+])\n \
                    DeepSeek · deepseek-flash · thinking: max   context 1%";
        assert_eq!(classify(idle, rules), Some(ScreenActivity::Idle));
        let working =
            "▎ say hello\n╭────╮\n│❯ Type a follow-up…    │\n│                  [·] │\n╰────╯\n \
                       ● ask  Shift+Tab to change   work (Tab)   working 11s   Esc to interrupt\n \
                       DeepSeek · deepseek-flash · thinking: max";
        assert_eq!(classify(working, rules), Some(ScreenActivity::Working));
        // The approval panel replaces the composer and its cursor row is a
        // bare `❯`: no verdict, so the previous one stands.
        let approval =
            "● $ touch made-by-fake · waiting for approval\n  Do you want to proceed?\n  \
                        [1 / y] Allow once\n  [2 / a] Allow for this conversation\n\
                        ❯ [3 / d / n] Don't allow (Enter)\n  [Esc] Stop this turn\n  \
                        Pg↑/↓ review  ·  ⌥V details  ·  Esc stop";
        assert_eq!(classify(approval, rules), None);
    }
}
