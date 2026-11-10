use std::path::Path;

/// The basename of the executable a command runs. Leading `NAME=value`
/// environment assignments are skipped the way the shell reads them, so
/// `CLINE_SESSION_BACKEND_MODE=local cline` names `cline` (#79).
pub fn command_head(command: &str) -> &str {
    let head = without_env_assignments(command)
        .split_whitespace()
        .next()
        .unwrap_or_default();
    Path::new(head)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(head)
}

/// `command` from its first word that is not a leading `NAME=value`
/// environment assignment. A quoted value is one word (`A='x y' cline`).
pub fn without_env_assignments(command: &str) -> &str {
    let mut rest = command.trim_start();
    loop {
        let (word, after) = split_first_word(rest);
        if !is_env_assignment(word) {
            return rest;
        }
        rest = after.trim_start();
    }
}

/// The first shell word of a command that starts at a word (quotes kept),
/// and the text after it.
fn split_first_word(command: &str) -> (&str, &str) {
    let mut quote = None;
    for (index, character) in command.char_indices() {
        match quote {
            Some(open) if character == open => quote = None,
            Some(_) => {}
            None if character == '\'' || character == '"' => quote = Some(character),
            None if character.is_whitespace() => return command.split_at(index),
            None => {}
        }
    }
    (command, "")
}

/// A `NAME=value` word a POSIX shell takes as an environment assignment for
/// the command that follows, not as the command itself.
pub fn is_env_assignment(token: &str) -> bool {
    let Some((name, _)) = token.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|first| first == '_' || first.is_ascii_alphabetic())
        && chars.all(|character| character == '_' || character.is_ascii_alphanumeric())
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r#"'"'"'"#))
}

pub fn shell_name(shell_path: &str) -> String {
    Path::new(shell_path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(shell_path)
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_head_skips_leading_environment_assignments() {
        assert_eq!(
            command_head("CLINE_SESSION_BACKEND_MODE=local cline"),
            "cline"
        );
        assert_eq!(
            command_head("  A=1 _B2=x /opt/unpeel/bin/codex --no-daemon"),
            "codex"
        );
        assert_eq!(command_head("EMPTY= cline --plan"), "cline");
        assert_eq!(command_head("A='x y' /tmp/bin/cline --plan"), "cline");
        assert_eq!(command_head("cline"), "cline");
        assert_eq!(command_head("FOO=bar"), "");
        assert_eq!(command_head(""), "");
        // Not assignments: a shell runs these words as the command.
        assert_eq!(command_head("=x cline"), "=x");
        assert_eq!(command_head("1A=x cline"), "1A=x");
        assert_eq!(command_head("A-B=x cline"), "A-B=x");
    }

    #[test]
    fn without_env_assignments_starts_at_the_command() {
        assert_eq!(
            without_env_assignments(" A=1  B=2 cline --plan"),
            "cline --plan"
        );
        assert_eq!(without_env_assignments("cline A=1"), "cline A=1");
        assert_eq!(without_env_assignments("A=1"), "");
        assert_eq!(without_env_assignments("A='x y' B=\"1 2\" cline"), "cline");
        assert_eq!(without_env_assignments("'A=1 cline'"), "'A=1 cline'");
    }

    #[test]
    fn env_assignment_is_a_shell_name_then_equals() {
        assert!(is_env_assignment("CLINE_SESSION_BACKEND_MODE=local"));
        assert!(is_env_assignment("_=x"));
        assert!(is_env_assignment("a1="));
        assert!(!is_env_assignment("cline"));
        assert!(!is_env_assignment("--flag=value"));
        assert!(!is_env_assignment("=value"));
        assert!(!is_env_assignment("9LIVES=x"));
    }
}
