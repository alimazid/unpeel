//! The workspace worker's side of the scheduler. Each sweep it reads every
//! task's clock and latest Run from disk (so a Host restart resumes where
//! the last one stopped), observes running Runs' Sessions, steps, and
//! performs the actions in order. Starting a Session runs on an
//! `unpeel-schedules` helper thread; its outcome comes back over a channel,
//! like auto-stop's.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use jiff::Zoned;
use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::schedule_store::TaskStore;
use unpeel_core::schedules::{RunStatus, Schedule, ScheduleClock, ScheduleRun};

use super::clock;
use super::launch;
use super::step::{self, Action, LaunchPlan, RunObservation, TaskState};

/// A just-started Run's Session may not have published its manifest yet;
/// until this long after its start a missing manifest means "launching".
const LAUNCH_GRACE_MS: u64 = 30_000;
/// How long the helper thread waits for a new Session's manifest.
const MANIFEST_TIMEOUT: Duration = Duration::from_secs(10);
/// Run Sessions open at the size `session.create` uses.
const SESSION_COLUMNS: u16 = 120;
const SESSION_ROWS: u16 = 32;

/// Everything a Run needs to start its Session.
#[derive(Debug, Clone)]
pub struct SpawnRequest {
    pub schedule_id: String,
    pub spawned_by: String,
    pub run_id: String,
    pub session_id: String,
    pub plan: LaunchPlan,
    pub hook_port: Option<u16>,
}

/// What the Host sees of a Session on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionSeen {
    Absent,
    Live,
    Stopped,
}

/// The side effects a sweep performs, so its ordering can be tested
/// against a real store without starting Sessions.
pub trait Effects: Send + Sync {
    /// Start the Session and wait until it exists. Runs on a helper thread.
    fn spawn(&self, request: SpawnRequest) -> Result<(), String>;
    /// The Session's state and its command's exit status, if recorded.
    fn session(&self, session_id: &str) -> (SessionSeen, Option<i32>);
    /// Turn a task off in `app-state.json`.
    fn disable(&self, schedule_id: &str) -> Result<(), String>;
}

/// What a sweep did, for the worker's trace and warnings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SweepEvent {
    Started {
        schedule_id: String,
        run_id: String,
        session_id: String,
    },
    Recorded {
        schedule_id: String,
        run_id: String,
        status: RunStatus,
    },
    Warning(String),
}

struct SpawnOutcome {
    run_id: String,
    error: Option<String>,
}

pub struct Scheduler {
    root: PathBuf,
    effects: Arc<dyn Effects>,
    /// Runs whose Session a helper thread is starting.
    launching: HashSet<String>,
    /// Runs whose Session failed to start, until the next step records it.
    spawn_failures: HashMap<String, String>,
    /// Accepted Run now requests: task id → Run id.
    run_now: HashMap<String, String>,
    /// The last warning per task, so a lasting problem warns once.
    warned: HashMap<String, String>,
    outcomes_tx: mpsc::Sender<SpawnOutcome>,
    outcomes_rx: mpsc::Receiver<SpawnOutcome>,
}

impl Default for Scheduler {
    fn default() -> Self {
        Self::new(
            unpeel_core::schedule_store::schedules_root(),
            Arc::new(HostEffects),
        )
    }
}

impl Scheduler {
    pub fn new(root: PathBuf, effects: Arc<dyn Effects>) -> Self {
        let (outcomes_tx, outcomes_rx) = mpsc::channel();
        Self {
            root,
            effects,
            launching: HashSet::new(),
            spawn_failures: HashMap::new(),
            run_now: HashMap::new(),
            warned: HashMap::new(),
            outcomes_tx,
            outcomes_rx,
        }
    }

    /// Whether a Run now request is waiting for the next sweep.
    pub fn has_pending(&self) -> bool {
        !self.run_now.is_empty()
    }

