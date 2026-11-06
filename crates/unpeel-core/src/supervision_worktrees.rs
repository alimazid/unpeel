//! Fork-only: the worktrees the Router made for its Workers (§16.4, §18.1
//! item 9). A durable ledger, `<UNPEEL_HOME>/supervision/worktrees.json`,
//! outside every session dir so it outlives the Worker that owns an entry.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// One worktree the Router created for a Worker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub path: String,
    pub branch: String,
    /// The ref the branch forked from, when the Router named one.
    pub base_ref: Option<String>,
    /// The main checkout the worktree belongs to.
    pub repo_path: String,
    /// The child project registered for it.
    pub project_id: String,
    pub owner_session_id: String,
    /// Unix ms.
    pub created_at: u64,
}

/// The file as stored: an object, so later keys can join it.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Document {
    #[serde(default)]
    worktrees: Vec<Entry>,
}

/// The ledger file: the workspace's (`home`), or an explicit path in tests.
#[derive(Debug, Clone)]
pub struct Ledger {
    path: PathBuf,
}

impl Ledger {
    pub fn home() -> Self {
        Self::at(
            crate::app_paths::unpeel_home()
                .join("supervision")
                .join("worktrees.json"),
        )
    }

    pub fn at(path: PathBuf) -> Self {
        Self { path }
    }

    /// Every entry. A missing file is an empty ledger.
    pub fn entries(&self) -> Result<Vec<Entry>, String> {
        Ok(self.load()?.worktrees)
    }

    /// A Worker got a worktree. One the Router created (`adopted: false`)
    /// is recorded, replacing any entry for the same path. An adopted one
    /// is recorded only if it is already on the ledger, and then the new
    /// Worker owns it: a worktree made by hand or by the desktop is never
    /// the sweep's to remove.
    pub fn record(&self, entry: Entry, adopted: bool) -> Result<(), String> {
        self.edit(|document| {
            let known = document
                .worktrees
                .iter()
                .position(|known| known.path == entry.path);
            match (known, adopted) {
                (Some(index), true) => {
                    document.worktrees[index].owner_session_id = entry.owner_session_id;
                }
                (None, true) => {}
                (known, false) => {
                    if let Some(index) = known {
                        document.worktrees.remove(index);
                    }
                    document.worktrees.push(entry);
                }
            }
        })
    }

    fn load(&self) -> Result<Document, String> {
        match std::fs::read(&self.path) {
            Ok(raw) => serde_json::from_slice(&raw)
                .map_err(|error| format!("parse {}: {error}", self.path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Document::default()),
            Err(error) => Err(format!("read {}: {error}", self.path.display())),
        }
    }

    /// Load → change → save under `<file>.lock`.
    fn edit<T>(&self, change: impl FnOnce(&mut Document) -> T) -> Result<T, String> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("create {}: {error}", parent.display()))?;
        }
        let _lock = crate::app_state::lock_exclusive(&self.path)?;
        let mut document = self.load()?;
        let outcome = change(&mut document);
        let body = serde_json::to_string_pretty(&document).map_err(|error| error.to_string())?;
        crate::hook_assets::write_file_atomic(&self.path, &body, "worktree ledger")?;
        Ok(outcome)
    }
}

/// The longest a sweep waits for the next: a removed Worker's worktree goes
/// within about a minute of the retention sweep removing the Worker.
const SWEEP_INTERVAL_MS: u64 = 60_000;

/// The Host's one sweeper. A static, so `Supervisor::step` needs one call
/// and no state of its own; one Host process serves one `UNPEEL_HOME`.
static SWEEPER: Mutex<Sweeper> = Mutex::new(Sweeper::new());

/// From `Supervisor::step`, once per rescan: at most once a minute, sweep
/// the ledger on a thread of its own (git runs there, never on the tick),
/// and trace what an earlier sweep did. Without a ledger nothing starts.
pub fn sweep_in_background(now_ms: u64) {
    let lines = match SWEEPER.lock() {
        Ok(mut sweeper) => sweeper.step(now_ms, start_home_sweep),
        Err(_) => return,
    };
    for line in lines {
        crate::hook_assets::append_trace_log_line(&line);
    }
}

