use super::*;
use crate::schedules::agent_run::AgentStatus;
use jiff::civil::date;
use jiff::tz::{self, TimeZone};
use std::sync::Mutex;
use unpeel_core::schedules::{RunPhase, RunReport, ScheduleTrigger};

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
    /// When set, each delivery waits for a message here before it returns.
    held_delivery: Option<Mutex<mpsc::Receiver<()>>>,
    /// What the agent's screen shows as its reply.
    screen: Option<String>,
    /// Each Run Session's last report (#81).
    reports: Mutex<HashMap<String, RunReport>>,
    /// Tasks whose definition has left the saved Scheduled Tasks.
    deleted: Mutex<HashSet<String>>,
    /// A delete that lands mid-sweep: the definition leaves once this many
    /// checks have seen it.
    delete_after_checks: Option<usize>,
    checks: Mutex<usize>,
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
        if let Some(held) = &self.held_delivery {
            let _ = held.lock().unwrap().recv();
        }
        let at_ms = clock::epoch_ms(&now(9, 0, 1));
        self.delivery.clone().unwrap_or(match instructions {
            Some(_) => Delivery::Typed { at_ms },
            None => Delivery::Ready { at_ms },
        })
    }

    fn screen_reply(&self, _session_id: &str, _instructions: &str) -> Option<String> {
        self.screen.clone()
    }

    fn run_report(&self, session_id: &str) -> Option<RunReport> {
        self.reports.lock().unwrap().get(session_id).cloned()
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

    fn is_defined(&self, schedule_id: &str) -> Result<bool, String> {
        let mut checks = self.checks.lock().unwrap();
        let mut deleted = self.deleted.lock().unwrap();
        if self.delete_after_checks == Some(*checks) {
            deleted.insert(schedule_id.to_string());
        }
        *checks += 1;
        Ok(!deleted.contains(schedule_id))
    }
}

/// Delete a task as `write.rs` `delete` and `unpeel schedules rm` do: its
/// definition leaves app-state.json, then its store goes.
fn delete(scheduler: &Scheduler, effects: &Recording, schedule_id: &str) {
    effects
        .deleted
        .lock()
        .unwrap()
        .insert(schedule_id.to_string());
    TaskStore::open(root_of(scheduler), schedule_id)
        .unwrap()
        .remove()
        .unwrap();
}

/// What a task's directory holds, if it exists.
fn entries(dir: &std::path::Path) -> Vec<std::ffi::OsString> {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
                .collect()
        })
        .unwrap_or_default()
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

