//! Fork-only: unit tests for `supervision_worktrees`, against a temp
//! ledger, temp session dirs and temp git repos, never the real home.

use super::*;
use std::path::Path;

fn entry(path: &str, owner: &str) -> Entry {
    Entry {
        path: path.into(),
        branch: "fix".into(),
        base_ref: Some("main".into()),
        repo_path: "/work/p".into(),
        project_id: "mcp-wt-1".into(),
        owner_session_id: owner.into(),
        created_at: 7,
    }
}

#[test]
fn the_ledger_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("supervision").join("worktrees.json");
    Ledger::at(path.clone())
        .record(entry("/wt/fix", "w-1"), false)
        .unwrap();

    // A new process reads the same file.
    assert_eq!(
        Ledger::at(path).entries().unwrap(),
        vec![entry("/wt/fix", "w-1")]
    );
}

fn temp_ledger() -> (tempfile::TempDir, Ledger) {
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::at(dir.path().join("supervision").join("worktrees.json"));
    (dir, ledger)
}

#[test]
fn an_adopted_worktree_the_router_never_made_is_not_recorded() {
    let (_dir, ledger) = temp_ledger();
    // Made by hand or by the desktop: never ours to remove.
    ledger.record(entry("/wt/manual", "w-1"), true).unwrap();
    assert_eq!(ledger.entries().unwrap(), vec![]);
}

#[test]
fn a_worker_adopting_a_recorded_worktree_becomes_its_owner() {
    let (_dir, ledger) = temp_ledger();
    ledger.record(entry("/wt/fix", "w-1"), false).unwrap();
    ledger
        .record(
            Entry {
                created_at: 99,
                ..entry("/wt/fix", "w-2")
            },
            true,
        )
        .unwrap();
    // Same worktree, new owner; when it was made doesn't change.
    assert_eq!(ledger.entries().unwrap(), vec![entry("/wt/fix", "w-2")]);
}

#[test]
fn recording_the_same_path_again_replaces_the_entry() {
    let (_dir, ledger) = temp_ledger();
    ledger.record(entry("/wt/fix", "w-1"), false).unwrap();
    ledger.record(entry("/wt/other", "w-1"), false).unwrap();
    ledger.record(entry("/wt/fix", "w-3"), false).unwrap();
    assert_eq!(
        ledger.entries().unwrap(),
        vec![entry("/wt/other", "w-1"), entry("/wt/fix", "w-3")]
    );
}

#[test]
fn a_ledger_that_does_not_parse_is_never_overwritten() {
    let (_dir, ledger) = temp_ledger();
    std::fs::create_dir_all(ledger.path.parent().unwrap()).unwrap();
    std::fs::write(&ledger.path, "{ not json").unwrap();
    assert!(ledger.record(entry("/wt/fix", "w-1"), false).is_err());
    assert_eq!(std::fs::read_to_string(&ledger.path).unwrap(), "{ not json");
}

/// `git` in `dir`, as a test author with no signing; panics on failure.
fn git(dir: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// A temp workspace: repo `p` on `main`, a worktree on branch `fix`
/// registered as child project `mcp-wt-1`, recorded on the ledger as Worker
/// `w-1`'s, and an empty `app-sessions/` (so `w-1` is gone).
struct Fixture {
    _dir: tempfile::TempDir,
    repo: PathBuf,
    wt: PathBuf,
    sessions_root: PathBuf,
    state: PathBuf,
    ledger: Ledger,
}

const WORKTREE_PROJECT: &str = "mcp-wt-1";

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "-b", "main"]);
    git(&repo, &["commit", "--quiet", "--allow-empty", "-m", "init"]);
    let wt = dir.path().join("wts").join("fix");
    git(
        &repo,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "fix",
            &wt.to_string_lossy(),
        ],
    );
    let sessions_root = dir.path().join("app-sessions");
    std::fs::create_dir_all(&sessions_root).unwrap();
    let state = dir.path().join("app-state.json");
    let document = serde_json::json!({
        "projects": [
            { "id": "p", "name": "P", "path": repo },
            { "id": WORKTREE_PROJECT, "name": "fix", "path": wt, "parent_project_id": "p", "worktree_branch": "fix" },
        ],
        "desktop_only_key": { "kept": true },
    });
    std::fs::write(&state, document.to_string()).unwrap();
    let ledger = Ledger::at(dir.path().join("supervision").join("worktrees.json"));
    let fixture = Fixture {
        _dir: dir,
        repo,
        wt,
        sessions_root,
        state,
        ledger,
    };
    fixture.ledger.record(fixture.entry(None), false).unwrap();
    fixture
}

