use super::*;
use crate::schedules::agent_run::AgentStatus;
use jiff::civil::date;
use jiff::tz::{self, TimeZone};
use std::sync::Mutex;
use unpeel_core::schedules::{RunPhase, ScheduleTrigger};

/// Records what the store held when each Session was started.
#[derive(Default)]
struct Recording {
    root: PathBuf,
    spawned: Mutex<Vec<(SpawnRequest, ScheduleClock, Option<ScheduleRun>)>>,
    disabled: Mutex<Vec<String>>,
    spawn_error: Option<String>,
    seen: Mutex<HashMap<String, (SessionSeen, Option<i32>)>>,
    /// (session id, instructions) per delivery, and what each returns
    /// (default: typed, or ready without instructions, at 09:00:01).
    delivered: Mutex<Vec<(String, Option<String>)>>,
    delivery: Option<Delivery>,
    /// What the agent's screen shows as its reply.
    screen: Option<String>,
}

impl Effects for Recording {
    fn spawn(&self, request: SpawnRequest) -> Result<(), String> {
        let store = TaskStore::open(&self.root, &request.schedule_id).unwrap();
        let clock = store.clock().unwrap();
        let run = store.current_run().unwrap();
        self.spawned.lock().unwrap().push((request, clock, run));
        match &self.spawn_error {
            Some(error) => Err(error.clone()),
            None => Ok(()),
        }
    }

    fn deliver(&self, session_id: &str, instructions: Option<&str>) -> Delivery {
        self.delivered
            .lock()
            .unwrap()
            .push((session_id.to_string(), instructions.map(str::to_string)));
        let at_ms = clock::epoch_ms(&now(9, 0, 1));
        self.delivery.clone().unwrap_or(match instructions {
            Some(_) => Delivery::Typed { at_ms },
            None => Delivery::Ready { at_ms },
        })
    }

    fn screen_reply(&self, _session_id: &str, _instructions: &str) -> Option<String> {
        self.screen.clone()
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
        instructions: None,
        trigger,
        enabled: true,
        notify_when_done: true,
        created_at_ms: clock::epoch_ms(&now(8, 0, 0)),
        clock_reset_at_ms: None,
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
        vec![
            HostCreatePreset {
                id: "ok".into(),
                command: "true".into(),
                enabled: true,
                project_id: None,
            },
            HostCreatePreset {
                id: "claude".into(),
                command: "claude".into(),
                enabled: true,
                project_id: None,
            },
        ],
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
    sweep_seeing(scheduler, schedules, &HashMap::new(), at)
}

/// A sweep whose worker rows show `activity` per Session id.
fn sweep_seeing(
    scheduler: &mut Scheduler,
    schedules: &[Schedule],
    activity: &HashMap<String, AgentActivity>,
    at: &Zoned,
) -> Vec<SweepEvent> {
    let (projects, presets) = catalog();
    scheduler.sweep(schedules, &projects, &presets, activity, Some(4321), at)
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

/// The Sessions of a sweep that came up (what lets the worker stop the
/// task's earlier Runs).
fn spawned(events: &[SweepEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|event| match event {
            SweepEvent::Spawned { session_id, .. } => Some(session_id.clone()),
            _ => None,
        })
        .collect()
}

/// Only a Session that actually started says so: a failed spawn leaves
/// the task's earlier Runs alone.
#[test]
fn a_run_says_its_session_is_up_only_once_it_started() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        let first = sweep(scheduler, &tasks, &now(9, 0, 0));
        assert!(spawned(&first).is_empty(), "not up yet: {first:?}");
        settle(effects, 1);
        let session_id = effects.spawned.lock().unwrap()[0].0.session_id.clone();
        let next = sweep(scheduler, &tasks, &now(9, 0, 1));
        assert_eq!(spawned(&next), vec![session_id]);
    });
    let failing = Recording {
        spawn_error: Some("unpeel-host exited with 1".into()),
        ..Recording::default()
    };
    with_scheduler(failing, |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        sweep(scheduler, &tasks, &now(9, 0, 0));
        settle(effects, 1);
        let next = sweep(scheduler, &tasks, &now(9, 0, 1));
        assert!(spawned(&next).is_empty(), "{next:?}");
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
        let run = store.current_run().unwrap().expect("a Run");
        assert_eq!(run.status, RunStatus::Failed);
        assert!(run.reason.unwrap().contains("unpeel-host exited with 1"));
    });
}