fn start_home_sweep() -> Option<mpsc::Receiver<Vec<Outcome>>> {
    let ledger = Ledger::home();
    if !ledger.path.exists() {
        return None;
    }
    let (outcomes_tx, outcomes_rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("unpeel-worktree-sweep".into())
        .spawn(move || {
            let sessions_root = crate::app_paths::app_sessions_root();
            let outcomes = sweep_at(&Sweep {
                ledger: &ledger,
                sessions_root: &sessions_root,
                remove_worktree: &|path| crate::worktrees::remove(path, false),
                unregister: &|entry| {
                    crate::app_state::edit(|state| Ok(unregister_in(state, entry))).map(|_| ())
                },
            });
            let _ = outcomes_tx.send(outcomes);
        })
        .ok()?;
    Some(outcomes_rx)
}

/// Throttles sweeps, keeps one in flight, and logs each kept worktree once
/// per reason (and again if the reason changes).
pub(crate) struct Sweeper {
    last_started_ms: Option<u64>,
    in_flight: Option<mpsc::Receiver<Vec<Outcome>>>,
    /// The reason each kept worktree was last logged with.
    logged: BTreeMap<String, Verdict>,
}

impl Sweeper {
    pub(crate) const fn new() -> Self {
        Self {
            last_started_ms: None,
            in_flight: None,
            logged: BTreeMap::new(),
        }
    }

    /// Collect a finished sweep, start the next when due. Returns trace
    /// lines.
    pub(crate) fn step(
        &mut self,
        now_ms: u64,
        start: impl FnOnce() -> Option<mpsc::Receiver<Vec<Outcome>>>,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        if let Some(outcomes) = self.in_flight.as_ref() {
            match outcomes.try_recv() {
                Ok(outcomes) => {
                    lines = self.report(now_ms, outcomes);
                    self.in_flight = None;
                }
                Err(mpsc::TryRecvError::Empty) => return lines,
                Err(mpsc::TryRecvError::Disconnected) => self.in_flight = None,
            }
        }
        let due = self
            .last_started_ms
            .is_none_or(|last| now_ms.saturating_sub(last) >= SWEEP_INTERVAL_MS);
        if due {
            self.last_started_ms = Some(now_ms);
            self.in_flight = start();
        }
        lines
    }

    fn report(&mut self, now_ms: u64, outcomes: Vec<Outcome>) -> Vec<String> {
        let previous = std::mem::take(&mut self.logged);
        let mut lines = Vec::new();
        for Outcome { path, verdict } in outcomes {
            let Some(why) = verdict.describe() else {
                continue;
            };
            if verdict != Verdict::Removed {
                let repeat = previous.get(&path) == Some(&verdict);
                self.logged.insert(path.clone(), verdict);
                if repeat {
                    continue;
                }
            }
            lines.push(format!("{now_ms} supervision-worktrees {path}: {why}"));
        }
        lines
    }
}

impl Verdict {
    /// What the trace says, or `None` for nothing worth a line.
    fn describe(&self) -> Option<String> {
        Some(match self {
            Self::Removed => {
                "removed: its Worker is gone, its branch merged and the worktree clean".into()
            }
            Self::OwnerAlive => return None,
            Self::InUse(session_id) => format!("kept: Session {session_id} works in it"),
            Self::Unmerged => "kept: its branch is not merged into its base".into(),
            Self::Dirty => "kept: it has uncommitted changes or untracked files".into(),
            Self::Missing => "kept on the ledger: its folder is gone".into(),
            Self::Failed(error) => format!("kept: {error}"),
        })
    }
}

/// What one sweep reads and changes: the workspace's own files, or temp
/// roots in tests.
pub(crate) struct Sweep<'a> {
    pub ledger: &'a Ledger,
    pub sessions_root: &'a Path,
    /// `worktrees::remove(path, false)` outside tests.
    pub remove_worktree: &'a dyn Fn(&str) -> Result<(), String>,
    /// Drops the entry's child project from app-state.
    pub unregister: &'a dyn Fn(&Entry) -> Result<(), String>,
}

