use crate::resume::{
    id_in_command, join, quoted, strip_resume_flags, tokenize, with_flag, ResumeAdapter,
};

const RESUME_FLAGS: &[(&str, bool)] = &[("--id", true)];

fn strip_history_subcommand(mut tokens: Vec<String>) -> Vec<String> {
    if tokens
        .get(1)
        .is_some_and(|value| value.eq_ignore_ascii_case("history"))
    {
        tokens.remove(1);
    }
    tokens
}

/// Split off leading `NAME=value` words, such as the suggested preset's
/// `CLINE_SESSION_BACKEND_MODE=local`, so every rewrite keeps them in front:
/// a relaunch without it would run in the shared hub again (#79).
fn split_env_assignments(command: &str) -> (Vec<String>, Vec<String>) {
    let mut assignments = tokenize(command);
    let count = assignments
        .iter()
        .take_while(|token| crate::integrations::shared::is_env_assignment(token))
        .count();
    let tokens = assignments.split_off(count);
    (assignments, tokens)
}

fn resumed(command: &str, provider_session_id: Option<&str>) -> String {
    let (assignments, tokens) = split_env_assignments(command);
    let has_history_subcommand = tokens
        .get(1)
        .is_some_and(|value| value.eq_ignore_ascii_case("history"));
    let id = provider_session_id
        .map(str::to_string)
        .filter(|id| !id.is_empty())
        .or_else(|| id_in_command(&tokens, &["--id"]));
    let stripped = strip_history_subcommand(strip_resume_flags(tokens, RESUME_FLAGS));
    let relaunch = match id {
        Some(id) => with_flag(stripped, &["--id", &quoted(&id)]),
        // Cline has no continue-last flag; its history picker is the fallback.
        None if has_history_subcommand => return command.trim().to_string(),
        None => vec!["cline".to_string(), "history".to_string()],
    };
    join([assignments, relaunch].concat())
}

fn fresh(command: &str) -> String {
    let (assignments, tokens) = split_env_assignments(command);
    let stripped = strip_history_subcommand(strip_resume_flags(tokens, RESUME_FLAGS));
    join([assignments, stripped].concat())
}

pub(super) const ADAPTER: ResumeAdapter = ResumeAdapter::new(resumed, fresh);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_exact_id_or_history_picker() {
        assert_eq!(resumed("cline", Some("c1")), "cline --id 'c1'");
        assert_eq!(resumed("cline --plan", None), "cline history");
        assert_eq!(
            resumed("cline history --plan", None),
            "cline history --plan"
        );
        assert_eq!(resumed("cline history", Some("c1")), "cline --id 'c1'");
        assert_eq!(fresh("cline history --id=old --plan"), "cline --plan");
    }

    /// The suggested preset's backend assignment survives every rewrite, or
    /// a resumed Cline would go back to the shared hub (#79).
    #[test]
    fn keeps_leading_environment_assignments() {
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
            resumed(
                "CLINE_SESSION_BACKEND_MODE=local cline history --plan",
                None
            ),
            "CLINE_SESSION_BACKEND_MODE=local cline history --plan"
        );
        assert_eq!(
            resumed("CLINE_SESSION_BACKEND_MODE=local cline history", Some("c1")),
            "CLINE_SESSION_BACKEND_MODE=local cline --id 'c1'"
        );
        assert_eq!(
            fresh("CLINE_SESSION_BACKEND_MODE=local cline history --id=old --plan"),
            "CLINE_SESSION_BACKEND_MODE=local cline --plan"
        );
        assert_eq!(
            resumed("A='x y' cline --id old", None),
            "A='x y' cline --id 'old'"
        );
    }
}