    /// Accept Run now for `schedule_id`, unless a Run of it is in progress.
    /// The Run starts on the next sweep; its id comes back at once.
    pub fn request_run_now(
        &mut self,
        schedule_id: &str,
        schedules: &[Schedule],
    ) -> Result<String, String> {
        let schedule = schedules
            .iter()
            .find(|schedule| schedule.id == schedule_id)
            .ok_or_else(|| format!("no schedule {schedule_id}"))?;
        let store = TaskStore::open(&self.root, &schedule.id)?;
        let latest_in_progress = store
            .latest_run()
            .is_some_and(|run| run.status.is_in_progress());
        if latest_in_progress || self.run_now.contains_key(&schedule.id) {
            return Err(format!(
                "a Run of {} is still in progress",
                display_name(schedule)
            ));
        }
        let run_id = new_run_id();
        self.run_now.insert(schedule.id.clone(), run_id.clone());
        Ok(run_id)
    }

    /// One sweep: step every task at `now` and perform the actions.
    pub fn sweep(
        &mut self,
        schedules: &[Schedule],
        projects: &[HostCreateProject],
        presets: &[HostCreatePreset],
        hook_port: Option<u16>,
        now: &Zoned,
    ) -> Vec<SweepEvent> {
        let mut events = Vec::new();
        while let Ok(outcome) = self.outcomes_rx.try_recv() {
            self.launching.remove(&outcome.run_id);
            if let Some(error) = outcome.error {
                self.spawn_failures.insert(outcome.run_id, error);
            }
        }
        self.run_now
            .retain(|id, _| schedules.iter().any(|schedule| schedule.id == *id));

        let now_ms = clock::epoch_ms(now);
        let mut tasks = Vec::new();
        for schedule in schedules {
            match self.task_state(schedule, projects, presets, now, now_ms, &mut events) {
                Ok(task) => tasks.push(task),
                Err(error) => self.warn(&schedule.id, error, &mut events),
            }
        }
        let actions = step::step(&tasks, now, &mut new_run_id);
        self.perform(actions, hook_port, &mut events);
        events
    }

    fn task_state(
        &mut self,
        schedule: &Schedule,
        projects: &[HostCreateProject],
        presets: &[HostCreatePreset],
        now: &Zoned,
        now_ms: u64,
        events: &mut Vec<SweepEvent>,
    ) -> Result<TaskState, String> {
        let store = TaskStore::open(&self.root, &schedule.id)?;
        let clock = match store.clock() {
            Ok(clock) => clock,
            Err(error) => {
                // A clock that will not read has lost its last occurrence;
                // restarting it from now can miss one occurrence but never
                // fires one twice. The step rewrites the file.
                self.warn(
                    &schedule.id,
                    format!("{error}; restarting its clock from now"),
                    events,
                );
                ScheduleClock {
                    last_occurrence: Some(clock::format_datetime(now.datetime())),
                    ..ScheduleClock::default()
                }
            }
        };
        let latest_run = store.latest_run();
        let observation = latest_run
            .as_ref()
            .map(|run| self.observe(run, now_ms))
            .unwrap_or(RunObservation::Idle);
        Ok(TaskState {
            schedule: schedule.clone(),
            clock,
            latest_run,
            observation,
            run_now: self.run_now.remove(&schedule.id),
            launch: launch::resolve(schedule, projects, presets),
        })
    }

    fn observe(&mut self, run: &ScheduleRun, now_ms: u64) -> RunObservation {
        if run.status != RunStatus::Running {
            return RunObservation::Idle;
        }
        if let Some(error) = self.spawn_failures.remove(&run.run_id) {
            return RunObservation::SpawnFailed(error);
        }
        if self.launching.contains(&run.run_id) {
            return RunObservation::Launching;
        }
        let Some(session_id) = run.session_id.as_deref() else {
            return RunObservation::Missing;
        };
        // State first, then the exit record: the launch script writes the
        // record before its shell can exit, so a stopped Session with no
        // record really has none.
        match self.effects.session(session_id) {
            (_, Some(code)) => RunObservation::Exited(code),
            (SessionSeen::Live, None) => RunObservation::Live,
            (SessionSeen::Stopped, None) => RunObservation::Ended,
            (SessionSeen::Absent, None) => {
                let started = run.started_at_ms.unwrap_or(0);
                if now_ms.saturating_sub(started) < LAUNCH_GRACE_MS {
                    RunObservation::Launching
                } else {
                    RunObservation::Missing
                }
            }
        }
    }

