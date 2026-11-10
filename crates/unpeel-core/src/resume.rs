//! Provider-neutral resume/restart dispatch and shell-command helpers.
//!
//! Provider recipes live beside their runtime adapters under
//! `runtimes/<package>/adapter/resume.rs`. The generated integration registry
//! binds those recipes to legacy runtime slugs, so adding a built-in runtime
//! does not require another central provider match table.

use std::path::Path;

pub type ResumeFailureMarkers = fn(&str) -> Option<Vec<String>>;

/// Runtime-owned recipe for relaunching the same agent conversation.
///
/// A new launch runs the user's command untouched; conversation identity is
/// captured from the installed integration's hooks (`provider-session.json`)
/// and turned into a resume command here, with each runtime's documented
/// continue-last fallback when no id was captured.
#[derive(Clone, Copy)]
pub struct ResumeAdapter {
    pub resumed: fn(&str, Option<&str>) -> String,
    pub fresh: fn(&str) -> String,
    pub resume_failure_markers: Option<ResumeFailureMarkers>,
    /// Recognize Unpeel-managed storage a command already pins (older Pi
    /// launches), so cleanup and relaunch keep honoring it.
    pub managed_session_dir: Option<fn(&str, &str) -> Option<String>>,
}

impl ResumeAdapter {
    pub const fn new(resumed: fn(&str, Option<&str>) -> String, fresh: fn(&str) -> String) -> Self {
        Self {
            resumed,
            fresh,
            resume_failure_markers: None,
            managed_session_dir: None,
        }
    }

    pub const fn with_failure_markers(
        mut self,
        resume_failure_markers: ResumeFailureMarkers,
    ) -> Self {
        self.resume_failure_markers = Some(resume_failure_markers);
        self
    }

    pub const fn with_managed_session_dir(
        mut self,
        managed_session_dir: fn(&str, &str) -> Option<String>,
    ) -> Self {
        self.managed_session_dir = Some(managed_session_dir);
        self
    }
}

fn adapter(command: &str) -> Option<&'static ResumeAdapter> {
    crate::integrations::integration_for_command(command)?
        .resume_adapter
        .as_ref()
}

/// Whether `command` names a built-in runtime with a real resume recipe.
/// This is intentionally narrower than runtime observation: recognizing a
/// foreground executable is not enough to prove a command can be relaunched.
pub fn can_resume(command: &str) -> bool {
    !command.trim().is_empty() && adapter(command).is_some()
}

/// Legacy presentation-side eligibility for restarting only the agent inside
/// a live hosted terminal. Retained for compatibility; current protocol-v3
/// surfaces use [`can_resume_agent`] so an active runtime is never eligible.
pub fn can_restart_agent(command: &str, active_runtime_id: Option<&str>) -> bool {
    if !can_resume(command) {
        return false;
    }
    let Some(runtime) = crate::integrations::runtime_for_command(command) else {
        return false;
    };
    active_runtime_id
        .map(|runtime_id| runtime_id.eq_ignore_ascii_case(&runtime.legacy_slug))
        .unwrap_or(true)
}

/// Presentation-side eligibility for resuming the saved agent recipe only
/// after the hosted terminal has returned to its owned shell. A recognized
/// foreground runtime is deliberately a rejection even when it matches the
/// saved launch: Resume Agent never stops a live process. The Host repeats a
/// fresh foreground/PTY ownership check at execution time.
pub fn can_resume_agent(command: &str, active_runtime_id: Option<&str>) -> bool {
    if active_runtime_id.is_some() || !can_resume(command) {
        return false;
    }
    crate::integrations::runtime_for_command(command).is_some_and(|runtime| {
        runtime
            .capabilities
            .contains(&crate::runtime_catalog::RuntimeCapability::RestartAgent)
    })
}

/// Rewrite `command` so its next launch resumes the previous conversation.
/// A hook-captured provider id is preferred over ids already in the launch;
/// each runtime adapter owns its exact fallback and idempotency rules.
pub fn resumed(command: &str, provider_session_id: Option<&str>) -> String {
    adapter(command)
        .map(|adapter| {
            keeping_env_assignments(command, |rest| (adapter.resumed)(rest, provider_session_id))
        })
        .unwrap_or_else(|| command.to_string())
}

/// Strip the runtime's resume markers so the next launch starts fresh.
pub fn fresh(command: &str) -> String {
    adapter(command)
        .map(|adapter| keeping_env_assignments(command, adapter.fresh))
        .unwrap_or_else(|| command.to_string())
}