impl Fixture {
    fn entry(&self, base_ref: Option<&str>) -> Entry {
        Entry {
            path: self.wt.to_string_lossy().to_string(),
            branch: "fix".into(),
            base_ref: base_ref.map(str::to_string),
            repo_path: self.repo.to_string_lossy().to_string(),
            project_id: WORKTREE_PROJECT.into(),
            owner_session_id: "w-1".into(),
            created_at: 1,
        }
    }

    /// A commit on `fix`, made in the worktree.
    fn commit_in_worktree(&self, file: &str) {
        std::fs::write(self.wt.join(file), "work").unwrap();
        git(&self.wt, &["add", file]);
        git(&self.wt, &["commit", "--quiet", "-m", file]);
    }

    /// The Worker merges its branch into `main` in the main checkout.
    fn merge(&self) {
        git(&self.repo, &["merge", "--quiet", "--no-edit", "fix"]);
    }

    /// Mirrors `worktrees::remove` (run git from the worktree's toplevel,
    /// never `--force`) minus its managed-root check, which reads the
    /// process-global home.
    fn remove(path: &str) -> Result<(), String> {
        let toplevel = crate::worktrees::repo_toplevel(path)?;
        let output = std::process::Command::new("git")
            .args(["-C", &toplevel, "worktree", "remove", path])
            .output()
            .map_err(|error| error.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&output.stderr).to_string())
        }
    }

    fn sweep(&self) -> Vec<Outcome> {
        self.sweep_with(&Self::remove)
    }

    fn sweep_with(&self, remove: &dyn Fn(&str) -> Result<(), String>) -> Vec<Outcome> {
        let unregister = |entry: &Entry| {
            crate::app_state::edit_at(&self.state, |state| Ok(unregister_in(state, entry)))
                .map(|_| ())
        };
        sweep_at(&Sweep {
            ledger: &self.ledger,
            sessions_root: &self.sessions_root,
            remove_worktree: remove,
            unregister: &unregister,
        })
    }

    fn outcome(&self, verdict: Verdict) -> Vec<Outcome> {
        vec![Outcome {
            path: self.wt.to_string_lossy().to_string(),
            verdict,
        }]
    }

    fn project_ids(&self) -> Vec<String> {
        let state: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&self.state).unwrap()).unwrap();
        state["projects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|project| project["id"].as_str().unwrap().to_string())
            .collect()
    }

    fn assert_kept(&self) {
        assert!(self.wt.is_dir(), "the worktree stays");
        assert_eq!(self.project_ids(), ["p", WORKTREE_PROJECT]);
        assert_eq!(self.ledger.entries().unwrap().len(), 1, "the entry stays");
    }
}

#[test]
fn a_merged_clean_worktree_of_a_removed_worker_is_removed() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();

    assert_eq!(fx.sweep(), fx.outcome(Verdict::Removed));
    assert!(!fx.wt.exists(), "the folder is gone");
    assert!(!git(&fx.repo, &["worktree", "list"]).contains("wts"));
    assert_eq!(fx.project_ids(), ["p"], "the child project is unregistered");
    assert_eq!(fx.ledger.entries().unwrap(), vec![]);
    // The branch is the Worker's merged history: it stays.
    git(
        &fx.repo,
        &["rev-parse", "--verify", "--quiet", "refs/heads/fix"],
    );
    let state: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&fx.state).unwrap()).unwrap();
    assert_eq!(state["desktop_only_key"]["kept"], true);
    // Nothing is left to sweep.
    assert_eq!(fx.sweep(), vec![]);
}

#[test]
fn an_unmerged_worktree_is_kept() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");

    assert_eq!(fx.sweep(), fx.outcome(Verdict::Unmerged));
    fx.assert_kept();
    // Still kept on the next pass.
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Unmerged));
}

