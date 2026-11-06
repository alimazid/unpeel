//! Agent Runs through the scheduler's step, from fake activity signals.

use super::*;
use crate::schedules::clock;
use crate::schedules::step::{step, Action, LaunchPlan, RunKind, TaskState};
use jiff::civil::date;
use jiff::tz::{self, TimeZone};
use jiff::Zoned;
use unpeel_core::schedules::{Schedule, ScheduleClock, ScheduleTrigger};

const INSTRUCTIONS: &str = "run the morning briefing";

fn now(minute: i8, second: i8) -> Zoned {
    date(2026, 11, 6)
        .at(9, minute, second, 0)
        .to_zoned(TimeZone::fixed(tz::offset(-5)))
        .unwrap()
}

fn ms(minute: i8, second: i8) -> u64 {
    clock::epoch_ms(&now(minute, second))
}

/// The instructions were typed at 09:01:00.
fn prompted_at() -> u64 {
    ms(1, 0)
}

fn agent_task() -> TaskState {
    TaskState {
        schedule: Schedule {
            id: "sch_agent".into(),
            name: "Briefing".into(),
            project_id: "p".into(),
            preset_id: "claude".into(),
            instructions: Some(INSTRUCTIONS.into()),
            // Never due in these tests: they follow one Run.
            trigger: ScheduleTrigger::Daily {
                time: "23:00".into(),
            },
            enabled: true,
            notify_when_done: true,
            created_at_ms: ms(0, 0),
            clock_reset_at_ms: None,
        },
        clock: ScheduleClock::default(),
        latest_run: None,
        observation: RunObservation::Idle,
        run_now: None,
        launch: Ok(LaunchPlan {
            project_id: "p".into(),
            preset_id: "claude".into(),
            command: "claude".into(),
            cwd: "/tmp".into(),
            worktree_path: None,
            worktree_branch: None,
            kind: RunKind::Agent {
                instructions: Some(INSTRUCTIONS.into()),
            },
        }),
    }
}

/// A task on an Agent Preset with no instructions.
fn bare_agent_task() -> TaskState {
    let mut task = agent_task();
    task.schedule.instructions = None;
    if let Ok(plan) = &mut task.launch {
        plan.kind = RunKind::Agent { instructions: None };
    }
    task
}

fn run_in(phase: RunPhase, status: RunStatus) -> ScheduleRun {
    let prompted = matches!(phase, RunPhase::Prompted | RunPhase::Working);
    ScheduleRun {
        run_id: "run_agent".into(),
        scheduled_for: None,
        started_at_ms: Some(ms(0, 0)),
        ended_at_ms: None,
        status,
        late: false,
        session_id: Some("session-agent".into()),
        exit_code: None,
        reason: None,
        snippet: None,
        phase: Some(phase),
        prompted_at_ms: prompted.then(prompted_at),
    }
}

fn observing(run: ScheduleRun, observation: RunObservation) -> TaskState {
    TaskState {
        latest_run: Some(run),
        observation,
        ..agent_task()
    }
}

fn agent(delivery: Option<Delivery>, activity: AgentActivity) -> RunObservation {
    RunObservation::Agent(AgentObservation {
        delivery,
        activity,
        working_timeout_ms: WORKING_TIMEOUT_MS,
    })
}

fn status(status: AgentStatus) -> AgentActivity {
    AgentActivity {
        status,
        ..AgentActivity::default()
    }
}

/// The Run line one step at `at` records, if any.
fn next_line(task: TaskState, at: &Zoned) -> Option<ScheduleRun> {
    let actions = step(&[task], at, &mut || "run_new".to_string());
    let mut lines = actions.into_iter().filter_map(|action| match action {
        Action::Record { run, .. } => Some(run),
        _ => None,
    });
    let line = lines.next();
    assert!(lines.next().is_none(), "one line per step");
    line
}

fn follow(
    phase: RunPhase,
    run_status: RunStatus,
    activity: AgentActivity,
    at: &Zoned,
) -> Option<ScheduleRun> {
    next_line(
        observing(run_in(phase, run_status), agent(None, activity)),
        at,
    )
}