    fn perform(
        &mut self,
        actions: Vec<Action>,
        hook_port: Option<u16>,
        events: &mut Vec<SweepEvent>,
    ) {
        // A task whose clock did not save must start nothing this sweep: the
        // occurrence would fire again on the next one.
        let mut held: HashSet<String> = HashSet::new();
        for action in actions {
            match action {
                Action::SaveClock { schedule_id, clock } => {
                    if let Err(error) = self.store(&schedule_id).and_then(|s| s.save_clock(&clock))
                    {
                        held.insert(schedule_id.clone());
                        self.warn(&schedule_id, format!("saving its clock: {error}"), events);
                    }
                }
                Action::Start { schedule_id, .. } | Action::Record { schedule_id, .. }
                    if held.contains(&schedule_id) => {}
                Action::Start {
                    schedule_id,
                    run,
                    plan,
                } => self.start(schedule_id, run, plan, hook_port, events),
                Action::Record { schedule_id, run } => {
                    match self.store(&schedule_id).and_then(|s| s.append_run(&run)) {
                        Ok(()) => events.push(SweepEvent::Recorded {
                            schedule_id,
                            run_id: run.run_id,
                            status: run.status,
                        }),
                        Err(error) => {
                            self.warn(&schedule_id, format!("recording a Run: {error}"), events)
                        }
                    }
                }
                Action::Disable { schedule_id } => {
                    if let Err(error) = self.effects.disable(&schedule_id) {
                        self.warn(&schedule_id, format!("disabling it: {error}"), events);
                    }
                }
            }
        }
    }

    fn start(
        &mut self,
        schedule_id: String,
        run: ScheduleRun,
        plan: LaunchPlan,
        hook_port: Option<u16>,
        events: &mut Vec<SweepEvent>,
    ) {
        let session_id = uuid::Uuid::new_v4().to_string().to_lowercase();
        let run = ScheduleRun {
            session_id: Some(session_id.clone()),
            ..run
        };
        if let Err(error) = self.store(&schedule_id).and_then(|s| s.append_run(&run)) {
            self.warn(&schedule_id, format!("recording its Run: {error}"), events);
            return;
        }
        let request = SpawnRequest {
            spawned_by: format!("{}{schedule_id}", unpeel_core::schedules::SPAWNED_BY_PREFIX),
            schedule_id: schedule_id.clone(),
            run_id: run.run_id.clone(),
            session_id: session_id.clone(),
            plan,
            hook_port,
        };
        let effects = Arc::clone(&self.effects);
        let outcomes = self.outcomes_tx.clone();
        let run_id = run.run_id.clone();
        self.launching.insert(run_id.clone());
        let spawned = std::thread::Builder::new()
            .name("unpeel-schedules".into())
            .spawn(move || {
                let error = effects.spawn(request).err();
                let _ = outcomes.send(SpawnOutcome { run_id, error });
            });
        if let Err(error) = spawned {
            self.launching.remove(&run.run_id);
            self.spawn_failures
                .insert(run.run_id.clone(), format!("no helper thread: {error}"));
        }
        events.push(SweepEvent::Started {
            schedule_id,
            run_id: run.run_id,
            session_id,
        });
    }

    fn store(&self, schedule_id: &str) -> Result<TaskStore, String> {
        TaskStore::open(&self.root, schedule_id)
    }

    fn warn(&mut self, schedule_id: &str, error: String, events: &mut Vec<SweepEvent>) {
        if self.warned.get(schedule_id) == Some(&error) {
            return;
        }
        self.warned.insert(schedule_id.to_string(), error.clone());
        events.push(SweepEvent::Warning(format!(
            "schedule {schedule_id}: {error}"
        )));
    }
}