/// Rewrite the command after its leading `NAME=value` words and put them
/// back in front. Adapters read the executable as the first word, and the
/// assignments are part of the launch: Cline's suggested
/// `CLINE_SESSION_BACKEND_MODE=local` keeps a resumed Cline out of its hub
/// (#79).
fn keeping_env_assignments(command: &str, rewrite: impl FnOnce(&str) -> String) -> String {
    let rest = crate::integrations::shared::without_env_assignments(command);
    let assignments = command[..command.len() - rest.len()].trim();
    let rewritten = rewrite(rest);
    if assignments.is_empty() {
        rewritten
    } else {
        format!("{assignments} {rewritten}")
    }
}

/// Provider-verified markers for a precise-resume conversation-not-found
/// failure. Unknown and unverified forms return `None` and fail closed.
pub fn resume_failure_markers(command: &str) -> Option<Vec<String>> {
    adapter(command)
        .and_then(|adapter| adapter.resume_failure_markers)
        .and_then(|markers| markers(command))
}

/// Return an Unpeel-managed Pi storage directory, when the Pi adapter proves
/// the command was pinned beneath `root`.
pub fn unpeel_managed_pi_session_dir(command: &str, root: &str) -> Option<String> {
    managed_storage_path(command, Path::new(root)).map(|path| path.to_string_lossy().to_string())
}

/// Return runtime-owned storage referenced by `command`, but only when the
/// runtime adapter proves that it lives beneath `unpeel_home`. This is the
/// provider-neutral cleanup/recovery seam used by Hosts and clients; the
/// compatibility Pi-named wrapper above remains for older callers.
pub fn managed_storage_path(command: &str, unpeel_home: &Path) -> Option<std::path::PathBuf> {
    let path = adapter(command)
        .and_then(|adapter| adapter.managed_session_dir)
        .and_then(|managed| managed(command, &unpeel_home.to_string_lossy()))?;
    let path = std::path::PathBuf::from(path);
    let relative = path.strip_prefix(unpeel_home).ok()?;
    let mut components = relative.components();
    if !matches!(components.next(), Some(std::path::Component::Normal(_)))
        || components.any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        return None;
    }
    Some(path)
}