#[test]
fn an_agent_run_starts_launching_then_waits_for_the_agent() {
    let mut asked = agent_task();
    asked.run_now = Some("run_asked".into());
    let actions = step(&[asked], &now(0, 0), &mut || "unused".into());
    let started = actions
        .iter()
        .find_map(|action| match action {
            Action::Start { run, plan, .. } => Some((run, plan)),
            _ => None,
        })
        .expect("the Run starts");
    assert_eq!(started.0.status, RunStatus::Running);
    assert_eq!(started.0.phase, Some(RunPhase::Launching));
    assert_eq!(started.1.kind.instructions(), Some(INSTRUCTIONS));

    let up = observing(
        run_in(RunPhase::Launching, RunStatus::Running),
        agent(Some(Delivery::Waiting), AgentActivity::default()),
    );
    let waiting = next_line(up, &now(0, 2)).expect("a phase line");
    assert_eq!(
        (waiting.status, waiting.phase),
        (RunStatus::Running, Some(RunPhase::WaitingReady))
    );
    let still = observing(
        run_in(RunPhase::WaitingReady, RunStatus::Running),
        agent(Some(Delivery::Waiting), AgentActivity::default()),
    );
    assert_eq!(next_line(still, &now(0, 3)), None, "no line until news");
}

#[test]
fn typed_instructions_prompt_the_agent() {
    let typed = observing(
        run_in(RunPhase::WaitingReady, RunStatus::Running),
        agent(
            Some(Delivery::Typed {
                at_ms: prompted_at(),
            }),
            status(AgentStatus::Idle),
        ),
    );
    let line = next_line(typed, &now(1, 1)).expect("prompted");
    assert_eq!(line.status, RunStatus::Running);
    assert_eq!(line.phase, Some(RunPhase::Prompted));
    assert_eq!(line.prompted_at_ms, Some(prompted_at()));
}

#[test]
fn the_first_working_signal_is_working_and_the_first_idle_after_it_is_done() {
    let working = follow(
        RunPhase::Prompted,
        RunStatus::Running,
        status(AgentStatus::Working),
        &now(1, 2),
    )
    .expect("working");
    assert_eq!(
        (working.status, working.phase),
        (RunStatus::Running, Some(RunPhase::Working))
    );
    assert_eq!(
        follow(
            RunPhase::Working,
            RunStatus::Running,
            status(AgentStatus::Working),
            &now(2, 0)
        ),
        None
    );

    let finished = AgentActivity {
        status: AgentStatus::Idle,
        hook_reply: Some(("Morning briefing ready: 3 meetings.".into(), ms(2, 30))),
        ..AgentActivity::default()
    };
    let done = follow(RunPhase::Working, RunStatus::Running, finished, &now(2, 31)).expect("done");
    assert_eq!(done.status, RunStatus::Done);
    assert_eq!(done.ended_at_ms, Some(ms(2, 31)));
    assert_eq!(
        done.snippet.as_deref(),
        Some("Morning briefing ready: 3 meetings.")
    );
    assert_eq!((done.exit_code, done.reason), (None, None));
}

#[test]
fn the_default_idle_never_moves_a_run() {
    // Silent: no tier has spoken. A stale idle (the readiness signal itself,
    // still showing right after the paste) is no working signal either.
    for (phase, activity) in [
        (RunPhase::Prompted, status(AgentStatus::Silent)),
        (RunPhase::Prompted, status(AgentStatus::Idle)),
        (RunPhase::Working, status(AgentStatus::Silent)),
    ] {
        assert_eq!(
            follow(phase, RunStatus::Running, activity.clone(), &now(1, 30)),
            None,
            "{phase:?} {activity:?}"
        );
    }
    // Evidence from before the paste is not this Run's turn.
    let stale = AgentActivity {
        status: AgentStatus::Idle,
        working_at_ms: Some(ms(0, 50)),
        finished_at_ms: Some(ms(0, 55)),
        ..AgentActivity::default()
    };
    assert_eq!(
        follow(RunPhase::Prompted, RunStatus::Running, stale, &now(1, 30)),
        None
    );
}

#[test]
fn a_turn_finished_between_two_scans_is_done_from_the_programs_record() {
    let fast = AgentActivity {
        status: AgentStatus::Idle,
        working_at_ms: Some(ms(1, 0) + 200),
        finished_at_ms: Some(ms(1, 0) + 700),
        program_reply: Some(("Briefing sent".into(), ms(1, 0) + 700)),
        hook_reply: Some(("an older reply".into(), ms(0, 30))),
    };
    let done = follow(RunPhase::Prompted, RunStatus::Running, fast, &now(1, 1)).expect("done");
    assert_eq!(done.status, RunStatus::Done);
    assert_eq!(done.snippet.as_deref(), Some("Briefing sent"));
}