/// The Run lines a sweep recorded, with each Run's status before them.
fn recorded(events: &[SweepEvent]) -> Vec<(RunStatus, Option<RunStatus>)> {
    events
        .iter()
        .filter_map(|event| match event {
            SweepEvent::Recorded { run, previous, .. } => Some((run.status, *previous)),
            _ => None,
        })
        .collect()
}

#[test]
fn a_recorded_line_says_what_the_run_was_before_it() {
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
            .insert(session_id.clone(), (SessionSeen::Live, Some(0)));
        let events = sweep(scheduler, &tasks, &now(9, 0, 1));
        assert_eq!(
            recorded(&events),
            vec![(RunStatus::Done, Some(RunStatus::Running))]
        );
        let line = events.iter().find_map(|event| match event {
            SweepEvent::Recorded { run, .. } => Some(run.clone()),
            _ => None,
        });
        assert_eq!(
            line.and_then(|run| run.session_id),
            Some(session_id),
            "the event carries the line as recorded"
        );
    });
}

#[test]
fn a_run_that_cannot_launch_is_recorded_with_no_status_before_it() {
    with_scheduler(Recording::default(), |scheduler, _| {
        let tasks = [Schedule {
            preset_id: "gone".into(),
            ..schedule(ScheduleTrigger::Daily {
                time: "09:00".into(),
            })
        }];
        let events = sweep(scheduler, &tasks, &now(9, 0, 0));
        assert_eq!(recorded(&events), vec![(RunStatus::Failed, None)]);
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
        assert_eq!(
            store.current_run().unwrap().unwrap().status,
            RunStatus::Running
        );

        effects
            .seen
            .lock()
            .unwrap()
            .insert(session_id, (SessionSeen::Live, Some(3)));
        sweep(scheduler, &tasks, &now(9, 0, 2));
        let run = store.current_run().unwrap().unwrap();
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

/// A Run log that will not read could be hiding a Run in progress: the
/// task starts nothing, and Run now says why instead of starting one.
#[test]
fn a_task_whose_runs_cannot_be_read_starts_nothing() {
    with_scheduler(Recording::default(), |scheduler, _| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        std::fs::create_dir_all(root_of(scheduler).join("sch_1").join("runs.jsonl")).unwrap();
        let refused = scheduler.request_run_now("sch_1", &tasks).unwrap_err();
        assert!(refused.contains("runs.jsonl"), "{refused}");
        let events = sweep(scheduler, &tasks, &now(9, 0, 0));
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, SweepEvent::Started { .. })),
            "{events:?}"
        );
        assert!(
            events.iter().any(
                |event| matches!(event, SweepEvent::Warning(warning) if warning.contains("runs.jsonl"))
            ),
            "{events:?}"
        );
    });
}

/// A skip recorded behind a live Run must not make the scheduler forget
/// it: it still blocks Run now, and its finish is still recorded.
#[test]
fn a_run_with_an_occurrence_skipped_behind_it_is_still_followed() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        let run_id = scheduler.request_run_now("sch_1", &tasks).unwrap();
        sweep(scheduler, &tasks, &now(8, 59, 0));
        settle(effects, 1);
        let session_id = effects.spawned.lock().unwrap()[0].0.session_id.clone();
        let seen = |state| {
            effects
                .seen
                .lock()
                .unwrap()
                .insert(session_id.clone(), state);
        };
        seen((SessionSeen::Live, None));
        sweep(scheduler, &tasks, &now(9, 0, 0));
        let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
        let statuses: Vec<_> = store.runs().unwrap().iter().map(|run| run.status).collect();
        assert_eq!(statuses, vec![RunStatus::Running, RunStatus::Skipped]);
        assert_eq!(
            store.current_run().unwrap().map(|run| run.run_id),
            Some(run_id.clone())
        );
        let refused = scheduler.request_run_now("sch_1", &tasks).unwrap_err();
        assert!(refused.contains("in progress"), "{refused}");

        seen((SessionSeen::Live, Some(0)));
        sweep(scheduler, &tasks, &now(9, 0, 30));
        let finished = store.current_run().unwrap().expect("a Run");
        assert_eq!(
            (finished.run_id.as_str(), finished.status),
            (run_id.as_str(), RunStatus::Done)
        );
        assert_eq!(
            store.clock().unwrap().last_run_status,
            Some(RunStatus::Done)
        );
        assert_eq!(effects.spawned.lock().unwrap().len(), 1, "no second Run");
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