fn display_name(schedule: &Schedule) -> &str {
    if schedule.name.trim().is_empty() {
        &schedule.id
    } else {
        &schedule.name
    }
}

fn new_run_id() -> String {
    format!("run_{}", uuid::Uuid::new_v4().simple())
}

/// The real Host: Sessions through the core spawn path, state from the
/// Session's manifest and `startup-exit`, definitions in `app-state.json`.
pub struct HostEffects;

impl Effects for HostEffects {
    fn spawn(&self, request: SpawnRequest) -> Result<(), String> {
        let plan = request.plan;
        let session = unpeel_core::state::SessionInfo {
            id: request.session_id.clone(),
            project_id: plan.project_id,
            label: unpeel_core::state::initial_session_label(&plan.command, &plan.cwd),
            custom_title: false,
            command: plan.command,
            created_at: clock::epoch_ms(&clock::now()),
            // The session Host binds a launch without an owner to the Host
            // owner before publishing its manifest, as for `unpeel new`.
            owner_principal_id: None,
            created_by_device_id: None,
            source_preset_id: Some(plan.preset_id),
            tag_id: None,
            worktree_path: plan.worktree_path,
            worktree_branch: plan.worktree_branch,
            parent_session_id: None,
            spawned_by: Some(request.spawned_by),
            role: None,
            task: None,
        };
        unpeel_core::session_ops::spawn_scheduled_session(
            session,
            &plan.cwd,
            request.hook_port,
            SESSION_COLUMNS,
            SESSION_ROWS,
            unpeel_core::session_host::ScheduleRunLaunch {
                schedule_id: request.schedule_id,
                run_id: request.run_id,
            },
        )?;
        wait_for_manifest(&request.session_id, MANIFEST_TIMEOUT)
    }

    fn session(&self, session_id: &str) -> (SessionSeen, Option<i32>) {
        let seen = match unpeel_core::session_host::load_manifest(session_id) {
            None => SessionSeen::Absent,
            Some(manifest) if unpeel_core::session_host::manifest_is_live(&manifest) => {
                SessionSeen::Live
            }
            Some(_) => SessionSeen::Stopped,
        };
        (
            seen,
            unpeel_core::session_host::read_startup_exit(session_id),
        )
    }

    fn disable(&self, schedule_id: &str) -> Result<(), String> {
        unpeel_core::app_state::edit(|state| {
            let entry = state
                .get_mut("schedules")
                .and_then(serde_json::Value::as_array_mut)
                .and_then(|entries| {
                    entries.iter_mut().find(|entry| {
                        entry.get("id").and_then(serde_json::Value::as_str) == Some(schedule_id)
                    })
                })
                .and_then(serde_json::Value::as_object_mut);
            if let Some(entry) = entry {
                entry.insert("enabled".into(), serde_json::Value::Bool(false));
            }
            Ok(())
        })
    }
}