#[test]
fn a_reply_from_before_the_paste_is_not_the_snippet() {
    let finished = AgentActivity {
        status: AgentStatus::Idle,
        hook_reply: Some(("the readiness turn's reply".into(), ms(0, 59))),
        ..AgentActivity::default()
    };
    let done = follow(RunPhase::Working, RunStatus::Running, finished, &now(3, 0)).expect("done");
    assert_eq!((done.status, done.snippet), (RunStatus::Done, None));
}

#[test]
fn no_readiness_signal_within_the_budget_fails_to_start_and_keeps_the_session() {
    let never = observing(
        run_in(RunPhase::WaitingReady, RunStatus::Running),
        agent(Some(Delivery::NotReady), AgentActivity::default()),
    );
    let line = next_line(never, &now(2, 0)).expect("a final line");
    assert_eq!(line.status, RunStatus::FailedToStart);
    assert_eq!(line.ended_at_ms, Some(ms(2, 0)));
    let reason = line.reason.unwrap_or_default();
    assert!(
        reason.contains("ready") && reason.contains("left open"),
        "{reason}"
    );
    assert_eq!(line.session_id.as_deref(), Some("session-agent"));
}

#[test]
fn a_launch_that_ends_or_cannot_type_fails_with_the_reason() {
    for (delivery, expected) in [
        (Delivery::SessionEnded, "ended"),
        (
            Delivery::Failed("session host rejected initial text".into()),
            "rejected",
        ),
        (Delivery::Interrupted, "restarted"),
    ] {
        let launch = observing(
            run_in(RunPhase::WaitingReady, RunStatus::Running),
            agent(Some(delivery.clone()), AgentActivity::default()),
        );
        let line = next_line(launch, &now(0, 30)).expect("a final line");
        assert_eq!(line.status, RunStatus::Failed, "{delivery:?}");
        assert!(
            line.reason.unwrap_or_default().contains(expected),
            "{delivery:?}"
        );
    }
}

#[test]
fn no_working_signal_within_60_seconds_of_the_paste_needs_you() {
    let quiet = || status(AgentStatus::Idle);
    assert_eq!(
        follow(RunPhase::Prompted, RunStatus::Running, quiet(), &now(2, 0)),
        None,
        "60 s is still within the window"
    );
    let stuck =
        follow(RunPhase::Prompted, RunStatus::Running, quiet(), &now(2, 1)).expect("needs you");
    assert_eq!(stuck.status, RunStatus::NeedsYou);
    assert_eq!(stuck.phase, Some(RunPhase::Prompted));
    assert_eq!(stuck.ended_at_ms, None, "needs you is still in progress");
    assert!(stuck.reason.unwrap_or_default().contains("60 s"));

    // It only waits on a person now: no second timeout.
    assert_eq!(
        follow(
            RunPhase::Prompted,
            RunStatus::NeedsYou,
            quiet(),
            &now(59, 0)
        ),
        None
    );
    // The agent was only slow: its first working signal, then idle, is done.
    let late_start = follow(
        RunPhase::Prompted,
        RunStatus::NeedsYou,
        status(AgentStatus::Working),
        &now(5, 0),
    )
    .expect("working");
    assert_eq!(
        (late_start.status, late_start.phase),
        (RunStatus::NeedsYou, Some(RunPhase::Working))
    );
    let done = follow(RunPhase::Working, RunStatus::NeedsYou, quiet(), &now(6, 0)).expect("done");
    assert_eq!((done.status, done.reason), (RunStatus::Done, None));
}

#[test]
fn an_attention_edge_while_working_needs_you_with_no_timeout_then_done() {
    let asked = follow(
        RunPhase::Working,
        RunStatus::Running,
        status(AgentStatus::Attention),
        &now(2, 0),
    )
    .expect("needs you");
    assert_eq!(asked.status, RunStatus::NeedsYou);
    assert_eq!(asked.ended_at_ms, None);
    assert!(asked.reason.unwrap_or_default().contains("answer"));

    // Still asking an hour later: nothing times out, nothing is killed.
    assert_eq!(
        follow(
            RunPhase::Working,
            RunStatus::NeedsYou,
            status(AgentStatus::Attention),
            &now(59, 59)
        ),
        None
    );
    assert_eq!(
        follow(
            RunPhase::Working,
            RunStatus::NeedsYou,
            status(AgentStatus::Working),
            &now(59, 59)
        ),
        None,
        "answered and working again: still in progress"
    );
    let done = follow(
        RunPhase::Working,
        RunStatus::NeedsYou,
        status(AgentStatus::Idle),
        &now(59, 59),
    )
    .expect("a later done edge");
    assert_eq!(done.status, RunStatus::Done);
}