/// Shell-ish tokenizer: split on whitespace while retaining quote characters
/// so joining untouched tokens is lossless for the command forms we rewrite.
pub(crate) fn tokenize(command: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    for ch in command.chars() {
        match quote {
            Some(q) => {
                current.push(ch);
                if ch == q {
                    quote = None;
                }
            }
            None => match ch {
                '\'' | '"' => {
                    current.push(ch);
                    quote = Some(ch);
                }
                c if c.is_whitespace() => {
                    if !current.is_empty() {
                        tokens.push(std::mem::take(&mut current));
                    }
                }
                c => current.push(c),
            },
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

pub(crate) fn unquote(token: &str) -> String {
    let token = token.trim();
    if token.len() >= 2
        && ((token.starts_with('\'') && token.ends_with('\''))
            || (token.starts_with('"') && token.ends_with('"')))
    {
        token[1..token.len() - 1].to_string()
    } else {
        token.to_string()
    }
}

pub(crate) fn quoted(id: &str) -> String {
    format!("'{}'", id.replace('\'', ""))
}

fn inline_flag_value<'a>(token: &'a str, flag: &str) -> Option<&'a str> {
    token.strip_prefix(flag)?.strip_prefix('=')
}

pub(crate) fn has_resume_flag(tokens: &[String], flags: &[(&str, bool)]) -> bool {
    tokens.iter().any(|token| {
        flags
            .iter()
            .any(|(flag, _)| token == flag || inline_flag_value(token, flag).is_some())
    })
}

pub(crate) fn id_in_command(tokens: &[String], id_flags: &[&str]) -> Option<String> {
    let mut index = 0;
    while index < tokens.len() {
        if let Some(value) = id_flags
            .iter()
            .find_map(|flag| inline_flag_value(&tokens[index], flag))
        {
            let value = unquote(value);
            if !value.is_empty() && !value.starts_with('-') && value != "latest" {
                return Some(value);
            }
        } else if id_flags.contains(&tokens[index].as_str()) {
            if let Some(value) = tokens.get(index + 1) {
                let value = unquote(value);
                if !value.is_empty() && !value.starts_with('-') && value != "latest" {
                    return Some(value);
                }
            }
        }
        index += 1;
    }
    None
}

/// Strip resume flags, consuming a value only when the next token is not
/// another flag. This preserves the historical relaunch behavior.
pub(crate) fn strip_resume_flags(tokens: Vec<String>, flags: &[(&str, bool)]) -> Vec<String> {
    let mut output = Vec::new();
    let mut index = 0;
    while index < tokens.len() {
        if flags
            .iter()
            .any(|(flag, _)| inline_flag_value(&tokens[index], flag).is_some())
        {
            index += 1;
            continue;
        }
        if let Some((_, takes_value)) = flags.iter().find(|(flag, _)| *flag == tokens[index]) {
            index += 1;
            if *takes_value && index < tokens.len() && !tokens[index].starts_with('-') {
                index += 1;
            }
            continue;
        }
        output.push(tokens[index].clone());
        index += 1;
    }
    output
}

/// Strip a provider subcommand sequence wherever it occurs, plus one target
/// (`<id>` or `--last`). Used by subcommand-based resume adapters.
pub(crate) fn strip_resume_subcommand(tokens: Vec<String>, subcommand: &[&str]) -> Vec<String> {
    let mut output = Vec::new();
    let mut index = 0;
    while index < tokens.len() {
        let matches = tokens[index..]
            .iter()
            .zip(subcommand)
            .all(|(actual, expected)| actual == expected)
            && tokens.len() - index >= subcommand.len();
        if matches {
            index += subcommand.len();
            if index < tokens.len()
                && (tokens[index] == "--last" || !tokens[index].starts_with('-'))
            {
                index += 1;
            }
            continue;
        }
        output.push(tokens[index].clone());
        index += 1;
    }
    output
}

pub(crate) fn insert_subcommand(mut tokens: Vec<String>, subcommand: Vec<String>) -> Vec<String> {
    if tokens.is_empty() {
        return subcommand;
    }
    let mut output = vec![tokens.remove(0)];
    output.extend(subcommand);
    output.extend(tokens);
    output
}

/// Drop one leading provider subcommand plus its optional target.
pub(crate) fn strip_leading_subcommands(tokens: Vec<String>, names: &[&str]) -> Vec<String> {
    let Some(head) = tokens.first().cloned() else {
        return tokens;
    };
    let Some(subcommand) = tokens.get(1) else {
        return tokens;
    };
    if !names.contains(&subcommand.to_lowercase().as_str()) {
        return tokens;
    }
    let mut remainder: Vec<String> = tokens.into_iter().skip(2).collect();
    if let Some(target) = remainder.first() {
        if target == "--last" || !target.starts_with('-') {
            remainder.remove(0);
        }
    }
    let mut output = vec![head];
    output.extend(remainder);
    output
}

#[cfg(test)]
pub(crate) fn has_any_flag(tokens: &[String], flags: &[&str]) -> bool {
    tokens.iter().skip(1).any(|token| {
        flags
            .iter()
            .any(|flag| token == flag || token.starts_with(&format!("{flag}=")))
    })
}

/// First matching flag value when it has UUID shape. Picker forms and bare
/// flags are intentionally excluded.
pub(crate) fn uuid_flag_value(command: &str, flags: &[&str]) -> Option<String> {
    let tokens = tokenize(command);
    let value = id_in_command(&tokens, flags)?;
    let pieces: Vec<&str> = value.split('-').collect();
    let shape = [8usize, 4, 4, 4, 12];
    let is_uuid = pieces.len() == 5
        && pieces
            .iter()
            .zip(shape.iter())
            .all(|(part, len)| part.len() == *len && part.chars().all(|c| c.is_ascii_hexdigit()));
    is_uuid.then_some(value)
}

pub(crate) fn with_flag(mut tokens: Vec<String>, extra: &[&str]) -> Vec<String> {
    tokens.extend(extra.iter().map(|value| value.to_string()));
    tokens
}

pub(crate) fn join(tokens: Vec<String>) -> String {
    tokens.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_catalog::RuntimeCapability;

    #[test]
    fn runtime_catalog_resume_capabilities_match_adapter_callbacks() {
        for runtime in
            crate::runtime_catalog::builtin_runtime_catalog().current_platform_descriptors()
        {
            let integration = crate::integrations::integration_for_id(&runtime.legacy_slug);
            let resume_adapter = integration.and_then(|integration| integration.resume_adapter);
            let has_resume = resume_adapter.is_some();
            assert_eq!(
                runtime.capabilities.contains(&RuntimeCapability::Resume),
                has_resume,
                "resume capability drift for {}",
                runtime.slug
            );
            assert!(
                !runtime
                    .capabilities
                    .contains(&RuntimeCapability::RestartAgent)
                    || has_resume,
                "restart-agent capability requires a resume adapter for {}",
                runtime.slug
            );
        }
    }

    #[test]
    fn resume_agent_eligibility_matches_the_runtime_capability() {
        for runtime in
            crate::runtime_catalog::builtin_runtime_catalog().current_platform_descriptors()
        {
            let expected = runtime.capabilities.contains(&RuntimeCapability::Resume)
                && runtime
                    .capabilities
                    .contains(&RuntimeCapability::RestartAgent);
            for alias in &runtime.detection.command_aliases {
                assert_eq!(
                    can_resume_agent(alias, None),
                    expected,
                    "resume-agent capability drift for {} alias {alias}",
                    runtime.slug
                );
                assert!(
                    !can_resume_agent(alias, Some(&runtime.legacy_slug)),
                    "an active {} runtime must never be resume-agent eligible",
                    runtime.slug
                );
            }
        }
    }

    /// Leading `NAME=value` words are part of the launch, so every
    /// runtime's rewrite keeps them in front (#79): Cline's suggested
    /// `CLINE_SESSION_BACKEND_MODE=local` must survive a Resume, or the
    /// relaunch runs in its shared hub again.
    #[test]
    fn rewrites_keep_leading_environment_assignments() {
        let preset = "CLINE_SESSION_BACKEND_MODE=local cline";
        assert_eq!(
            resumed(preset, Some("c1")),
            "CLINE_SESSION_BACKEND_MODE=local cline --id 'c1'"
        );
        assert_eq!(
            resumed(preset, None),
            "CLINE_SESSION_BACKEND_MODE=local cline history"
        );
        assert_eq!(
            fresh("CLINE_SESSION_BACKEND_MODE=local cline history --id=old --plan"),
            "CLINE_SESSION_BACKEND_MODE=local cline --plan"
        );
        assert_eq!(
            resumed("A='x y'  B=2 cline --id old", None),
            "A='x y'  B=2 cline --id 'old'"
        );
        for runtime in
            crate::runtime_catalog::builtin_runtime_catalog().current_platform_descriptors()
        {
            let commands = runtime
                .suggested_presets
                .iter()
                .map(|preset| crate::integrations::shared::without_env_assignments(&preset.command))
                .chain(runtime.detection.command_aliases.iter().map(String::as_str));
            for command in commands.filter(|command| can_resume(command)) {
                let assigned = format!("UNPEEL_TEST_MODE=1 {command}");
                for id in [Some("id1"), None] {
                    assert_eq!(
                        resumed(&assigned, id),
                        format!("UNPEEL_TEST_MODE=1 {}", resumed(command, id)),
                        "{assigned} {id:?}"
                    );
                }
                assert_eq!(
                    fresh(&assigned),
                    format!("UNPEEL_TEST_MODE=1 {}", fresh(command)),
                    "{assigned}"
                );
            }
        }
    }

    #[test]
    fn unknown_commands_are_unchanged() {
        assert_eq!(resumed("bash -lc 'echo hi'", None), "bash -lc 'echo hi'");
        assert_eq!(fresh("htop"), "htop");
        assert!(!can_resume("bash"));
    }

    #[test]
    fn restart_requires_a_managed_launch_and_no_runtime_mismatch() {
        assert!(can_resume("claude --model opus"));
        assert!(can_resume("/opt/unpeel/bin/claude --model opus"));
        assert!(can_restart_agent("claude --model opus", Some("claude")));
        assert!(can_restart_agent(
            "/opt/unpeel/bin/claude --model opus",
            Some("claude")
        ));
        assert!(can_restart_agent("claude --model opus", None));
        assert!(!can_restart_agent("claude --model opus", Some("codex")));
        assert!(!can_restart_agent("", Some("claude")));
        assert!(!can_restart_agent("bash", None));

        assert!(can_resume_agent("claude --model opus", None));
        assert!(!can_resume_agent("claude --model opus", Some("claude")));
        assert!(!can_resume_agent("", None));
        assert!(!can_resume_agent("bash", None));
    }

    #[test]
    fn managed_storage_is_recognized_but_never_pinned_on_a_new_launch() {
        // Older Pi launches recorded `--session-dir` beneath the Unpeel home;
        // cleanup and relaunch keep honoring it, but nothing adds it now.
        assert_eq!(
            unpeel_managed_pi_session_dir("pi --yolo --session-dir '/root/pi/s1'", "/root/pi"),
            Some("/root/pi/s1".to_string())
        );
        assert_eq!(
            managed_storage_path("pi --yolo", Path::new("/root/pi")),
            None
        );
        assert_eq!(
            managed_storage_path("pi --session-dir '/elsewhere/s1'", Path::new("/root/pi")),
            None
        );
    }

    #[test]
    fn generic_flag_helpers_preserve_inline_value_compatibility() {
        let tokens = tokenize("agent --resume=thread-1 -c --model fast");
        assert_eq!(
            id_in_command(&tokens, &["--resume"]),
            Some("thread-1".into())
        );
        assert!(has_any_flag(&tokens, &["--resume"]));
        assert!(has_resume_flag(
            &tokens,
            &[("--resume", true), ("-c", false)]
        ));
        assert_eq!(
            strip_resume_flags(tokens, &[("--resume", true), ("-c", false)]),
            vec!["agent", "--model", "fast"]
        );
    }
}
