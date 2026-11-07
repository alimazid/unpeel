//! Per-task Host state of a Scheduled Task, under
//! `<UNPEEL_HOME>/schedules/<id>/`:
//!
//! - `clock.json`: the last occurrence fired, plus the next run and last
//!   result the scheduler publishes for readers that have no clock.
//! - `runs.jsonl`: the append-only Run log. A Run's later line supersedes
//!   its earlier ones; past 100 lines it is rewritten to the newest 50 Runs.
//!
//! The workspace worker is the writer; MCP, the CLI and Controller routes
//! read through here, so none of them needs the scheduler. Every write, and
//! deleting a task, takes the task's `<id>.lock` flock (beside its
//! directory) and lands by temp file + rename or one `O_APPEND` write. The
//! scheduler's clock save and a Run's first line check under that lock that
//! the task is still defined, so a delete that lands during a sweep wins.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::schedules::run_sessions::{LatestRunSessions, RunSessionRow};
use crate::schedules::{self, Schedule, ScheduleClock, ScheduleRun};
use crate::state::Preset;

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

/// [`load_schedules`] plus every preset row, turned off ones too, from the
/// same read: a Run that cannot start names its preset by label.
pub fn load_schedules_and_presets() -> Result<(Vec<Schedule>, Vec<Preset>), String> {
    let state = crate::app_state::load()?;
    Ok((
        schedules::schedules_from_value(state.get("schedules")),
        presets_from_value(state.get("presets")),
    ))
}

/// Preset rows decoded entry by entry; one that will not decode is skipped.
pub fn presets_from_value(value: Option<&serde_json::Value>) -> Vec<Preset> {
    value
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| serde_json::from_value(row.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

/// What a write that first checks its task is still defined did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskWrite {
    Written,
    /// The task's definition is gone: nothing was written.
    TaskDeleted,
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

    /// Save the task's clock while `is_defined` says the task is still
    /// saved. The scheduler's first write for a new task, so it makes the
    /// task's directory; on disk a deleted task looks like a new one, so
    /// only the definition tells them apart. The check runs under the
    /// task's lock, which a delete takes after removing the definition:
    /// either the clock lands before the delete removes the directory, or
    /// the check sees the task gone and nothing is written. A check that
    /// fails is an error, never "still defined".
    pub fn save_clock(
        &self,
        clock: &ScheduleClock,
        is_defined: impl FnOnce() -> Result<bool, String>,
    ) -> Result<TaskWrite, String> {
        let body = serde_json::to_vec_pretty(clock).map_err(|error| error.to_string())?;
        let _lock = self.lock()?;
        if !is_defined()? {
            return Ok(TaskWrite::TaskDeleted);
        }
        fs::create_dir_all(&self.dir)
            .map_err(|error| format!("create {}: {error}", self.dir.display()))?;
        replace_file(&self.dir.join(CLOCK_FILE), &body)?;
        Ok(TaskWrite::Written)
    }

    /// Append one Run line; compacts the log once it passes
    /// [`COMPACT_AFTER_LINES`]. The task's clock is always saved first, so
    /// a missing directory is a task deleted since: its Run is not
    /// recorded, and the directory is not made again.
    pub fn append_run(&self, run: &ScheduleRun) -> Result<(), String> {
        let line = run_line(run)?;
        let _lock = self.lock()?;
        self.append_line(&line)
    }

    /// Append a Run's first line while `is_defined` says the task is still
    /// saved, checked under the lock as [`Self::save_clock`] does: a Run
    /// starts only from a task that is not deleted.
    pub fn append_run_if_defined(
        &self,
        run: &ScheduleRun,
        is_defined: impl FnOnce() -> Result<bool, String>,
    ) -> Result<TaskWrite, String> {
        let line = run_line(run)?;
        let _lock = self.lock()?;
        if !is_defined()? {
            return Ok(TaskWrite::TaskDeleted);
        }
        self.append_line(&line)?;
        Ok(TaskWrite::Written)
    }

    /// The append itself, with the task's lock held.
    fn append_line(&self, line: &[u8]) -> Result<(), String> {
        if !self.dir.is_dir() {
            return Err(format!(
                "{} is gone: the Scheduled Task was deleted",
                self.dir.display()
            ));
        }
        let path = self.dir.join(RUNS_FILE);
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|error| format!("open {}: {error}", path.display()))?;
        file.write_all(line)
            .and_then(|()| file.flush())
            .map_err(|error| format!("append {}: {error}", path.display()))?;
        drop(file);
        let raw = fs::read(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
        if raw.iter().filter(|byte| **byte == b'\n').count() > COMPACT_AFTER_LINES {
            compact(&path, &raw)?;
        }
        Ok(())
    }

    /// Every Run's latest line, oldest Run first. A missing log is a task
    /// that never ran; a log that exists but will not read is an error,
    /// never "no Runs": it could be hiding the Run in progress.
    pub fn runs(&self) -> Result<Vec<ScheduleRun>, String> {
        let path = self.dir.join(RUNS_FILE);
        match fs::read(&path) {
            Ok(raw) => Ok(parse_runs(&raw)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(error) => Err(format!("read {}: {error}", path.display())),
        }
    }

    /// The Run that speaks for the task (`schedules::current_run`): the one
    /// in progress, else the newest outcome.
    pub fn current_run(&self) -> Result<Option<ScheduleRun>, String> {
        Ok(schedules::current_run(&self.runs()?).cloned())
    }

    /// Point every Run line naming `old_session_id` at `new_session_id`:
    /// Resume relaunches a Run Session under a new id, and the task's Runs
    /// must keep opening it. Other lines stay byte for byte. `false` when
    /// no line named it (or the task has no log, which stays absent).
    pub fn replace_session(
        &self,
        old_session_id: &str,
        new_session_id: &str,
    ) -> Result<bool, String> {
        let path = self.dir.join(RUNS_FILE);
        let _lock = self.lock()?;
        if !path.exists() {
            return Ok(false);
        }
        let raw = fs::read(&path).map_err(|error| format!("read {}: {error}", path.display()))?;
        let mut body = Vec::with_capacity(raw.len());
        let mut replaced = false;
        for line in raw.split_inclusive(|byte| *byte == b'\n') {
            match serde_json::from_slice::<ScheduleRun>(line.trim_ascii_end()) {
                Ok(run) if run.session_id.as_deref() == Some(old_session_id) => {
                    let run = ScheduleRun {
                        session_id: Some(new_session_id.to_string()),
                        ..run
                    };
                    serde_json::to_writer(&mut body, &run).map_err(|error| error.to_string())?;
                    body.push(b'\n');
                    replaced = true;
                }
                _ => body.extend_from_slice(line),
            }
        }
        if replaced {
            replace_file(&path, &body)?;
        }
        Ok(replaced)
    }

    /// Delete the task's clock and Run log, under the same lock as every
    /// write, so it never interleaves with an append or a compaction. Its
    /// Run Sessions are untouched.
    pub fn remove(&self) -> Result<(), String> {
        let _lock = self.lock()?;
        match fs::remove_dir_all(&self.dir) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("remove {}: {error}", self.dir.display())),
        }
    }

    /// The task's lock, `<root>/<id>.lock`: beside its directory rather than
    /// in it, so deleting the directory cannot strand a waiter on a lock
    /// file nobody else opens.
    fn lock(&self) -> Result<crate::app_state::FileLock, String> {
        if let Some(root) = self.dir.parent() {
            fs::create_dir_all(root)
                .map_err(|error| format!("create {}: {error}", root.display()))?;
        }
        crate::app_state::lock_exclusive(&self.dir)
    }
}