#[test]
fn a_question_right_after_the_paste_needs_you() {
    let asked = follow(
        RunPhase::Prompted,
        RunStatus::Running,
        status(AgentStatus::Attention),
        &now(1, 5),
    )
    .expect("needs you");
    assert_eq!(
        (asked.status, asked.phase),
        (RunStatus::NeedsYou, Some(RunPhase::Working))
    );
}

#[test]
fn the_agent_exiting_before_done_fails_with_its_exit_code() {
    for (phase, run_status) in [
        (RunPhase::Launching, RunStatus::Running),
        (RunPhase::WaitingReady, RunStatus::Running),
        (RunPhase::Prompted, RunStatus::Running),
        (RunPhase::Working, RunStatus::Running),
        (RunPhase::Working, RunStatus::NeedsYou),
    ] {
        for code in [0, 2] {
            let exited = observing(run_in(phase, run_status), RunObservation::Exited(code));
            let line = next_line(exited, &now(3, 0)).expect("a final line");
            assert_eq!(line.status, RunStatus::Failed, "{phase:?} {code}");
            assert_eq!(line.exit_code, Some(code), "{phase:?}");
            assert_eq!(line.ended_at_ms, Some(ms(3, 0)));
            assert!(line.reason.unwrap_or_default().contains("exited"));
        }
    }
    let gone = observing(
        run_in(RunPhase::Working, RunStatus::Running),
        RunObservation::Missing,
    );
    let line = next_line(gone, &now(3, 0)).expect("a final line");
    assert_eq!((line.status, line.exit_code), (RunStatus::Failed, None));
}

#[test]
fn a_run_that_needs_you_skips_the_next_occurrence() {
    let mut blocked = observing(
        run_in(RunPhase::Working, RunStatus::NeedsYou),
        agent(None, status(AgentStatus::Attention)),
    );
    blocked.schedule.trigger = ScheduleTrigger::Daily {
        time: "09:30".into(),
    };
    blocked.clock.last_occurrence = Some("2026-11-05T09:30".into());
    let actions = step(&[blocked], &now(30, 0), &mut || "run_due".to_string());
    assert!(!actions
        .iter()
        .any(|action| matches!(action, Action::Start { .. })));
    let skipped: Vec<_> = actions
        .iter()
        .filter_map(|action| match action {
            Action::Record { run, .. } => Some(run),
            _ => None,
        })
        .collect();
    assert_eq!(skipped.len(), 1);
    assert_eq!(skipped[0].status, RunStatus::Skipped);
    assert_eq!(skipped[0].run_id, "run_due");
}

#[test]
fn an_agent_preset_task_without_instructions_is_done_once_its_agent_is_ready() {
    let mut asked = bare_agent_task();
    asked.run_now = Some("run_bare".into());
    let actions = step(&[asked], &now(0, 0), &mut || "unused".into());
    let started = actions
        .iter()
        .find_map(|action| match action {
            Action::Start { run, .. } => Some(run),
            _ => None,
        })
        .expect("the Run starts");
    assert_eq!(
        started.phase,
        Some(RunPhase::Launching),
        "it waits for its agent"
    );

    let ready = TaskState {
        latest_run: Some(run_in(RunPhase::WaitingReady, RunStatus::Running)),
        observation: agent(
            Some(Delivery::Ready { at_ms: ms(0, 4) }),
            status(AgentStatus::Idle),
        ),
        ..bare_agent_task()
    };
    let done = next_line(ready, &now(0, 5)).expect("a final line");
    assert_eq!(done.status, RunStatus::Done);
    assert_eq!(done.ended_at_ms, Some(ms(0, 5)));
    assert_eq!(
        (done.snippet, done.reason, done.prompted_at_ms),
        (None, None, None),
        "nothing was typed"
    );

    let never = TaskState {
        latest_run: Some(run_in(RunPhase::WaitingReady, RunStatus::Running)),
        observation: agent(Some(Delivery::NotReady), AgentActivity::default()),
        ..bare_agent_task()
    };
    assert_eq!(
        next_line(never, &now(2, 0)).map(|line| line.status),
        Some(RunStatus::FailedToStart)
    );
}

#[test]
fn a_closed_agent_session_fails_with_a_reason_about_the_agent() {
    for phase in [RunPhase::WaitingReady, RunPhase::Working] {
        let closed = observing(run_in(phase, RunStatus::Running), RunObservation::Ended);
        let line = next_line(closed, &now(3, 0)).expect("a final line");
        assert_eq!(line.status, RunStatus::Failed);
        let reason = line.reason.unwrap_or_default();
        assert!(
            reason.contains("closed") && reason.contains("agent"),
            "{reason}"
        );
        assert!(!reason.contains("exit status"), "{reason}");
    }
}