fn with_scheduler<T>(effects: Recording, body: impl FnOnce(&mut Scheduler, &Recording) -> T) -> T {
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
    let catalog = RunCatalog {
        projects: &projects,
        presets: &presets,
        known_presets: &[],
    };
    scheduler.sweep(schedules, &catalog, activity, Some(4321), at)
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

/// Run now refused because a Run of the task is in progress.
fn in_progress(refused: &Result<String, RunNowRefusal>) -> bool {
    matches!(refused, Err(RunNowRefusal::InProgress(message)) if message.contains("in progress"))
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
            in_progress(&scheduler.request_run_now("sch_1", &tasks)),
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
        let refused = scheduler.request_run_now("sch_1", &tasks);
        assert!(in_progress(&refused), "{refused:?}");
        assert!(matches!(
            scheduler.request_run_now("sch_missing", &tasks),
            Err(RunNowRefusal::UnknownTask(_))
        ));
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
        let refused = scheduler.request_run_now("sch_1", &tasks);
        assert!(
            matches!(&refused, Err(RunNowRefusal::RunLogUnreadable(message))
                if message.contains("runs.jsonl")),
            "{refused:?}"
        );
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
        let refused = scheduler.request_run_now("sch_1", &tasks);
        assert!(in_progress(&refused), "{refused:?}");

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

/// A next run that moved (a new task, an edited Trigger) is told to
/// Controllers once the clock holds it, and an unchanged clock tells
/// nothing: the worker pings the state bus on this event.
#[test]
fn a_saved_clock_is_published_once() {
    with_scheduler(Recording::default(), |scheduler, _| {
        let published = |events: &[SweepEvent]| {
            events
                .iter()
                .filter(|event| matches!(event, SweepEvent::Published { schedule_id } if schedule_id == "sch_1"))
                .count()
        };
        let mut task = schedule(ScheduleTrigger::Daily {
            time: "09:30".into(),
        });
        assert_eq!(
            published(&sweep(scheduler, &[task.clone()], &now(9, 0, 0))),
            1
        );
        assert_eq!(
            published(&sweep(scheduler, &[task.clone()], &now(9, 0, 1))),
            0
        );
        task.trigger = ScheduleTrigger::Daily {
            time: "17:00".into(),
        };
        task.clock_reset_at_ms = Some(clock::epoch_ms(&now(9, 0, 2)));
        assert_eq!(
            published(&sweep(scheduler, &[task.clone()], &now(9, 0, 2))),
            1
        );
        let clock = TaskStore::open(root_of(scheduler), "sch_1")
            .unwrap()
            .clock()
            .unwrap();
        assert_eq!(clock.next_occurrence.as_deref(), Some("2026-11-06T17:00"));
        // What a write route answers before this sweep is what it published.
        let zone = now(9, 0, 2).time_zone().clone();
        let before_the_sweep = ScheduleClock {
            next_occurrence: Some("2026-11-06T09:30".into()),
            ..clock.clone()
        };
        assert_eq!(
            crate::schedules::trigger::published_next_run(&task, &before_the_sweep, &zone),
            clock
                .next_occurrence
                .map(|at| (at, clock.next_occurrence_ms))
        );
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

/// Sweep the agent task at `at` with its Session's row showing `status`;
/// the statuses the recorded lines say they came from.
fn follow_sweep(
    scheduler: &mut Scheduler,
    session_id: &str,
    status: AgentStatus,
    at: &Zoned,
) -> Vec<(RunStatus, Option<RunStatus>)> {
    recorded(&sweep_seeing(
        scheduler,
        &[agent_schedule()],
        &seeing(session_id, status),
        at,
    ))
}

#[test]
fn a_done_agent_run_follows_its_sessions_later_turns_and_reports() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let session_id = start_agent_run(scheduler, effects);
        for (status, second) in [(AgentStatus::Idle, 2), (AgentStatus::Working, 5)] {
            follow_sweep(scheduler, &session_id, status, &now(9, 0, second));
        }
        follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 1, 0));
        let first = latest(scheduler);
        assert_eq!(first.status, RunStatus::Done);

        // A screen-tier agent works again, then idles: only the Host's own
        // sighting of it working tells the later turn apart.
        assert_eq!(
            follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 2, 0)),
            vec![],
            "an idle agent that did not work again records nothing"
        );
        follow_sweep(scheduler, &session_id, AgentStatus::Working, &now(9, 3, 0));
        assert_eq!(
            follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 4, 0)),
            vec![(RunStatus::Done, Some(RunStatus::Done))],
            "a done line again, so no second notice"
        );
        assert_eq!(
            latest(scheduler).ended_at_ms,
            Some(clock::epoch_ms(&now(9, 4, 0)))
        );
        assert_eq!(
            follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 5, 0)),
            vec![],
            "the sighting was used up by its line"
        );

        // A blocked report lands on the Run; it stays done.
        let blocked = RunReport {
            status: "blocked".into(),
            summary: "Waiting on a signing key".into(),
            at_ms: clock::epoch_ms(&now(9, 6, 0)),
        };
        effects
            .reports
            .lock()
            .unwrap()
            .insert(session_id.clone(), blocked.clone());
        follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 6, 1));
        let reported = latest(scheduler);
        assert_eq!(
            (reported.status, reported.report),
            (RunStatus::Done, Some(blocked))
        );
        let store = TaskStore::open(root_of(scheduler), "sch_1").unwrap();
        assert_eq!(
            store.clock().unwrap().last_run_status,
            Some(RunStatus::Done)
        );

        // Its Session stops: following ends and the Run stays as it was.
        effects
            .seen
            .lock()
            .unwrap()
            .insert(session_id.clone(), (SessionSeen::Stopped, None));
        assert_eq!(
            follow_sweep(scheduler, &session_id, AgentStatus::Idle, &now(9, 7, 0)),
            vec![]
        );
        assert_eq!(latest(scheduler).status, RunStatus::Done);
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
        let refused = scheduler.request_run_now("sch_1", &tasks);
        assert!(in_progress(&refused), "{refused:?}");
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
            report: None,
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

// ── A task deleted while its Run comes up (#30) ──