/// What a sweep did with one entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub path: String,
    pub verdict: Verdict,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The worktree and its child project are gone, and so is the entry.
    Removed,
    /// Waiting: the owning Worker's session still exists (stopped or not).
    OwnerAlive,
    /// Kept: another Session (say, the Worker restarted by the user under
    /// a new id) runs in it or in its project.
    InUse(String),
    /// Kept: its branch is not merged into its base.
    Unmerged,
    /// Kept: it has uncommitted changes or untracked files.
    Dirty,
    /// Kept: its folder is gone (removed by hand or by the desktop), so
    /// there is nothing to check.
    Missing,
    /// Kept: a check or a removal step failed.
    Failed(String),
}

/// One pass over the ledger. A ledger that won't read is one `Failed`
/// outcome under its own path, and nothing is touched.
pub(crate) fn sweep_at(sweep: &Sweep) -> Vec<Outcome> {
    let entries = match sweep.ledger.entries() {
        Ok(entries) => entries,
        Err(error) => {
            return vec![Outcome {
                path: sweep.ledger.path.to_string_lossy().to_string(),
                verdict: Verdict::Failed(error),
            }]
        }
    };
    entries
        .into_iter()
        .map(|entry| {
            let verdict = match judge(sweep.sessions_root, &entry) {
                Some(kept) => kept,
                None => remove(sweep, &entry).unwrap_or_else(Verdict::Failed),
            };
            Outcome {
                path: entry.path,
                verdict,
            }
        })
        .collect()
}

/// Worktree, then child project, then entry: a failed step leaves the
/// later ones in place, so nothing is unregistered that still exists.
/// The git checks take a moment, so the ledger and the Sessions are read
/// again just before: a Worker that adopted the worktree meanwhile keeps it.
fn remove(sweep: &Sweep, entry: &Entry) -> Result<Verdict, String> {
    if !sweep.ledger.entries()?.contains(entry) {
        return Ok(Verdict::OwnerAlive);
    }
    if let Some(session_id) = session_using(sweep.sessions_root, entry) {
        return Ok(Verdict::InUse(session_id));
    }
    (sweep.remove_worktree)(&entry.path)?;
    (sweep.unregister)(entry)?;
    sweep
        .ledger
        .edit(|document| document.worktrees.retain(|known| known.path != entry.path))?;
    Ok(Verdict::Removed)
}

/// Why `entry` stays, or `None` when it may go.
fn judge(sessions_root: &Path, entry: &Entry) -> Option<Verdict> {
    let owner = &entry.owner_session_id;
    if !crate::supervision::valid_session_id(owner) || sessions_root.join(owner).exists() {
        return Some(Verdict::OwnerAlive);
    }
    if !Path::new(&entry.path).is_dir() {
        return Some(Verdict::Missing);
    }
    if let Some(session_id) = session_using(sessions_root, entry) {
        return Some(Verdict::InUse(session_id));
    }
    match merged(entry) {
        Ok(true) => {}
        Ok(false) => return Some(Verdict::Unmerged),
        Err(error) => return Some(Verdict::Failed(error)),
    }
    match clean(&entry.path) {
        Ok(true) => None,
        Ok(false) => Some(Verdict::Dirty),
        Err(error) => Some(Verdict::Failed(error)),
    }
}

/// The first Session (by id) that runs in the worktree or files under its
/// project: a manifest's `cwd` inside it, its `session.worktree_path` or
/// `session.project_id`, or a move marker into the project. Raw reads,
/// not `list_manifests`, which rewrites manifests as it goes.
fn session_using(sessions_root: &Path, entry: &Entry) -> Option<String> {
    let mut ids: Vec<String> = std::fs::read_dir(sessions_root)
        .ok()?
        .flatten()
        .filter_map(|dir| dir.file_name().into_string().ok())
        .collect();
    ids.sort();
    ids.into_iter().find(|id| {
        let dir = sessions_root.join(id);
        let read = |file: &str| -> Value {
            std::fs::read(dir.join(file))
                .ok()
                .and_then(|raw| serde_json::from_slice(&raw).ok())
                .unwrap_or(Value::Null)
        };
        let manifest = read("manifest.json");
        let text = |value: &Value| value.as_str().map(str::to_string);
        let in_worktree =
            |path: Option<String>| path.is_some_and(|path| inside(&path, &entry.path));
        in_worktree(text(&manifest["cwd"]))
            || in_worktree(text(&manifest["session"]["worktree_path"]))
            || text(&manifest["session"]["project_id"]).as_deref() == Some(&entry.project_id)
            || text(&read("project-override.json")["project_id"]).as_deref()
                == Some(&entry.project_id)
    })
}