/// A Session that exits at once (a preset that is a bare `exit 3`) still
/// publishes a manifest, so "it exists" is the whole wait.
fn wait_for_manifest(session_id: &str, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if unpeel_core::session_host::load_manifest(session_id).is_some() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(format!(
        "the Session did not start within {} s",
        timeout.as_secs()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;
    use jiff::tz::{self, TimeZone};
    use std::sync::Mutex;
    use unpeel_core::schedules::ScheduleTrigger;

    /// Records what the store held when each Session was started.
    #[derive(Default)]
    struct Recording {
        root: PathBuf,
        spawned: Mutex<Vec<(SpawnRequest, ScheduleClock, Option<ScheduleRun>)>>,
        disabled: Mutex<Vec<String>>,
        spawn_error: Option<String>,
        seen: Mutex<HashMap<String, (SessionSeen, Option<i32>)>>,
    }

    impl Effects for Recording {
        fn spawn(&self, request: SpawnRequest) -> Result<(), String> {
            let store = TaskStore::open(&self.root, &request.schedule_id).unwrap();
            let clock = store.clock().unwrap();
            let run = store.latest_run();
            self.spawned.lock().unwrap().push((request, clock, run));
            match &self.spawn_error {
                Some(error) => Err(error.clone()),
                None => Ok(()),
            }
        }

        fn session(&self, session_id: &str) -> (SessionSeen, Option<i32>) {
            self.seen
                .lock()
                .unwrap()
                .get(session_id)
                .copied()
                .unwrap_or((SessionSeen::Absent, None))
        }

        fn disable(&self, schedule_id: &str) -> Result<(), String> {
            self.disabled.lock().unwrap().push(schedule_id.to_string());
            Ok(())
        }
    }

    fn root_of(scheduler: &Scheduler) -> &std::path::Path {
        &scheduler.root
    }

    fn now(hour: i8, minute: i8, second: i8) -> Zoned {
        date(2026, 11, 6)
            .at(hour, minute, second, 0)
            .to_zoned(TimeZone::fixed(tz::offset(-5)))
            .unwrap()
    }

    fn schedule(trigger: ScheduleTrigger) -> Schedule {
        Schedule {
            id: "sch_1".into(),
            name: "Morning".into(),
            project_id: "p".into(),
            preset_id: "ok".into(),
            trigger,
            enabled: true,
            notify_when_done: true,
            created_at_ms: clock::epoch_ms(&now(8, 0, 0)),
        }
    }

    fn catalog() -> (Vec<HostCreateProject>, Vec<HostCreatePreset>) {
        (
            vec![HostCreateProject {
                id: "p".into(),
                path: "/tmp".into(),
                is_folder: false,
                worktree_path: None,
                worktree_branch: None,
            }],
            vec![HostCreatePreset {
                id: "ok".into(),
                command: "true".into(),
                enabled: true,
                project_id: None,
            }],
        )
    }

    fn with_scheduler<T>(
        effects: Recording,
        body: impl FnOnce(&mut Scheduler, &Recording) -> T,
    ) -> T {
        let root = std::env::temp_dir().join(format!("unpeel-sched-{}", uuid::Uuid::new_v4()));
        let effects = Arc::new(Recording {
            root: root.clone(),
            ..effects
        });
        let mut scheduler = Scheduler::new(root.clone(), effects.clone());
        let outcome = body(&mut scheduler, &effects);
        let _ = std::fs::remove_dir_all(&root);
        outcome
    }

    fn sweep(scheduler: &mut Scheduler, schedules: &[Schedule], at: &Zoned) -> Vec<SweepEvent> {
        let (projects, presets) = catalog();
        scheduler.sweep(schedules, &projects, &presets, Some(4321), at)
    }

    /// Wait for the helper thread, then let a sweep drain its outcome.
    fn settle(effects: &Recording, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while effects.spawned.lock().unwrap().len() < count && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        std::thread::sleep(Duration::from_millis(20));
    }

    #[test]
    fn a_run_starts_only_after_its_occurrence_and_run_are_on_disk() {
        with_scheduler(Recording::default(), |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Daily {
                time: "09:00".into(),
            })];
            let events = sweep(scheduler, &tasks, &now(9, 0, 0));
            settle(effects, 1);
            let spawned = effects.spawned.lock().unwrap();
            assert_eq!(spawned.len(), 1, "{events:?}");
            let (request, clock, run) = &spawned[0];
            assert_eq!(clock.last_occurrence.as_deref(), Some("2026-11-06T09:00"));
            let run = run
                .as_ref()
                .expect("the Run was recorded before its Session");
            assert_eq!(run.status, RunStatus::Running);
            assert_eq!(run.session_id.as_deref(), Some(request.session_id.as_str()));
            assert_eq!(request.spawned_by, "schedule:sch_1");
            assert_eq!(request.plan.command, "true");
            assert_eq!(request.hook_port, Some(4321));
            assert!(root_of(scheduler).join("sch_1").join("runs.jsonl").exists());
        });
    }

    #[test]
    fn a_session_that_cannot_start_records_the_run_failed() {
        let effects = Recording {
            spawn_error: Some("unpeel-host exited with 1".into()),
            ..Recording::default()
        };
        with_scheduler(effects, |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Daily {
                time: "09:00".into(),
            })];
            sweep(scheduler, &tasks, &now(9, 0, 0));
            settle(effects, 1);
            sweep(scheduler, &tasks, &now(9, 0, 1));
            let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
            let run = store.latest_run().expect("a Run");
            assert_eq!(run.status, RunStatus::Failed);
            assert!(run.reason.unwrap().contains("unpeel-host exited with 1"));
        });
    }

    #[test]
    fn a_script_run_finishes_from_its_exit_record() {
        with_scheduler(Recording::default(), |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Daily {
                time: "09:00".into(),
            })];
            sweep(scheduler, &tasks, &now(9, 0, 0));
            settle(effects, 1);
            let session_id = effects.spawned.lock().unwrap()[0].0.session_id.clone();
            effects
                .seen
                .lock()
                .unwrap()
                .insert(session_id.clone(), (SessionSeen::Live, None));
            sweep(scheduler, &tasks, &now(9, 0, 1));
            let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
            assert_eq!(store.latest_run().unwrap().status, RunStatus::Running);

            effects
                .seen
                .lock()
                .unwrap()
                .insert(session_id, (SessionSeen::Live, Some(3)));
            sweep(scheduler, &tasks, &now(9, 0, 2));
            let run = store.latest_run().unwrap();
            assert_eq!((run.status, run.exit_code), (RunStatus::Failed, Some(3)));
            assert_eq!(
                store.clock().unwrap().last_run_status,
                Some(RunStatus::Failed)
            );
        });
    }

    #[test]
    fn run_now_is_refused_while_a_run_is_in_progress() {
        with_scheduler(Recording::default(), |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Daily {
                time: "23:00".into(),
            })];
            let run_id = scheduler
                .request_run_now("sch_1", &tasks)
                .expect("accepted");
            assert!(
                scheduler.request_run_now("sch_1", &tasks).is_err(),
                "already queued"
            );
            sweep(scheduler, &tasks, &now(9, 0, 0));
            settle(effects, 1);
            let spawned = effects.spawned.lock().unwrap()[0].0.clone();
            assert_eq!(spawned.run_id, run_id);
            effects
                .seen
                .lock()
                .unwrap()
                .insert(spawned.session_id, (SessionSeen::Live, None));
            sweep(scheduler, &tasks, &now(9, 0, 1));
            let refused = scheduler.request_run_now("sch_1", &tasks).unwrap_err();
            assert!(refused.contains("in progress"), "{refused}");
            assert!(scheduler.request_run_now("sch_missing", &tasks).is_err());
        });
    }

    #[test]
    fn a_once_task_is_disabled_when_it_fires() {
        with_scheduler(Recording::default(), |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Once {
                at: "2026-11-06T09:00:05".into(),
            })];
            sweep(scheduler, &tasks, &now(9, 0, 5));
            settle(effects, 1);
            assert_eq!(*effects.disabled.lock().unwrap(), vec!["sch_1".to_string()]);
        });
    }

    #[test]
    fn a_damaged_clock_restarts_from_now_and_never_refires() {
        with_scheduler(Recording::default(), |scheduler, effects| {
            let tasks = [schedule(ScheduleTrigger::Daily {
                time: "09:00".into(),
            })];
            let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
            std::fs::create_dir_all(store.dir()).unwrap();
            std::fs::write(store.dir().join("clock.json"), b"{torn").unwrap();
            sweep(scheduler, &tasks, &now(9, 30, 0));
            settle(effects, 0);
            assert!(effects.spawned.lock().unwrap().is_empty());
            assert_eq!(
                store.clock().unwrap().last_occurrence.as_deref(),
                Some("2026-11-06T09:30")
            );
        });
    }
}