/// Each named task's latest Run Session (`schedules::run_sessions`):
/// the Session of its current Run. A task without a Run log is left out.
/// Both Host session-row builders read it, so they agree with the worker on
/// which Run is the task's.
pub fn latest_run_sessions<'a>(task_ids: impl IntoIterator<Item = &'a str>) -> LatestRunSessions {
    latest_run_sessions_in(&schedules_root(), task_ids)
}

/// Each task's latest Run Session as the Host's `rows` see it
/// (`run_sessions::resolve_latest`): what both session-row builders publish
/// from.
pub fn latest_run_sessions_of(rows: &[RunSessionRow<'_>]) -> LatestRunSessions {
    let logged = latest_run_sessions(
        rows.iter()
            .filter_map(|row| schedules::run_sessions::schedule_id(row.spawned_by)),
    );
    schedules::run_sessions::resolve_latest(logged, rows)
}

/// [`latest_run_sessions`] under an explicit root (tests).
pub fn latest_run_sessions_in<'a>(
    root: &Path,
    task_ids: impl IntoIterator<Item = &'a str>,
) -> LatestRunSessions {
    let tasks: std::collections::BTreeSet<&str> = task_ids.into_iter().collect();
    tasks
        .into_iter()
        .filter_map(|task| {
            // A log that will not read counts as no log: the task supersedes
            // nothing, so every one of its Run Sessions stays listed.
            let current = match TaskStore::open(root, task).ok()?.current_run() {
                Ok(current) => current?,
                Err(error) => {
                    log::warn!("Run Sessions of {task} all stay listed: {error}");
                    return None;
                }
            };
            Some((task.to_string(), current.session_id))
        })
        .collect()
}

