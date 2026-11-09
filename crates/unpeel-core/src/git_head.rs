//! Fork-only (#59): the `gitBranch` a Host publishes for a project, read from
//! the checkout's HEAD file without spawning `git`, so it stays cheap enough
//! to run per project on every bootstrap. Both Rust wires (`host.sock` and
//! the `/mobile/bootstrap` snapshot) use it, matching the native
//! `GitHeadReader.currentBranch`.

use std::path::{Path, PathBuf};

/// HEAD's text in a reftable repo, whose real HEAD lives in the reftable.
/// No branch can have this name: git rejects a leading `.`.
const REFTABLE_STUB: &str = "refs/heads/.invalid";

/// The branch checked out at `repo_path`, or a detached HEAD's short commit.
/// `None` when the path is no checkout root or HEAD names no branch this
/// reader can see (a reftable repo).
pub fn branch(repo_path: &str) -> Option<String> {
    let head = std::fs::read_to_string(git_dir(Path::new(repo_path))?.join("HEAD")).ok()?;
    branch_from_head(&head)
}

/// The gitdir behind `<repo>/.git`: the directory itself, or the one a
/// linked worktree's or submodule's `.git` file points at.
fn git_dir(repo: &Path) -> Option<PathBuf> {
    let git_entry = repo.join(".git");
    if std::fs::metadata(&git_entry).ok()?.is_dir() {
        return Some(git_entry);
    }
    let contents = std::fs::read_to_string(&git_entry).ok()?;
    let gitdir = contents
        .lines()
        .find_map(|line| line.strip_prefix("gitdir:"))?
        .trim();
    // `join` keeps an absolute gitdir as it is.
    Some(repo.join(gitdir))
}

/// A symbolic HEAD names the ref after `refs/heads/`, or after `refs/<kind>/`
/// for one outside the branches (`refs/remotes/origin/main` is
/// `origin/main`), the same rule as the Mac's `WorktreeGit.checkedOutBranch`.
/// A detached HEAD keeps its short commit.
fn branch_from_head(head: &str) -> Option<String> {
    let head = head.trim();
    let Some(target) = head.strip_prefix("ref:").map(str::trim) else {
        return (!head.is_empty()).then(|| head.chars().take(7).collect());
    };
    if target == REFTABLE_STUB {
        return None;
    }
    let name = target
        .strip_prefix("refs/")
        .and_then(|rest| rest.split_once('/'))
        .map_or(target, |(_, name)| name);
    (!name.is_empty()).then(|| name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn head_text_names_the_branch_or_the_detached_commit() {
        for (head, expected) in [
            ("ref: refs/heads/main\n", Some("main")),
            ("ref: refs/heads/feat/some-thing\n", Some("feat/some-thing")),
            ("ref: refs/remotes/origin/main\n", Some("origin/main")),
            ("ref: refs/tags/v1\n", Some("v1")),
            ("ref: refs/heads/.invalid\n", None),
            (
                "1976b60d4f0d6c7e8a9b0c1d2e3f405162738495\n",
                Some("1976b60"),
            ),
            ("", None),
            ("\n", None),
        ] {
            assert_eq!(branch_from_head(head).as_deref(), expected, "{head:?}");
        }
    }

    #[test]
    fn a_git_file_is_followed_to_its_gitdir() {
        let root = tempfile::tempdir().unwrap();
        let repo = root.path().join("repo");
        std::fs::create_dir_all(repo.join(".git/modules/sub")).unwrap();
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(
            repo.join(".git/modules/sub/HEAD"),
            "ref: refs/heads/sub-branch\n",
        )
        .unwrap();
        let worktree_gitdir = repo.join(".git/worktrees/linked");
        std::fs::create_dir_all(&worktree_gitdir).unwrap();
        std::fs::write(worktree_gitdir.join("HEAD"), "ref: refs/heads/linked\n").unwrap();

        let linked = root.path().join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        std::fs::write(
            linked.join(".git"),
            format!("gitdir: {}\n", worktree_gitdir.display()),
        )
        .unwrap();
        let sub = repo.join("sub");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join(".git"), "gitdir: ../.git/modules/sub\n").unwrap();

        assert_eq!(branch(repo.to_str().unwrap()).as_deref(), Some("main"));
        assert_eq!(branch(linked.to_str().unwrap()).as_deref(), Some("linked"));
        assert_eq!(branch(sub.to_str().unwrap()).as_deref(), Some("sub-branch"));
        assert_eq!(branch(root.path().to_str().unwrap()), None);
        assert_eq!(branch(repo.join("missing").to_str().unwrap()), None);
    }
}
