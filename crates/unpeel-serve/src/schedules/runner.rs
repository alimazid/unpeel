//! The workspace worker's side of the scheduler. Each sweep it reads every
//! task's clock and latest Run from disk (so a Host restart resumes where
//! the last one stopped), observes running Runs' Sessions, steps, and
//! performs the actions in order. Starting a Session, and for an agent Run
//! waiting for the agent and typing its instructions, runs on an
//! `unpeel-schedules` helper thread; its outcomes come back over a channel,
//! like auto-stop's. An agent Run is then followed through the worker's own
//! activity rows, which the worker passes in every sweep.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use jiff::Zoned;
use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::controller_schedules::{unknown_task_message, RunNowRefusal};
use unpeel_core::schedule_store::{TaskStore, TaskWrite};
use unpeel_core::schedules::{RunStatus, Schedule, ScheduleClock, ScheduleRun};
use unpeel_core::state::Preset;

use super::agent_run::{self, AgentActivity, AgentObservation, Delivery};
use super::clock;
use super::launch;
use super::step::{self, Action, LaunchPlan, RunObservation, TaskState};

/// A just-started Run's Session may not have published its manifest yet;
/// until this long after its start a missing manifest means "launching".
const LAUNCH_GRACE_MS: u64 = 30_000;
/// How long the helper thread waits for a new Session's manifest.
const MANIFEST_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a finished agent Run waits for its screen when it needs the
/// reply from there.
const SCREEN_READ_TIMEOUT: Duration = Duration::from_millis(200);
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
    /// Wait for the agent in a new Session to be ready, then type and
    /// submit its instructions, if it has any. Blocks (up to the readiness
    /// budget) on the helper thread.
    fn deliver(&self, session_id: &str, instructions: Option<&str>) -> Delivery;
    /// The Session's state and its command's exit status, if recorded.
    fn session(&self, session_id: &str) -> (SessionSeen, Option<i32>);
    /// The agent's reply as its screen shows it, for a finished agent Run
    /// whose agent reported none.
    fn screen_reply(&self, session_id: &str, instructions: &str) -> Option<String>;
    /// Turn a task off in `app-state.json`.
    fn disable(&self, schedule_id: &str) -> Result<(), String>;
    /// Whether the task is still among the saved Scheduled Tasks, read
    /// afresh: the sweep's definitions may predate a delete.
    fn is_defined(&self, schedule_id: &str) -> Result<bool, String>;
}

/// What a sweep did, for the worker's trace and warnings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SweepEvent {
    /// A Run was recorded and its Session is being started.
    Started {
        schedule_id: String,
        run_id: String,
        session_id: String,
    },
    /// A Run's Session did start: only now may the task's earlier Run
    /// Sessions be stopped (a failed start leaves them alone).
    Spawned {
        schedule_id: String,
        session_id: String,
    },
    /// A Run line was appended: `run` as recorded, and `previous` the
    /// Run's status before it (`None` for a Run this line begins), so the
    /// worker can tell a status entered from one recorded again.
    Recorded {
        schedule_id: String,
        run: ScheduleRun,
        previous: Option<RunStatus>,
    },
    /// The task's clock changed on disk (its next run, its latest Run), so
    /// a Controller that read the list before this sweep reads it again.
    Published {
        schedule_id: String,
    },
    /// The task was deleted after this sweep read its definition: the
    /// sweep dropped its remaining actions, so nothing more of it is
    /// written and no Run of it starts.
    Deleted {
        schedule_id: String,
    },
    Warning(String),
}

impl SweepEvent {
    /// Whether a Controller that read the schedules before this sweep
    /// should read them again. A warning, or a task deleted mid-sweep (its
    /// delete announced already), changed nothing on disk.
    pub fn changes_schedules(&self) -> bool {
        !matches!(self, Self::Warning(_) | Self::Deleted { .. })
    }
}

/// What a helper thread reports, in order.
enum HelperEvent {
    /// The Session started (or could not); `delivering` when the helper
    /// goes on to type the Run's instructions.
    Spawned {
        schedule_id: String,
        run_id: String,
        session_id: String,
        error: Option<String>,
        delivering: bool,
    },
    Delivered {
        run_id: String,
        delivery: Delivery,
    },
}

/// What a sweep resolves Runs against: the Host's create catalog, plus every
/// preset row in the app state so a Run that cannot start names its preset.
#[derive(Debug, Clone, Copy, Default)]
pub struct RunCatalog<'a> {
    pub projects: &'a [HostCreateProject],
    pub presets: &'a [HostCreatePreset],
    pub known_presets: &'a [Preset],
}