/// The worker skips the sweep of a workspace with no task unless the
/// Scheduler says otherwise. Deleting the only task while its Run's Session
/// comes up must not leave that Session's outcome undrained (and the task's
/// Superseded Runs live) until some later task is created; swept with no
/// definition, the Run still says its Session is up.
#[test]
fn a_spawned_outcome_keeps_the_worker_sweeping_after_its_task_is_deleted() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        sweep(scheduler, &tasks, &now(9, 0, 0));
        settle(effects, 1);
        let session_id = effects.spawned.lock().unwrap()[0].0.session_id.clone();
        assert!(
            scheduler.needs_sweep(&[]),
            "the worker skips the sweep, so the Session's Spawned outcome waits undrained"
        );
        let next = sweep(scheduler, &[], &now(9, 0, 1));
        assert_eq!(spawned(&next), vec![session_id]);
        assert!(!scheduler.needs_sweep(&[]), "nothing left to drain");
    });
}

/// An agent Run's delivery outcome is drained the same way: a task deleted
/// while its agent's instructions are typed leaves nothing held for a later
/// sweep.
#[test]
fn an_agent_runs_delivery_keeps_the_worker_sweeping_after_its_task_is_deleted() {
    let (release, held) = mpsc::channel();
    let effects = Recording {
        held_delivery: Some(Mutex::new(held)),
        ..Recording::default()
    };
    with_scheduler(effects, |scheduler, effects| {
        let session_id = start_agent_run(scheduler, effects);
        let up = sweep(scheduler, &[], &now(9, 0, 1));
        assert_eq!(spawned(&up), vec![session_id]);
        assert!(
            scheduler.needs_sweep(&[]),
            "its instructions are still being typed"
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while scheduler.needs_sweep(&[]) && Instant::now() < deadline {
            sweep(scheduler, &[], &now(9, 0, 2));
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            !scheduler.needs_sweep(&[]),
            "its delivery outcome was drained"
        );
    });
}

/// With no task and nothing starting, the worker still skips the sweep.
#[test]
fn a_workspace_with_no_task_and_no_run_starting_is_not_swept() {
    with_scheduler(Recording::default(), |scheduler, _| {
        assert!(!scheduler.needs_sweep(&[]));
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        assert!(scheduler.needs_sweep(&tasks));
    });
}

/// #29: the worker read the task's definition (`driver.rs`
/// `load_schedules_and_presets`) just before the task was deleted, so this
/// sweep still steps it. Deleting removed its directory; the sweep must not
/// make it again.
#[test]
fn a_sweep_does_not_recreate_a_task_deleted_after_its_definition_was_read() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        let dir = root_of(scheduler).join("sch_1");
        sweep(scheduler, &tasks, &now(8, 0, 0));
        assert!(dir.join("clock.json").is_file(), "the first sweep saved it");

        delete(scheduler, effects, "sch_1");
        assert!(!dir.exists());

        let events = sweep(scheduler, &tasks, &now(8, 0, 1));
        assert!(!dir.exists(), "recreated: {:?} {events:?}", entries(&dir));
    });
}

/// #29, at its task's due second: a task deleted after its definition was
/// read must not fire, and its drop is quiet (no warning, no failed Run).
#[test]
fn a_task_deleted_at_its_due_time_starts_no_run() {
    with_scheduler(Recording::default(), |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        sweep(scheduler, &tasks, &now(8, 0, 0));
        delete(scheduler, effects, "sch_1");

        let events = sweep(scheduler, &tasks, &now(9, 0, 0));
        assert_eq!(
            events,
            vec![SweepEvent::Deleted {
                schedule_id: "sch_1".into()
            }]
        );
        assert!(effects.spawned.lock().unwrap().is_empty());
        let dir = root_of(scheduler).join("sch_1");
        assert!(!dir.exists(), "recreated: {:?}", entries(&dir));
    });
}

/// #29: the delete removes the definition after the sweep's clock save saw
/// it but before the Run's start; the store goes only after that. The Run
/// line is the start's own write, so it checks again: no Run of a task
/// already deleted.
#[test]
fn a_task_deleted_between_its_clock_save_and_its_start_starts_no_run() {
    let effects = Recording {
        delete_after_checks: Some(1),
        ..Recording::default()
    };
    with_scheduler(effects, |scheduler, effects| {
        let tasks = [schedule(ScheduleTrigger::Daily {
            time: "09:00".into(),
        })];
        let events = sweep(scheduler, &tasks, &now(9, 0, 0));
        let runs = TaskStore::open(root_of(scheduler), "sch_1")
            .unwrap()
            .runs()
            .unwrap();
        assert!(runs.is_empty(), "a deleted task's Run: {runs:?} {events:?}");
        assert_eq!(
            events,
            vec![
                SweepEvent::Published {
                    schedule_id: "sch_1".into()
                },
                SweepEvent::Deleted {
                    schedule_id: "sch_1".into()
                },
            ]
        );
        assert!(effects.spawned.lock().unwrap().is_empty());
    });
}