#[test]
fn a_dirty_worktree_is_kept_even_when_merged() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();

    // An untracked file.
    std::fs::write(fx.wt.join("notes.txt"), "draft").unwrap();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Dirty));
    fx.assert_kept();

    // An uncommitted change to a tracked file.
    std::fs::remove_file(fx.wt.join("notes.txt")).unwrap();
    std::fs::write(fx.wt.join("fix.txt"), "more work").unwrap();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Dirty));
    fx.assert_kept();
}

#[test]
fn a_worktree_whose_owner_still_exists_is_kept() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();
    // Stopped or running, the Worker's session dir is still there.
    std::fs::create_dir_all(fx.sessions_root.join("w-1")).unwrap();

    assert_eq!(fx.sweep(), fx.outcome(Verdict::OwnerAlive));
    fx.assert_kept();
}

#[test]
fn a_worktree_another_session_works_in_is_kept() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();
    let wt = fx.wt.to_string_lossy().to_string();
    let manifests = [
        // The user restarted the Worker: a new id, same folder.
        serde_json::json!({ "cwd": format!("{wt}/src"), "session": { "project_id": "p" } }),
        // Started in the worktree's project.
        serde_json::json!({ "cwd": "/elsewhere", "session": { "project_id": WORKTREE_PROJECT } }),
        serde_json::json!({ "cwd": "/elsewhere", "session": { "project_id": "p", "worktree_path": wt } }),
    ];
    for manifest in manifests {
        let dir = fx.sessions_root.join("w-2");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("manifest.json"), manifest.to_string()).unwrap();
        assert_eq!(
            fx.sweep(),
            fx.outcome(Verdict::InUse("w-2".into())),
            "{manifest}"
        );
        fx.assert_kept();
    }

    // Moved into the worktree's project from elsewhere.
    let dir = fx.sessions_root.join("w-3");
    std::fs::remove_dir_all(fx.sessions_root.join("w-2")).unwrap();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("project-override.json"),
        serde_json::json!({ "project_id": WORKTREE_PROJECT, "moved_at": 1 }).to_string(),
    )
    .unwrap();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::InUse("w-3".into())));
    fx.assert_kept();
}

#[test]
fn commits_checked_out_off_the_branch_count_as_unmerged() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();
    // Detached commits live only in the worktree's HEAD.
    git(&fx.wt, &["checkout", "--quiet", "--detach"]);
    fx.commit_in_worktree("loose.txt");

    assert_eq!(fx.sweep(), fx.outcome(Verdict::Unmerged));
    fx.assert_kept();
}

#[test]
fn a_named_base_is_checked_and_its_local_branch_counts_for_a_remote_one() {
    let fx = fixture();
    let start = git(&fx.repo, &["rev-parse", "HEAD"]);
    git(
        &fx.repo,
        &["update-ref", "refs/remotes/origin/main", &start],
    );
    fx.ledger
        .record(fx.entry(Some("origin/main")), false)
        .unwrap();
    fx.commit_in_worktree("fix.txt");
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Unmerged));

    // Merged into local `main`, not pushed: nothing is lost by removing it.
    fx.merge();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Removed));
}

#[test]
fn a_base_that_does_not_contain_the_branch_keeps_it() {
    let fx = fixture();
    git(&fx.repo, &["branch", "release"]);
    fx.ledger.record(fx.entry(Some("release")), false).unwrap();
    fx.commit_in_worktree("fix.txt");
    // In `main`, but the Router named `release`.
    fx.merge();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Unmerged));
    fx.assert_kept();
}

#[test]
fn a_failed_removal_keeps_the_project_and_the_entry() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();
    let refuse = |_: &str| Err("refusing to remove a worktree Unpeel does not manage".to_string());

    assert_eq!(
        fx.sweep_with(&refuse),
        fx.outcome(Verdict::Failed(
            "refusing to remove a worktree Unpeel does not manage".into()
        ))
    );
    fx.assert_kept();
}