pub struct Scheduler {
    root: PathBuf,
    effects: Arc<dyn Effects>,
    /// Runs whose Session a helper thread is starting.
    launching: HashSet<String>,
    /// Agent Runs whose helper waits to type their instructions.
    delivering: HashSet<String>,
    /// Agent Runs' delivery outcomes, until their Run line moves past
    /// `waiting_ready`.
    deliveries: HashMap<String, Delivery>,
    /// Runs whose Session failed to start, until the next step records it.
    spawn_failures: HashMap<String, String>,
    /// How long an agent has to show a working signal after its prompt.
    working_timeout_ms: u64,
    /// Accepted Run now requests: task id → Run id.
    run_now: HashMap<String, String>,
    /// The last warning per task, so a lasting problem warns once.
    warned: HashMap<String, String>,
    outcomes_tx: mpsc::Sender<HelperEvent>,
    outcomes_rx: mpsc::Receiver<HelperEvent>,
}

impl Default for Scheduler {
    fn default() -> Self {
        Self {
            working_timeout_ms: agent_run::working_timeout_ms(),
            ..Self::new(
                unpeel_core::schedule_store::schedules_root(),
                Arc::new(HostEffects),
            )
        }
    }
}

impl Scheduler {
    pub fn new(root: PathBuf, effects: Arc<dyn Effects>) -> Self {
        let (outcomes_tx, outcomes_rx) = mpsc::channel();
        Self {
            root,
            effects,
            launching: HashSet::new(),
            delivering: HashSet::new(),
            deliveries: HashMap::new(),
            spawn_failures: HashMap::new(),
            working_timeout_ms: agent_run::WORKING_TIMEOUT_MS,
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

    /// Whether a sweep against `schedules` has anything to do. A Run whose
    /// Session is starting, or whose instructions are being typed, keeps
    /// the sweeps going after its task is deleted: its helper's outcomes
    /// are drained only by a sweep, and the Session coming up still stops
    /// the task's earlier idle Runs (#30).
    pub fn needs_sweep(&self, schedules: &[Schedule]) -> bool {
        !schedules.is_empty()
            || self.has_pending()
            || !self.launching.is_empty()
            || !self.delivering.is_empty()
    }

    /// Accept Run now for `schedule_id`, unless a Run of it is in progress.
    /// The Run starts on the next sweep; its id comes back at once.
    pub fn request_run_now(
        &mut self,
        schedule_id: &str,
        schedules: &[Schedule],
    ) -> Result<String, RunNowRefusal> {
        let schedule = schedules
            .iter()
            .find(|schedule| schedule.id == schedule_id)
            .ok_or_else(|| RunNowRefusal::UnknownTask(unknown_task_message(schedule_id)))?;
        let store = TaskStore::open(&self.root, &schedule.id).map_err(RunNowRefusal::Internal)?;
        let latest_in_progress = store
            .current_run()
            .map_err(|error| {
                RunNowRefusal::RunLogUnreadable(format!(
                    "cannot tell whether a Run of {} is in progress: {error}",
                    display_name(schedule)
                ))
            })?
            .is_some_and(|run| run.status.is_in_progress());
        if latest_in_progress || self.run_now.contains_key(&schedule.id) {
            return Err(RunNowRefusal::InProgress(format!(
                "a Run of {} is still in progress",
                display_name(schedule)
            )));
        }
        let run_id = new_run_id();
        self.run_now.insert(schedule.id.clone(), run_id.clone());
        Ok(run_id)
    }

    /// One sweep: step every task at `now` and perform the actions.
    /// `activity` is the worker's rows for this rescan, by Session id.
    pub fn sweep(
        &mut self,
        schedules: &[Schedule],
        catalog: &RunCatalog,
        activity: &HashMap<String, AgentActivity>,
        hook_port: Option<u16>,
        now: &Zoned,
    ) -> Vec<SweepEvent> {
        let mut events = Vec::new();
        self.drain_helpers(&mut events);
        self.run_now
            .retain(|id, _| schedules.iter().any(|schedule| schedule.id == *id));

        let mut tasks = Vec::new();
        for schedule in schedules {
            match self.task_state(schedule, catalog, activity, now, &mut events) {
                Ok(task) => tasks.push(task),
                Err(error) => {
                    // A Run now accepted before the task stopped reading
                    // does not wait for it.
                    self.run_now.remove(&schedule.id);
                    self.warn(&schedule.id, error, &mut events)
                }
            }
        }
        self.forget_settled_deliveries(&tasks);
        let before = tasks
            .iter()
            .filter_map(|task| task.latest_run.as_ref())
            .map(|run| (run.run_id.clone(), run.status))
            .collect::<HashMap<_, _>>();
        let actions = step::step(&tasks, now, &mut new_run_id);
        self.perform(actions, schedules, &before, hook_port, &mut events);
        events
    }

    fn drain_helpers(&mut self, events: &mut Vec<SweepEvent>) {
        while let Ok(event) = self.outcomes_rx.try_recv() {
            match event {
                HelperEvent::Spawned {
                    schedule_id,
                    run_id,
                    session_id,
                    error,
                    delivering,
                } => {
                    self.launching.remove(&run_id);
                    if let Some(error) = error {
                        self.spawn_failures.insert(run_id, error);
                        continue;
                    }
                    if delivering {
                        self.delivering.insert(run_id);
                    }
                    events.push(SweepEvent::Spawned {
                        schedule_id,
                        session_id,
                    });
                }
                HelperEvent::Delivered { run_id, delivery } => {
                    self.delivering.remove(&run_id);
                    self.deliveries.insert(run_id, delivery);
                }
            }
        }
    }

    /// A delivery outcome is kept until its Run's line has moved past it, so
    /// a sweep that could not record it (a clock that would not save) sees
    /// it again.
    fn forget_settled_deliveries(&mut self, tasks: &[TaskState]) {
        self.deliveries.retain(|run_id, _| {
            tasks.iter().any(|task| {
                task.latest_run.as_ref().is_some_and(|run| {
                    run.run_id == *run_id && run.status.is_in_progress() && run.is_starting_agent()
                })
            })
        });
    }

    fn task_state(
        &mut self,
        schedule: &Schedule,
        catalog: &RunCatalog,
        activity: &HashMap<String, AgentActivity>,
        now: &Zoned,
        events: &mut Vec<SweepEvent>,
    ) -> Result<TaskState, String> {
        let now_ms = clock::epoch_ms(now);
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
        // A Run log that will not read could be hiding the Run in progress:
        // the task is not stepped, so nothing starts on a guess.
        let latest_run = store
            .current_run()
            .map_err(|error| format!("{error}; starting nothing until it reads"))?;
        let observation = latest_run
            .as_ref()
            .map(|run| self.observe(run, activity, now_ms))
            .unwrap_or(RunObservation::Idle);
        Ok(TaskState {
            schedule: schedule.clone(),
            clock,
            latest_run,
            observation,
            run_now: self.run_now.remove(&schedule.id),
            launch: launch::resolve(
                schedule,
                catalog.projects,
                catalog.presets,
                catalog.known_presets,
            ),
        })
    }

    fn observe(
        &mut self,
        run: &ScheduleRun,
        activity: &HashMap<String, AgentActivity>,
        now_ms: u64,
    ) -> RunObservation {
        if !run.status.is_in_progress() {
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
            (SessionSeen::Live, None) if run.is_agent_run() => {
                RunObservation::Agent(AgentObservation {
                    delivery: self.delivery_of(run),
                    activity: activity.get(session_id).cloned().unwrap_or_default(),
                    working_timeout_ms: self.working_timeout_ms,
                })
            }
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

    /// While an agent Run starts: what its helper reported. A Run still
    /// starting that no helper of this Host is typing for was being started
    /// by a Host that has since restarted.
    fn delivery_of(&self, run: &ScheduleRun) -> Option<Delivery> {
        if !run.is_starting_agent() {
            return None;
        }
        Some(match self.deliveries.get(&run.run_id) {
            Some(delivery) => delivery.clone(),
            None if self.delivering.contains(&run.run_id) => Delivery::Waiting,
            None => Delivery::Interrupted,
        })
    }

    /// A finished agent Run whose agent reported no reply takes it from the
    /// agent's screen, which still shows it.
    fn with_screen_reply(
        &self,
        run: ScheduleRun,
        schedules: &[Schedule],
        schedule_id: &str,
    ) -> ScheduleRun {
        let wants_screen =
            run.status == RunStatus::Done && run.prompted_at_ms.is_some() && run.snippet.is_none();
        let instructions = schedules
            .iter()
            .find(|schedule| schedule.id == schedule_id)
            .and_then(|schedule| schedule.instructions.as_deref())
            .unwrap_or_default();
        match run.session_id.as_deref().filter(|_| wants_screen) {
            Some(session_id) => ScheduleRun {
                snippet: self.effects.screen_reply(session_id, instructions),
                ..run
            },
            None => run,
        }
    }

    /// `before` is each task's latest Run status as this sweep found it.
    fn perform(
        &mut self,
        actions: Vec<Action>,
        schedules: &[Schedule],
        before: &HashMap<String, RunStatus>,
        hook_port: Option<u16>,
        events: &mut Vec<SweepEvent>,
    ) {
        // A task whose clock did not save must start, record and disable
        // nothing this sweep: the occurrence would fire again on the next.
        // Nor must one deleted since the sweep read it.
        let mut held: HashSet<String> = HashSet::new();
        for action in actions {
            match action {
                Action::SaveClock { schedule_id, clock } => {
                    let saved = self.store(&schedule_id).and_then(|s| {
                        s.save_clock(&clock, || self.effects.is_defined(&schedule_id))
                    });
                    match saved {
                        Ok(TaskWrite::Written) => {
                            events.push(SweepEvent::Published { schedule_id })
                        }
                        Ok(TaskWrite::TaskDeleted) => drop_deleted(schedule_id, &mut held, events),
                        Err(error) => {
                            held.insert(schedule_id.clone());
                            self.warn(&schedule_id, format!("saving its clock: {error}"), events);
                        }
                    }
                }
                Action::Start { schedule_id, .. }
                | Action::Record { schedule_id, .. }
                | Action::Disable { schedule_id }
                    if held.contains(&schedule_id) => {}
                Action::Start {
                    schedule_id,
                    run,
                    plan,
                } => match schedules.iter().find(|schedule| schedule.id == schedule_id) {
                    Some(schedule) => match self.start(schedule, run, plan, hook_port, events) {
                        Ok(TaskWrite::Written) => {}
                        Ok(TaskWrite::TaskDeleted) => drop_deleted(schedule_id, &mut held, events),
                        Err(error) => {
                            self.warn(&schedule_id, format!("recording its Run: {error}"), events)
                        }
                    },
                    None => self.warn(&schedule_id, "no longer defined".into(), events),
                },
                Action::Record { schedule_id, run } => {
                    match self.record(&schedule_id, run, schedules, before, events) {
                        Ok(TaskWrite::Written) => {}
                        Ok(TaskWrite::TaskDeleted) => drop_deleted(schedule_id, &mut held, events),
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

    /// Append a Run line (a finished agent Run first takes its reply from
    /// the screen when its agent reported none).
    fn record(
        &self,
        schedule_id: &str,
        run: ScheduleRun,
        schedules: &[Schedule],
        before: &HashMap<String, RunStatus>,
        events: &mut Vec<SweepEvent>,
    ) -> Result<TaskWrite, String> {
        let run = self.with_screen_reply(run, schedules, schedule_id);
        let recorded = self.store(schedule_id)?.append_run(&run)?;
        if recorded == TaskWrite::Written {
            events.push(SweepEvent::Recorded {
                previous: before.get(&run.run_id).copied(),
                schedule_id: schedule_id.to_string(),
                run,
            });
        }
        Ok(recorded)
    }

    /// Record the Run with the id of the Session it starts, then start that
    /// Session on a helper thread. A task deleted since the sweep read it
    /// records and starts nothing.
    fn start(
        &mut self,
        schedule: &Schedule,
        run: ScheduleRun,
        plan: LaunchPlan,
        hook_port: Option<u16>,
        events: &mut Vec<SweepEvent>,
    ) -> Result<TaskWrite, String> {
        let session_id = uuid::Uuid::new_v4().to_string().to_lowercase();
        let run = ScheduleRun {
            session_id: Some(session_id.clone()),
            ..run
        };
        let recorded = self
            .store(&schedule.id)?
            .append_run_if_defined(&run, || self.effects.is_defined(&schedule.id))?;
        if recorded == TaskWrite::TaskDeleted {
            return Ok(recorded);
        }
        self.launching.insert(run.run_id.clone());
        let request = SpawnRequest {
            spawned_by: schedule.spawned_by(),
            schedule_id: schedule.id.clone(),
            run_id: run.run_id.clone(),
            session_id: session_id.clone(),
            plan,
            hook_port,
        };
        if let Err(error) = self.spawn_helper(request) {
            self.launching.remove(&run.run_id);
            self.spawn_failures
                .insert(run.run_id.clone(), format!("no helper thread: {error}"));
        }
        events.push(SweepEvent::Started {
            schedule_id: schedule.id.clone(),
            run_id: run.run_id,
            session_id,
        });
        Ok(TaskWrite::Written)
    }

    /// The `unpeel-schedules` helper: start the Session, then for an agent
    /// Run wait for the agent and type its instructions. Each outcome comes
    /// back over the channel, in order.
    fn spawn_helper(&self, request: SpawnRequest) -> std::io::Result<()> {
        let effects = Arc::clone(&self.effects);
        let outcomes = self.outcomes_tx.clone();
        std::thread::Builder::new()
            .name("unpeel-schedules".into())
            .spawn(move || {
                let agent = request.plan.kind.is_agent();
                let instructions = request.plan.kind.instructions().map(str::to_owned);
                let (schedule_id, run_id, session_id) = (
                    request.schedule_id.clone(),
                    request.run_id.clone(),
                    request.session_id.clone(),
                );
                let error = effects.spawn(request).err();
                let delivering = agent && error.is_none();
                let _ = outcomes.send(HelperEvent::Spawned {
                    schedule_id,
                    run_id: run_id.clone(),
                    session_id: session_id.clone(),
                    error,
                    delivering,
                });
                if delivering {
                    let delivery = effects.deliver(&session_id, instructions.as_deref());
                    let _ = outcomes.send(HelperEvent::Delivered { run_id, delivery });
                }
            })
            .map(|_| ())
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

/// A task deleted since the sweep read it: the sweep drops its remaining
/// actions quietly.
fn drop_deleted(schedule_id: String, held: &mut HashSet<String>, events: &mut Vec<SweepEvent>) {
    held.insert(schedule_id.clone());
    events.push(SweepEvent::Deleted { schedule_id });
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

    /// The `agentReady` wait of `initial_text`: the agent's first readiness signal
    /// (program status, a hook, or its idle prompt; never the default
    /// idle), within its 120 s budget. Then the instructions go in as one
    /// bracketed paste and Enter, like every prompt typed into an agent.
    fn deliver(&self, session_id: &str, instructions: Option<&str>) -> Delivery {
        use unpeel_core::agent_readiness::ReadinessWait;
        use unpeel_core::initial_text::InitialTextOutcome;
        let Some(instructions) = instructions else {
            return match unpeel_core::initial_text::wait_for_agent(session_id) {
                ReadinessWait::Ready(_) => Delivery::Ready {
                    at_ms: clock::epoch_ms(&clock::now()),
                },
                ReadinessWait::TimedOut => Delivery::NotReady,
                ReadinessWait::Exited => Delivery::SessionEnded,
            };
        };
        match unpeel_core::initial_text::prompt_when_ready(session_id, instructions) {
            (InitialTextOutcome::Delivered { .. }, typed_at) => Delivery::Typed {
                at_ms: typed_at.unwrap_or_else(|| clock::epoch_ms(&clock::now())),
            },
            (InitialTextOutcome::ReadinessTimeout, _) => Delivery::NotReady,
            (InitialTextOutcome::Exited, _) => Delivery::SessionEnded,
            (InitialTextOutcome::HostNotReady(error), _) => {
                Delivery::Failed(format!("its Session never answered: {error}"))
            }
            (InitialTextOutcome::DeliveryFailed(error), _) => Delivery::Failed(error),
        }
    }

    fn screen_reply(&self, session_id: &str, instructions: &str) -> Option<String> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        let prompts = unpeel_core::session_host::active_runtime_id(&manifest)
            .and_then(unpeel_core::screen_activity::rules_for_runtime)
            .map(|rules| rules.idle_prompt.clone())
            .unwrap_or_default();
        let viewport = unpeel_core::session_host::request_current_viewport_snapshot_with_timeout(
            session_id,
            0,
            None,
            SCREEN_READ_TIMEOUT,
        )
        .ok()?;
        let screen = viewport
            .viewport_rows
            .iter()
            .map(|row| row.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        crate::completion_snippet::screen_reply(&screen, &prompts, instructions)
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
        use unpeel_core::schedules::save;
        unpeel_core::app_state::edit(|state| {
            let list = save::schedules_list_mut(state)?;
            if let Some(entry) = save::entry_mut(list, schedule_id) {
                entry.insert("enabled".into(), serde_json::Value::Bool(false));
            }
            Ok(())
        })
    }

    fn is_defined(&self, schedule_id: &str) -> Result<bool, String> {
        Ok(unpeel_core::schedule_store::load_schedules()?
            .iter()
            .any(|schedule| schedule.id == schedule_id))
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
mod tests;