fn run_line(run: &ScheduleRun) -> Result<Vec<u8>, String> {
    let mut line = serde_json::to_vec(run).map_err(|error| error.to_string())?;
    line.push(b'\n');
    Ok(line)
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

    /// A private root: never this machine's `UNPEEL_HOME`. The task has
    /// saved its first clock, as the scheduler always does before a Run.
    fn with_store<T>(body: impl FnOnce(&TaskStore) -> T) -> T {
        let root = std::env::temp_dir().join(format!("unpeel-sched-{}", uuid::Uuid::new_v4()));
        let store = TaskStore::open(&root, "sch_test").expect("valid id");
        store
            .save_clock(&ScheduleClock::default(), || Ok(true))
            .expect("first clock");
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
            assert!(store.runs().unwrap().is_empty());
            assert_eq!(store.current_run(), Ok(None));
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
            store.save_clock(&clock, || Ok(true)).expect("save");
            assert_eq!(store.clock(), Ok(clock));

            fs::write(store.dir().join("clock.json"), b"{not json").unwrap();
            assert!(store.clock().is_err());
        });
    }

    #[test]
    fn a_run_log_that_will_not_read_is_an_error_never_no_runs() {
        with_store(|store| {
            fs::create_dir_all(store.dir().join("runs.jsonl")).unwrap();
            assert!(store.runs().is_err());
            assert!(store.current_run().is_err());
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
            let runs = store.runs().unwrap();
            let ids: Vec<_> = runs.iter().map(|r| (r.run_id.as_str(), r.status)).collect();
            assert_eq!(
                ids,
                vec![("run_1", RunStatus::Done), ("run_2", RunStatus::Skipped)]
            );
            // Both say they ended at once: the later Run is the task's.
            assert_eq!(
                store.current_run().unwrap().map(|r| r.run_id),
                Some("run_2".into())
            );
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
            assert_eq!(store.current_run(), Ok(Some(live.clone())));
            let done = ScheduleRun {
                status: RunStatus::Done,
                ended_at_ms: Some(30),
                ..live
            };
            store.append_run(&done).unwrap();
            assert_eq!(
                store.current_run(),
                Ok(Some(done)),
                "its outcome is the newest"
            );
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
                store.runs().unwrap().len(),
                COMPACT_AFTER_LINES,
                "no trim at 100 lines"
            );
            store.append_run(&run("run_101", RunStatus::Done)).unwrap();
            let runs = store.runs().unwrap();
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
            let ids: Vec<_> = store
                .runs()
                .unwrap()
                .into_iter()
                .map(|r| r.run_id)
                .collect();
            assert_eq!(ids, vec!["run_1", "run_2"]);
        });
    }

    #[test]
    fn every_preset_row_decodes_turned_off_ones_too_and_a_bad_one_costs_only_itself() {
        let rows = serde_json::json!([
            {"id": "a", "label": "Alpha", "command": "true", "project_id": null,
             "enabled": false, "quick_launch": false},
            {"id": "broken"},
            {"id": "b", "label": "Beta", "command": "true", "project_id": "p"}
        ]);
        let presets = presets_from_value(Some(&rows));
        let decoded: Vec<_> = presets
            .iter()
            .map(|preset| {
                (
                    preset.label.as_str(),
                    preset.enabled,
                    preset.project_id.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            decoded,
            vec![("Alpha", false, None), ("Beta", true, Some("p"))]
        );
        assert!(presets_from_value(None).is_empty());
    }

    /// A task's latest Run Session is the Session of its current Run;
    /// a task with no Run log is left out, and so is an id with no store.
    #[test]
    fn each_tasks_latest_run_session_is_its_current_runs() {
        let root = std::env::temp_dir().join(format!("unpeel-sched-{}", uuid::Uuid::new_v4()));
        let append = |task: &str, line: ScheduleRun| {
            let store = TaskStore::open(&root, task).expect("valid id");
            if !store.dir().exists() {
                store
                    .save_clock(&ScheduleClock::default(), || Ok(true))
                    .expect("first clock");
            }
            store.append_run(&line).expect("append");
        };
        let with_session = |run_id: &str, status, session: &str, ended| ScheduleRun {
            session_id: Some(session.into()),
            ended_at_ms: ended,
            ..run(run_id, status)
        };
        append(
            "sch_a",
            with_session("run_1", RunStatus::Done, "a-1", Some(10)),
        );
        append(
            "sch_a",
            with_session("run_2", RunStatus::Done, "a-2", Some(20)),
        );
        // In progress outranks a newer outcome.
        append(
            "sch_b",
            with_session("run_1", RunStatus::NeedsYou, "b-1", None),
        );
        append(
            "sch_b",
            with_session("run_2", RunStatus::Done, "b-2", Some(50)),
        );
        append(
            "sch_c",
            with_session("run_1", RunStatus::Done, "c-1", Some(10)),
        );
        append(
            "sch_c",
            ScheduleRun {
                ended_at_ms: Some(20),
                ..run("run_2", RunStatus::FailedToStart)
            },
        );

        let latest = latest_run_sessions_in(
            &root,
            [
                "sch_a",
                "sch_b",
                "sch_a",
                "sch_c",
                "sch_never_ran",
                "../escape",
            ],
        );
        let _ = fs::remove_dir_all(&root);

        assert_eq!(
            latest,
            LatestRunSessions::from([
                ("sch_a".to_string(), Some("a-2".to_string())),
                ("sch_b".to_string(), Some("b-1".to_string())),
                ("sch_c".to_string(), None),
            ])
        );
    }

    /// Resume relaunches a Run Session under a new id: the Runs that named
    /// the old one name its replacement, and nothing else changes.
    #[test]
    fn a_resumed_run_session_is_followed_to_its_new_id() {
        with_store(|store| {
            let with_session = |run_id: &str, status, session: &str| ScheduleRun {
                session_id: Some(session.into()),
                ..run(run_id, status)
            };
            store
                .append_run(&with_session("run_1", RunStatus::Running, "old"))
                .unwrap();
            store
                .append_run(&with_session("run_1", RunStatus::Done, "old"))
                .unwrap();
            store
                .append_run(&with_session("run_2", RunStatus::Done, "other"))
                .unwrap();
            assert_eq!(store.replace_session("old", "new"), Ok(true));
            let sessions: Vec<_> = store
                .runs()
                .unwrap()
                .into_iter()
                .map(|run| (run.run_id, run.status, run.session_id))
                .collect();
            assert_eq!(
                sessions,
                vec![
                    (
                        "run_1".to_string(),
                        RunStatus::Done,
                        Some("new".to_string())
                    ),
                    (
                        "run_2".to_string(),
                        RunStatus::Done,
                        Some("other".to_string())
                    ),
                ]
            );
            assert_eq!(store.replace_session("unknown", "x"), Ok(false));
        });
        with_store(|store| {
            assert_eq!(store.replace_session("old", "new"), Ok(false));
            assert!(
                !store.dir().join("runs.jsonl").exists(),
                "a task with no log gains none"
            );
        });
    }

    #[test]
    fn a_task_id_that_is_not_a_plain_name_has_no_store() {
        let root = Path::new("/nonexistent");
        assert!(TaskStore::open(root, "../escape").is_err());
        assert!(TaskStore::open(root, "").is_err());
        assert!(TaskStore::open(root, "a/b").is_err());
    }

    /// A Run recorded after its task was deleted (a sweep that read the
    /// task first) does not bring the task's directory back.
    #[test]
    fn a_deleted_task_records_no_more_runs() {
        with_store(|store| {
            store.append_run(&run("run_1", RunStatus::Done)).unwrap();
            store.remove().unwrap();
            assert!(store.append_run(&run("run_2", RunStatus::Done)).is_err());
            assert!(!store.dir().exists());
        });
    }

    /// Deleting a task waits for a write in progress (same lock), so it
    /// never interleaves with an append or a compaction.
    #[test]
    fn removing_a_task_waits_for_a_write_in_progress() {
        with_store(|store| {
            store.append_run(&run("run_1", RunStatus::Done)).unwrap();
            let held = store.lock().unwrap();
            let other = store.clone();
            let (removed_tx, removed_rx) = std::sync::mpsc::channel();
            let remover = std::thread::spawn(move || {
                let removed = other.remove();
                let _ = removed_tx.send(removed);
            });
            assert!(
                removed_rx
                    .recv_timeout(std::time::Duration::from_millis(200))
                    .is_err(),
                "remove waits for the lock"
            );
            drop(held);
            let removed = removed_rx
                .recv_timeout(std::time::Duration::from_secs(5))
                .expect("remove once the lock is free");
            assert_eq!(removed, Ok(()));
            remover.join().unwrap();
            assert!(!store.dir().exists());
        });
    }

    /// #29: on disk a deleted task and a new one look alike (no
    /// directory); only the definition check tells them apart.
    #[test]
    fn a_clock_save_writes_only_while_its_task_is_defined() {
        with_store(|store| {
            store.remove().unwrap();
            let clock = ScheduleClock::default();
            assert_eq!(
                store.save_clock(&clock, || Ok(false)),
                Ok(TaskWrite::TaskDeleted)
            );
            assert!(!store.dir().exists(), "a deleted task gets no directory");
            assert!(store
                .save_clock(&clock, || Err("app-state.json will not read".into()))
                .is_err());
            assert!(!store.dir().exists(), "nor does one it cannot check");
            assert_eq!(
                store.append_run_if_defined(&run("run_1", RunStatus::Running), || Ok(false)),
                Ok(TaskWrite::TaskDeleted)
            );
            assert!(!store.dir().exists());

            assert_eq!(
                store.save_clock(&clock, || Ok(true)),
                Ok(TaskWrite::Written),
                "a new task's first save"
            );
            assert_eq!(store.clock(), Ok(clock));
            assert_eq!(
                store.append_run_if_defined(&run("run_1", RunStatus::Running), || Ok(true)),
                Ok(TaskWrite::Written)
            );
            assert_eq!(store.runs().unwrap().len(), 1);
        });
    }

    /// A delete as the routes and `unpeel schedules rm` run it: the
    /// definition goes, then the store.
    fn delete(store: TaskStore, defined: &std::sync::atomic::AtomicBool) -> Result<(), String> {
        defined.store(false, std::sync::atomic::Ordering::SeqCst);
        store.remove()
    }

    /// One delete raced against a clock save whose definition check is
    /// parked under the task's lock. `check_first`: the check answered
    /// before the delete removed the definition (the save lands, then the
    /// delete removes it); otherwise after (nothing is written).
    fn race_a_delete_against_a_clock_save(check_first: bool) -> Result<TaskWrite, String> {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::{mpsc, Arc};
        use std::time::Duration;
        with_store(|store| {
            let defined = Arc::new(AtomicBool::new(true));
            let (parked_tx, parked_rx) = mpsc::channel();
            let (go_tx, go_rx) = mpsc::channel::<()>();
            let saver = {
                let (store, defined) = (store.clone(), Arc::clone(&defined));
                std::thread::spawn(move || {
                    store.save_clock(&ScheduleClock::default(), || {
                        let early = defined.load(Ordering::SeqCst);
                        parked_tx.send(()).unwrap();
                        go_rx.recv().unwrap();
                        Ok(if check_first {
                            early
                        } else {
                            defined.load(Ordering::SeqCst)
                        })
                    })
                })
            };
            parked_rx.recv().unwrap();
            let (removed_tx, removed_rx) = mpsc::channel();
            let deleter = {
                let (store, defined) = (store.clone(), Arc::clone(&defined));
                std::thread::spawn(move || removed_tx.send(delete(store, &defined)).unwrap())
            };
            while defined.load(Ordering::SeqCst) {
                std::thread::yield_now();
            }
            assert!(
                removed_rx.recv_timeout(Duration::from_millis(100)).is_err(),
                "the delete waits for the save's lock"
            );
            go_tx.send(()).unwrap();
            let saved = saver.join().unwrap();
            deleter.join().unwrap();
            assert_eq!(removed_rx.recv().unwrap(), Ok(()));
            assert!(!store.dir().exists(), "orphaned: {saved:?}");
            saved
        })
    }

    #[test]
    fn a_delete_racing_a_clock_save_never_leaves_the_task_directory() {
        assert_eq!(
            race_a_delete_against_a_clock_save(true),
            Ok(TaskWrite::Written)
        );
        assert_eq!(
            race_a_delete_against_a_clock_save(false),
            Ok(TaskWrite::TaskDeleted)
        );
    }

    /// The same race left to the scheduler, many times over.
    #[test]
    fn a_delete_racing_a_clock_save_freely_never_leaves_the_task_directory() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::{Arc, Barrier};
        for _ in 0..200 {
            with_store(|store| {
                let defined = Arc::new(AtomicBool::new(true));
                let barrier = Arc::new(Barrier::new(2));
                let saver = {
                    let (store, defined, barrier) =
                        (store.clone(), Arc::clone(&defined), Arc::clone(&barrier));
                    std::thread::spawn(move || {
                        barrier.wait();
                        store.save_clock(&ScheduleClock::default(), || {
                            Ok(defined.load(Ordering::SeqCst))
                        })
                    })
                };
                barrier.wait();
                delete(store.clone(), &defined).unwrap();
                let saved = saver.join().unwrap();
                assert!(!store.dir().exists(), "orphaned: {saved:?}");
            });
        }
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
