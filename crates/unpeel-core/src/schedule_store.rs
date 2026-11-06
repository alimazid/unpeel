//! Per-task Host state of a Scheduled Task, under
//! `<UNPEEL_HOME>/schedules/<id>/`:
//!
//! - `clock.json`: the last occurrence fired, plus the next run and last
//!   result the scheduler publishes for readers that have no clock.
//! - `runs.jsonl`: the append-only Run log. A Run's later line supersedes
//!   its earlier ones; past 100 lines it is rewritten to the newest 50 Runs.
//!
//! The workspace worker is the writer; MCP, the CLI and Controller routes
//! read through here, so none of them needs the scheduler. Every write takes
//! the task's `runs.lock` flock and lands by temp file + rename or one
//! `O_APPEND` write.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::schedules::{self, Schedule, ScheduleClock, ScheduleRun};

/// Runs a task keeps once its log is compacted.
pub const MAX_RUNS: usize = 50;
/// Physical lines past which an append compacts the log.
pub const COMPACT_AFTER_LINES: usize = 100;

const CLOCK_FILE: &str = "clock.json";
const RUNS_FILE: &str = "runs.jsonl";

/// `<UNPEEL_HOME>/schedules`: one directory per task of this workspace.
pub fn schedules_root() -> PathBuf {
    crate::app_paths::unpeel_home().join("schedules")
}

/// The workspace's task definitions from `app-state.json`, decoded entry by
/// entry (`schedules::schedules_from_value`). A missing file has no tasks;
/// an unreadable one is an error, never "no tasks".
pub fn load_schedules() -> Result<Vec<Schedule>, String> {
    let state = crate::app_state::load()?;
    Ok(schedules::schedules_from_value(state.get("schedules")))
}

/// One task's state directory.
#[derive(Debug, Clone)]
pub struct TaskStore {
    dir: PathBuf,
}

impl TaskStore {
    /// The store of `schedule_id` in this workspace.
    pub fn for_schedule(schedule_id: &str) -> Result<Self, String> {
        Self::open(&schedules_root(), schedule_id)
    }

    /// The store of `schedule_id` under an explicit root (tests).
    pub fn open(root: &Path, schedule_id: &str) -> Result<Self, String> {
        if !schedules::is_valid_id(schedule_id) {
            return Err(format!("invalid schedule id {schedule_id:?}"));
        }
        Ok(Self {
            dir: root.join(schedule_id),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The task's clock. Missing is a task that never fired; a file that
    /// exists but will not read is an error, so the caller can refuse to
    /// guess (a lost `last_occurrence` would fire an occurrence again).
    pub fn clock(&self) -> Result<ScheduleClock, String> {
        let path = self.dir.join(CLOCK_FILE);
        let raw = match fs::read(&path) {
            Ok(raw) => raw,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(ScheduleClock::default())
            }
            Err(error) => return Err(format!("read {}: {error}", path.display())),
        };
        serde_json::from_slice(&raw).map_err(|error| format!("parse {}: {error}", path.display()))
    }

    pub fn save_clock(&self, clock: &ScheduleClock) -> Result<(), String> {
        let body = serde_json::to_vec_pretty(clock).map_err(|error| error.to_string())?;
        let _lock = self.lock()?;
        replace_file(&self.dir.join(CLOCK_FILE), &body)
    }

    /// Append one Run line; compacts the log once it passes
    /// [`COMPACT_AFTER_LINES`].
    pub fn append_run(&self, run: &ScheduleRun) -> Result<(), String> {
        let mut line = serde_json::to_vec(run).map_err(|error| error.to_string())?;
        line.push(b'\n');
        let _lock = self.lock()?;
        let path = self.dir.join(RUNS_FILE);
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|error| format!("open {}: {error}", path.display()))?;
        file.write_all(&line)
            .and_then(|()| file.flush())
            .map_err(|error| format!("append {}: {error}", path.display()))?;
        drop(file);
        let raw = fs::read(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
        if raw.iter().filter(|byte| **byte == b'\n').count() > COMPACT_AFTER_LINES {
            compact(&path, &raw)?;
        }
        Ok(())
    }

    /// Every Run's latest line, oldest Run first.
    pub fn runs(&self) -> Vec<ScheduleRun> {
        fs::read(self.dir.join(RUNS_FILE))
            .map(|raw| parse_runs(&raw))
            .unwrap_or_default()
    }

    /// The Run that speaks for the task (`schedules::current_run`): the one
    /// in progress, else the newest outcome.
    pub fn current_run(&self) -> Option<ScheduleRun> {
        schedules::current_run(&self.runs()).cloned()
    }

    /// Delete the task's clock and Run log. Its Run Sessions are untouched.
    pub fn remove(&self) -> Result<(), String> {
        match fs::remove_dir_all(&self.dir) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("remove {}: {error}", self.dir.display())),
        }
    }