#[test]
fn only_the_worktree_project_for_that_folder_is_unregistered() {
    let mut state = serde_json::json!({
        "projects": [
            { "id": "p", "path": "/work/p" },
            { "id": "mcp-wt-1", "path": "/wt/fix", "parent_project_id": "p", "worktree_branch": "fix" },
        ],
    });
    let object = state.as_object_mut().unwrap();
    // Re-pointed at another folder since: someone else's now.
    assert!(!unregister_in(object, &entry("/wt/elsewhere", "w-1")));
    assert!(unregister_in(object, &entry("/wt/fix", "w-1")));
    assert_eq!(
        state["projects"],
        serde_json::json!([{ "id": "p", "path": "/work/p" }])
    );
}

#[test]
fn a_worktree_folder_that_is_gone_is_kept_on_the_ledger() {
    let fx = fixture();
    std::fs::remove_dir_all(&fx.wt).unwrap();
    assert_eq!(fx.sweep(), fx.outcome(Verdict::Missing));
    assert_eq!(fx.project_ids(), ["p", WORKTREE_PROJECT]);
    assert_eq!(fx.ledger.entries().unwrap().len(), 1);
}

#[test]
fn a_ledger_that_does_not_parse_removes_nothing_and_says_so() {
    let fx = fixture();
    fx.commit_in_worktree("fix.txt");
    fx.merge();
    std::fs::write(&fx.ledger.path, "{ not json").unwrap();

    let outcomes = fx.sweep();
    assert_eq!(outcomes.len(), 1);
    assert_eq!(outcomes[0].path, fx.ledger.path.to_string_lossy());
    assert!(
        matches!(&outcomes[0].verdict, Verdict::Failed(error) if error.contains("parse")),
        "{outcomes:?}"
    );
    assert!(fx.wt.is_dir());
    assert_eq!(fx.project_ids(), ["p", WORKTREE_PROJECT]);
}

fn finished(outcomes: Vec<Outcome>) -> Option<std::sync::mpsc::Receiver<Vec<Outcome>>> {
    let (tx, rx) = std::sync::mpsc::channel();
    tx.send(outcomes).unwrap();
    Some(rx)
}

fn kept(path: &str, verdict: Verdict) -> Outcome {
    Outcome {
        path: path.into(),
        verdict,
    }
}

#[test]
fn sweeps_start_at_most_once_a_minute_and_one_at_a_time() {
    let mut sweeper = Sweeper::new();
    let (tx, rx) = std::sync::mpsc::channel();
    let mut starts = 0;
    // The first step starts one.
    sweeper.step(0, || {
        starts += 1;
        Some(rx)
    });
    // Still running a minute later: no second sweep.
    sweeper.step(SWEEP_INTERVAL_MS, || {
        starts += 1;
        None
    });
    assert_eq!(starts, 1);
    // It finishes; the next is due a minute after the last start.
    tx.send(vec![]).unwrap();
    sweeper.step(SWEEP_INTERVAL_MS + 1, || {
        starts += 1;
        None
    });
    assert_eq!(starts, 2);
    sweeper.step(SWEEP_INTERVAL_MS + 2, || {
        starts += 1;
        None
    });
    assert_eq!(starts, 2, "throttled");
    sweeper.step(2 * SWEEP_INTERVAL_MS + 1, || {
        starts += 1;
        None
    });
    assert_eq!(starts, 3);
}

#[test]
fn a_kept_worktree_is_logged_once_per_reason() {
    let mut sweeper = Sweeper::new();
    let mut now = 0;
    let mut step = |outcomes: Vec<Outcome>| {
        // One step starts the sweep, the next collects it.
        sweeper.step(now, || finished(outcomes));
        now += SWEEP_INTERVAL_MS;
        let lines = sweeper.step(now, || None);
        now += SWEEP_INTERVAL_MS;
        lines
    };

    let lines = step(vec![
        kept("/wt/a", Verdict::Unmerged),
        kept("/wt/b", Verdict::OwnerAlive),
    ]);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("/wt/a") && lines[0].contains("not merged"));
    // Same reason again: quiet.
    assert_eq!(
        step(vec![kept("/wt/a", Verdict::Unmerged)]),
        Vec::<String>::new()
    );
    // A new reason is news.
    let lines = step(vec![kept("/wt/a", Verdict::Dirty)]);
    assert!(lines[0].contains("uncommitted"), "{lines:?}");
    let lines = step(vec![kept("/wt/a", Verdict::Removed)]);
    assert!(lines[0].contains("removed"), "{lines:?}");
}