/// `path` is `root` or below it, through symlinks (`/tmp` is
/// `/private/tmp` to git).
fn inside(path: &str, root: &str) -> bool {
    Path::new(path).starts_with(root) || canonical(path).starts_with(canonical(root))
}

fn same_path(left: &str, right: &str) -> bool {
    left == right || canonical(left) == canonical(right)
}

fn canonical(path: &str) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.into())
}

/// `git status --porcelain` is empty: nothing modified, nothing untracked.
/// No optional locks, so a background check never takes the index lock
/// from a Worker's own git.
fn clean(path: &str) -> Result<bool, String> {
    let output = git(path, &["--no-optional-locks", "status", "--porcelain"])?;
    if !output.status.success() {
        return Err(stderr(&output));
    }
    Ok(output.stdout.iter().all(u8::is_ascii_whitespace))
}

/// Whether the branch, and whatever the worktree has checked out, are in
/// its base: the ref the Router named, else the mainline
/// `worktrees::create` forks from. For a remote-tracking base the local
/// branch of the same name counts too: a Worker merges locally and pushes
/// only when the user asked for it.
fn merged(entry: &Entry) -> Result<bool, String> {
    let repo = entry.repo_path.as_str();
    let base = entry
        .base_ref
        .clone()
        .or_else(|| crate::worktrees::default_base_ref(repo))
        .ok_or("no base ref to check its branch against")?;
    let head = rev_parse(&entry.path, "HEAD")?;
    let branch = format!("refs/heads/{}", entry.branch);
    let mut bases = vec![base.clone()];
    if rev_parse(repo, &format!("refs/remotes/{base}")).is_ok() {
        if let Some((_, local)) = base.split_once('/') {
            bases.push(format!("refs/heads/{local}"));
        }
    }
    for base in &bases {
        if is_ancestor(repo, &branch, base)? && is_ancestor(repo, &head, base)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// The commit `name` resolves to in `dir`.
fn rev_parse(dir: &str, name: &str) -> Result<String, String> {
    let output = git(dir, &["rev-parse", "--verify", "--quiet", name])?;
    if !output.status.success() {
        return Err(format!("{name} does not resolve in {dir}"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// `git merge-base --is-ancestor`: exit 0 is yes, 1 is no, anything else
/// (an unknown ref, no repo) an error.
fn is_ancestor(repo: &str, commit: &str, base: &str) -> Result<bool, String> {
    // git would read a leading '-' as an option.
    if let Some(flag) = [commit, base]
        .into_iter()
        .find(|name| name.starts_with('-'))
    {
        return Err(format!("refusing ref {flag:?}"));
    }
    let output = git(repo, &["merge-base", "--is-ancestor", commit, base])?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(stderr(&output)),
    }
}

fn git(dir: &str, args: &[&str]) -> Result<std::process::Output, String> {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|error| format!("git {}: {error}", args.join(" ")))
}

fn stderr(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

/// Drop `entry`'s child project: the row with its id, if it is still the
/// worktree project for that folder. `true` when a row went.
pub(crate) fn unregister_in(state: &mut Map<String, Value>, entry: &Entry) -> bool {
    let Some(projects) = state.get_mut("projects").and_then(Value::as_array_mut) else {
        return false;
    };
    let before = projects.len();
    projects.retain(|project| {
        let text = |key: &str| project.get(key).and_then(Value::as_str);
        let ours = text("id") == Some(entry.project_id.as_str())
            && text("path").is_some_and(|path| same_path(path, &entry.path));
        !ours
    });
    projects.len() != before
}

#[cfg(test)]
mod tests;