    fn lock(&self) -> Result<crate::app_state::FileLock, String> {
        fs::create_dir_all(&self.dir)
            .map_err(|error| format!("create {}: {error}", self.dir.display()))?;
        crate::app_state::lock_exclusive(&self.dir.join(RUNS_FILE))
    }
}

fn parse_runs(raw: &[u8]) -> Vec<ScheduleRun> {
    schedules::fold_runs(
        raw.split(|byte| *byte == b'\n')
            .filter_map(|line| serde_json::from_slice::<ScheduleRun>(line).ok()),
    )
}

/// Rewrite the log to the latest line of each of the newest [`MAX_RUNS`].
fn compact(path: &Path, raw: &[u8]) -> Result<(), String> {
    let runs = parse_runs(raw);
    let mut body = Vec::new();
    for run in &runs[runs.len().saturating_sub(MAX_RUNS)..] {
        serde_json::to_writer(&mut body, run).map_err(|error| error.to_string())?;
        body.push(b'\n');
    }
    replace_file(path, &body)
}

fn replace_file(path: &Path, body: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension("unpeel-tmp");
    fs::write(&temporary, body)
        .and_then(|()| fs::rename(&temporary, path))
        .map_err(|error| {
            let _ = fs::remove_file(&temporary);
            format!("write {}: {error}", path.display())
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schedules::RunStatus;

    /// A private root: never this machine's `UNPEEL_HOME`.
    fn with_store<T>(body: impl FnOnce(&TaskStore) -> T) -> T {
        let root = std::env::temp_dir().join(format!("unpeel-sched-{}", uuid::Uuid::new_v4()));
        let store = TaskStore::open(&root, "sch_test").expect("valid id");
        let outcome = body(&store);
        let _ = fs::remove_dir_all(&root);
        outcome
    }

    fn run(run_id: &str, status: RunStatus) -> ScheduleRun {
        ScheduleRun {
            run_id: run_id.into(),
            scheduled_for: Some("2026-11-06T09:00".into()),
            started_at_ms: Some(1),
            ended_at_ms: None,
            status,
            late: false,
            session_id: None,
            exit_code: None,
            reason: None,
            snippet: None,
            phase: None,
            prompted_at_ms: None,
        }
    }

    #[test]
    fn a_task_that_never_fired_has_an_empty_clock() {
        with_store(|store| {
            assert_eq!(store.clock(), Ok(ScheduleClock::default()));
            assert!(store.runs().is_empty());
            assert_eq!(store.current_run(), None);
        });
    }

    #[test]
    fn the_clock_round_trips_and_a_damaged_one_is_an_error() {
        with_store(|store| {
            let clock = ScheduleClock {
                last_occurrence: Some("2026-11-06T09:00".into()),
                next_occurrence: Some("2026-11-07T09:00".into()),
                next_occurrence_ms: Some(1_793_000_000_000),
                last_run_id: Some("run_1".into()),
                last_run_status: Some(RunStatus::Done),
            };
            store.save_clock(&clock).expect("save");
            assert_eq!(store.clock(), Ok(clock));

            fs::write(store.dir().join("clock.json"), b"{not json").unwrap();
            assert!(store.clock().is_err());
        });
    }

    #[test]
    fn a_runs_later_line_is_its_state() {
        with_store(|store| {
            store.append_run(&run("run_1", RunStatus::Running)).unwrap();
            store.append_run(&run("run_2", RunStatus::Skipped)).unwrap();
            let mut finished = run("run_1", RunStatus::Done);
            finished.exit_code = Some(0);
            store.append_run(&finished).unwrap();
            let runs = store.runs();
            let ids: Vec<_> = runs.iter().map(|r| (r.run_id.as_str(), r.status)).collect();
            assert_eq!(
                ids,
                vec![("run_1", RunStatus::Done), ("run_2", RunStatus::Skipped)]
            );
            // Both say they ended at once: the later Run is the task's.
            assert_eq!(store.current_run().map(|r| r.run_id), Some("run_2".into()));
        });
    }

    #[test]
    fn a_skipped_occurrence_never_replaces_the_run_in_progress() {
        with_store(|store| {
            let live = ScheduleRun {
                started_at_ms: Some(10),
                ..run("run_live", RunStatus::Running)
            };
            store.append_run(&live).unwrap();
            store
                .append_run(&ScheduleRun {
                    started_at_ms: None,
                    ended_at_ms: Some(20),
                    ..run("run_skipped", RunStatus::Skipped)
                })
                .unwrap();
            assert_eq!(store.current_run(), Some(live.clone()));
            let done = ScheduleRun {
                status: RunStatus::Done,
                ended_at_ms: Some(30),
                ..live
            };
            store.append_run(&done).unwrap();
            assert_eq!(store.current_run(), Some(done), "its outcome is the newest");
        });
    }

    #[test]
    fn the_log_keeps_the_newest_fifty_runs_once_it_passes_a_hundred_lines() {
        with_store(|store| {
            for index in 1..=COMPACT_AFTER_LINES {
                store
                    .append_run(&run(&format!("run_{index:03}"), RunStatus::Done))
                    .unwrap();
            }
            assert_eq!(
                store.runs().len(),
                COMPACT_AFTER_LINES,
                "no trim at 100 lines"
            );
            store.append_run(&run("run_101", RunStatus::Done)).unwrap();
            let runs = store.runs();
            assert_eq!(runs.len(), MAX_RUNS);
            assert_eq!(runs.first().map(|r| r.run_id.as_str()), Some("run_052"));
            assert_eq!(runs.last().map(|r| r.run_id.as_str()), Some("run_101"));
            let lines = fs::read_to_string(store.dir().join("runs.jsonl")).unwrap();
            assert_eq!(lines.lines().count(), MAX_RUNS);
        });
    }

    #[test]
    fn an_unreadable_line_costs_only_itself() {
        with_store(|store| {
            store.append_run(&run("run_1", RunStatus::Done)).unwrap();
            let path = store.dir().join("runs.jsonl");
            let mut raw = fs::read(&path).unwrap();
            raw.extend_from_slice(b"{\"half a line\n");
            fs::write(&path, raw).unwrap();
            store.append_run(&run("run_2", RunStatus::Failed)).unwrap();
            let ids: Vec<_> = store.runs().into_iter().map(|r| r.run_id).collect();
            assert_eq!(ids, vec!["run_1", "run_2"]);
        });
    }

    #[test]
    fn a_task_id_that_is_not_a_plain_name_has_no_store() {
        let root = Path::new("/nonexistent");
        assert!(TaskStore::open(root, "../escape").is_err());
        assert!(TaskStore::open(root, "").is_err());
        assert!(TaskStore::open(root, "a/b").is_err());
    }

    #[test]
    fn removing_a_task_deletes_its_state_only() {
        with_store(|store| {
            store.append_run(&run("run_1", RunStatus::Done)).unwrap();
            let sibling = store.dir().with_file_name("sch_other");
            fs::create_dir_all(&sibling).unwrap();
            store.remove().expect("remove");
            assert!(!store.dir().exists());
            assert!(sibling.exists());
            store.remove().expect("removing twice is fine");
        });
    }
}