#[test]
fn only_a_test_host_may_shorten_the_working_window() {
    assert_eq!(working_timeout_from(None, None), WORKING_TIMEOUT_MS);
    assert_eq!(working_timeout_from(None, Some("2000")), WORKING_TIMEOUT_MS);
    assert_eq!(
        working_timeout_from(Some("0"), Some("2000")),
        WORKING_TIMEOUT_MS
    );
    assert_eq!(working_timeout_from(Some("1"), Some(" 2000 ")), 2_000);
    assert_eq!(
        working_timeout_from(Some("1"), Some("soon")),
        WORKING_TIMEOUT_MS
    );
}

// ── The worker's rows as an agent Run sees them ──

fn row(
    status: crate::sessions::Status,
    source: crate::sessions::StatusSource,
) -> crate::sessions::SessionRow {
    crate::sessions::SessionRow {
        id: "session-agent".into(),
        host_started_at: None,
        project_id: "p".into(),
        label: "claude".into(),
        command: "claude".into(),
        active_runtime_id: Some("claude".into()),
        active_app: None,
        resume_available: false,
        resumable: false,
        resume_agent_available: false,
        running: true,
        status,
        status_source: source,
        program_status: None,
        created_at: 1_000,
        pinned: false,
        unread: false,
        latest_alert_body: None,
        cwd: "/tmp".into(),
        activity_at: 1_000,
        group_id: "p".into(),
        detected_local_urls: Vec::new(),
        spawned_by: Some("schedule:sch_agent".into()),
    }
}

#[test]
fn a_rows_status_counts_only_when_a_tier_reported_it() {
    use crate::sessions::{Status, StatusSource};
    let seen = |status, source| AgentActivity::from_row(&row(status, source), None, None).status;
    assert_eq!(
        seen(Status::Busy, StatusSource::Screen),
        AgentStatus::Working
    );
    assert_eq!(seen(Status::Idle, StatusSource::Hooks), AgentStatus::Idle);
    assert_eq!(seen(Status::Idle, StatusSource::Program), AgentStatus::Idle);
    // The default idle: no tier has spoken.
    assert_eq!(seen(Status::Idle, StatusSource::None), AgentStatus::Silent);
    assert_eq!(
        seen(Status::Starting, StatusSource::None),
        AgentStatus::Silent
    );
    // A select menu on screen is a question whichever tier the row has.
    assert_eq!(
        seen(Status::Attention, StatusSource::None),
        AgentStatus::Attention
    );
    assert_eq!(
        seen(Status::Attention, StatusSource::Hooks),
        AgentStatus::Attention
    );
    let mut stopped = row(Status::Exited, StatusSource::None);
    stopped.running = false;
    assert_eq!(
        AgentActivity::from_row(&stopped, None, None).status,
        AgentStatus::Silent
    );
}

#[test]
fn a_rows_program_record_and_hook_reply_carry_the_turns_evidence() {
    use crate::sessions::{Status, StatusSource};
    let mut done = row(Status::Idle, StatusSource::Program);
    done.program_status = Some(
        serde_json::from_value(serde_json::json!({
            "state": "done", "msg": "Briefing sent", "changed_at": 900,
            "last_non_idle_at": 900, "last_finished_at": 900, "finished_edges": 1
        }))
        .unwrap(),
    );
    let activity = AgentActivity::from_row(&done, Some(950), Some(("the reply", 940)));
    assert_eq!(activity.working_at_ms, Some(900));
    assert_eq!(
        activity.finished_at_ms,
        Some(950),
        "the newest completion evidence"
    );
    assert_eq!(activity.program_reply, Some(("Briefing sent".into(), 900)));
    assert_eq!(activity.hook_reply, Some(("the reply".into(), 940)));

    // An idle report's text is not a done summary.
    let mut idle = done.clone();
    idle.program_status = Some(
        serde_json::from_value(serde_json::json!({
            "state": "idle", "msg": "Ready", "changed_at": 990, "last_non_idle_at": 900,
            "last_finished_at": 900
        }))
        .unwrap(),
    );
    let activity = AgentActivity::from_row(&idle, None, None);
    assert_eq!(activity.program_reply, None);
    assert_eq!(activity.finished_at_ms, Some(900));
}