/// An occurrence whose clock could not be saved would fire again on the
/// next sweep, so it starts nothing and a Once task stays enabled.
#[test]
fn a_task_whose_clock_cannot_be_saved_starts_nothing() {
    use std::os::unix::fs::PermissionsExt;
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Once {
            at: "2026-11-06T09:00:05".into(),
        })];
        let dir = root_of(scheduler).join("sch_1");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o555)).unwrap();
        let events = sweep(scheduler, &tasks, &now(9, 0, 5));
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        settle(effects, 0);
        assert!(effects.spawned.lock().unwrap().is_empty(), "{events:?}");
        assert!(effects.disabled.lock().unwrap().is_empty(), "{events:?}");
        assert!(events.iter().any(
            |event| matches!(event, SweepEvent::Warning(warning) if warning.contains("clock"))
        ));
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

// ── Agent Runs ──

const INSTRUCTIONS: &str = "run the morning briefing";

fn agent_schedule() -> Schedule {
    Schedule {
        preset_id: "claude".into(),
        instructions: Some(INSTRUCTIONS.into()),
        ..schedule(ScheduleTrigger::Daily {
            time: "23:00".into(),
        })
    }
}

/// Run the agent task now and wait until its helper has typed.
fn start_agent_run(scheduler: &mut Scheduler, effects: &Recording) -> String {
    start_run_of(scheduler, effects, agent_schedule())
}

fn start_run_of(scheduler: &mut Scheduler, effects: &Recording, task: Schedule) -> String {
    let tasks = [task];
    scheduler
        .request_run_now("sch_1", &tasks)
        .expect("accepted");
    sweep(scheduler, &tasks, &now(9, 0, 0));
    settle(effects, 1);
    let deadline = Instant::now() + Duration::from_secs(5);
    while effects.delivered.lock().unwrap().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(20));
    let session_id = effects.spawned.lock().unwrap()[0].0.session_id.clone();
    effects
        .seen
        .lock()
        .unwrap()
        .insert(session_id.clone(), (SessionSeen::Live, None));
    session_id
}

fn seeing(session_id: &str, status: AgentStatus) -> HashMap<String, AgentActivity> {
    HashMap::from([(
        session_id.to_string(),
        AgentActivity {
            status,
            ..AgentActivity::default()
        },
    )])
}

fn latest(scheduler: &Scheduler) -> ScheduleRun {
    TaskStore::open(root_of(scheduler), "sch_1")
        .unwrap()
        .current_run()
        .unwrap()
        .expect("a Run")
}

#[test]
fn an_agent_run_types_its_instructions_and_follows_the_rows_to_done() {
    let effects = Recording {
        screen: Some("Morning briefing ready.".into()),
        ..Recording::default()
    };
    with_scheduler(effects, |scheduler, effects| {
        let session_id = start_agent_run(scheduler, effects);
        assert_eq!(
            *effects.delivered.lock().unwrap(),
            vec![(session_id.clone(), Some(INSTRUCTIONS.to_string()))],
            "the instructions are typed into the Run's own Session"
        );
        let tasks = [agent_schedule()];
        sweep_seeing(
            scheduler,
            &tasks,
            &seeing(&session_id, AgentStatus::Idle),
            &now(9, 0, 2),
        );
        let prompted = latest(scheduler);
        assert_eq!(prompted.phase, Some(RunPhase::Prompted));
        assert_eq!(
            prompted.prompted_at_ms,
            Some(clock::epoch_ms(&now(9, 0, 1)))
        );

        sweep_seeing(
            scheduler,
            &tasks,
            &seeing(&session_id, AgentStatus::Working),
            &now(9, 0, 5),
        );
        assert_eq!(latest(scheduler).phase, Some(RunPhase::Working));
        sweep_seeing(
            scheduler,
            &tasks,
            &seeing(&session_id, AgentStatus::Idle),
            &now(9, 1, 0),
        );
        let done = latest(scheduler);
        assert_eq!(done.status, RunStatus::Done);
        assert_eq!(
            done.snippet.as_deref(),
            Some("Morning briefing ready."),
            "an agent that reported no reply leaves it on its screen"
        );
        let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
        assert_eq!(
            store.clock().unwrap().last_run_status,
            Some(RunStatus::Done)
        );
    });
}

