use crate::resume::{
    id_in_command, join, quoted, strip_leading_subcommands, strip_resume_flags, tokenize, unquote,
    with_flag, ResumeAdapter,
};

/// Codewhale's conversation flags: `-c/--continue` (most recent session in
/// this workspace), `-r/--resume <id|prefix>` and its `--session-id` alias.
/// `--fresh` opts out of automatic resume, so it never survives a resume.
const RESUME_FLAGS: &[(&str, bool)] = &[
    ("-c", false),
    ("--continue", false),
    ("--fresh", false),
    ("-r", true),
    ("--resume", true),
    ("--session-id", true),
];
const ID_FLAGS: &[&str] = &["--resume", "-r", "--session-id"];

/// `codewhale resume <id>` is the subcommand spelling of `--resume <id>`.
fn embedded_resume_id(tokens: &[String]) -> Option<String> {
    if tokens.get(1).is_none_or(|value| value != "resume") {
        return None;
    }
    tokens
        .get(2)
        .filter(|value| !value.starts_with('-'))
        .map(|value| unquote(value))
        .filter(|value| !value.is_empty())
}

fn without_resume_forms(tokens: Vec<String>) -> Vec<String> {
    strip_resume_flags(strip_leading_subcommands(tokens, &["resume"]), RESUME_FLAGS)
}

fn resumed(command: &str, provider_session_id: Option<&str>) -> String {
    let tokens = tokenize(command);
    // The reporter captures the saved session Codewhale holds open at each
    // turn end; before that, a session the launch command named still wins.
    let id = provider_session_id
        .map(str::to_string)
        .filter(|id| !id.is_empty())
        .or_else(|| embedded_resume_id(&tokens))
        .or_else(|| id_in_command(&tokens, ID_FLAGS));
    let stripped = without_resume_forms(tokens);
    match id {
        Some(id) => join(with_flag(stripped, &["--resume", &quoted(&id)])),
        // New launches run `codewhale` as typed, so continue-last is
        // Codewhale's own most recent session for this workspace.
        None => join(with_flag(stripped, &["--continue"])),
    }
}

fn fresh(command: &str) -> String {
    join(without_resume_forms(tokenize(command)))
}

pub(super) const ADAPTER: ResumeAdapter = ResumeAdapter::new(resumed, fresh);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continue_last_is_the_resume_without_a_captured_id() {
        assert_eq!(resumed("codewhale", None), "codewhale --continue");
        assert_eq!(
            resumed("codew --model flash", None),
            "codew --model flash --continue"
        );
        assert_eq!(resumed("codewhale -c", None), "codewhale --continue");
        assert_eq!(resumed("codewhale --fresh", None), "codewhale --continue");
    }

    #[test]
    fn named_sessions_resume_exactly_in_flag_spelling() {
        let id = "528c609b-4571-4550-9deb-454c46fa9871";
        assert_eq!(
            resumed(&format!("codewhale resume {id}"), None),
            format!("codewhale --resume '{id}'")
        );
        assert_eq!(
            resumed("codewhale --session-id abc --model flash", None),
            "codewhale --model flash --resume 'abc'"
        );
        assert_eq!(
            resumed("codewhale -r old -c", Some("new")),
            "codewhale --resume 'new'"
        );
    }

    #[test]
    fn fresh_drops_every_resume_form() {
        assert_eq!(
            fresh("codewhale --continue --model flash"),
            "codewhale --model flash"
        );
        assert_eq!(fresh("codewhale resume abc"), "codewhale");
        assert_eq!(fresh("codewhale -r abc --fresh"), "codewhale");
        // Only the leading subcommand is a resume form; prompt words are not.
        assert_eq!(
            fresh("codewhale fix resume flow"),
            "codewhale fix resume flow"
        );
    }
}