#[test]
fn an_agent_preset_task_without_instructions_is_done_once_its_agent_is_ready() {
    let effects = Recording {
        screen: Some("✻ Welcome back".into()),
        ..Recording::default()
    };
    with_scheduler(effects, |scheduler, effects| {
        let bare = Schedule {
            instructions: None,
            ..agent_schedule()
        };
        let session_id = start_run_of(scheduler, effects, bare.clone());
        assert_eq!(
            *effects.delivered.lock().unwrap(),
            vec![(session_id.clone(), None)],
            "the helper waits for the agent and types nothing"
        );
        sweep_seeing(
            scheduler,
            &[bare],
            &seeing(&session_id, AgentStatus::Idle),
            &now(9, 0, 2),
        );
        let done = latest(scheduler);
        assert_eq!(done.status, RunStatus::Done);
        assert_eq!(done.snippet, None, "no reply is read off its screen");
        assert_eq!(done.prompted_at_ms, None);
    });
}

#[test]
fn an_agent_that_never_gets_ready_fails_to_start() {
    let effects = Recording {
        delivery: Some(Delivery::NotReady),
        ..Recording::default()
    };
    with_scheduler(effects, |scheduler, effects| {
        let session_id = start_agent_run(scheduler, effects);
        let tasks = [agent_schedule()];
        sweep_seeing(
            scheduler,
            &tasks,
            &seeing(&session_id, AgentStatus::Silent),
            &now(9, 2, 1),
        );
        let run = latest(scheduler);
        assert_eq!(run.status, RunStatus::FailedToStart);
        assert_eq!(run.session_id.as_deref(), Some(session_id.as_str()));
    });
}

#[test]
fn a_needs_you_run_refuses_run_now_and_a_quiet_agent_needs_you_after_the_window() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        scheduler.working_timeout_ms = 5_000;
        let session_id = start_agent_run(scheduler, effects);
        let tasks = [agent_schedule()];
        let quiet = seeing(&session_id, AgentStatus::Idle);
        sweep_seeing(scheduler, &tasks, &quiet, &now(9, 0, 2));
        sweep_seeing(scheduler, &tasks, &quiet, &now(9, 0, 6));
        assert_eq!(latest(scheduler).status, RunStatus::Running);
        sweep_seeing(scheduler, &tasks, &quiet, &now(9, 0, 7));
        assert_eq!(latest(scheduler).status, RunStatus::NeedsYou);
        let refused = scheduler.request_run_now("sch_1", &tasks).unwrap_err();
        assert!(refused.contains("in progress"), "{refused}");
    });
}

#[test]
fn a_host_restart_while_a_run_starts_fails_it() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
        std::fs::create_dir_all(store.dir()).unwrap();
        let interrupted = ScheduleRun {
            run_id: "run_before_restart".into(),
            scheduled_for: None,
            started_at_ms: Some(clock::epoch_ms(&now(8, 59, 0))),
            ended_at_ms: None,
            status: RunStatus::Running,
            late: false,
            session_id: Some("session-live".into()),
            exit_code: None,
            reason: None,
            snippet: None,
            phase: Some(RunPhase::WaitingReady),
            prompted_at_ms: None,
        };
        store.append_run(&interrupted).unwrap();
        effects
            .seen
            .lock()
            .unwrap()
            .insert("session-live".into(), (SessionSeen::Live, None));
        sweep(scheduler, &[agent_schedule()], &now(9, 0, 0));
        let run = latest(scheduler);
        assert_eq!(run.status, RunStatus::Failed);
        assert!(run.reason.unwrap().contains("restarted"));
        assert!(effects.delivered.lock().unwrap().is_empty());
    });
}

#[test]
fn instructions_on_a_preset_that_is_not_an_agent_fail_the_run_before_launch() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let script = Schedule {
            preset_id: "ok".into(),
            ..agent_schedule()
        };
        let tasks = [script];
        scheduler.request_run_now("sch_1", &tasks).unwrap();
        sweep(scheduler, &tasks, &now(9, 0, 0));
        settle(effects, 0);
        assert!(effects.spawned.lock().unwrap().is_empty());
        let run = latest(scheduler);
        assert_eq!(run.status, RunStatus::Failed);
        assert!(run.reason.unwrap().contains("not an Agent Preset"));
    });
}
