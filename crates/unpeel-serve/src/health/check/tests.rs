use super::*;
use crate::health::state::KeptNotice;
use unpeel_core::schedules::{RunPhase, RunReport, ScheduleTrigger};

const MIN: u64 = 60_000;
/// A check's "now" well after every timestamp below.
const T0: u64 = 1_800_000_000_000;

fn limits() -> Limits {
    Limits::new(false, 15 * MIN)
}

fn task(id: &str) -> Schedule {
    Schedule {
        id: id.into(),
        name: "Morning report".into(),
        project_id: "p".into(),
        preset_id: "ok".into(),
        instructions: None,
        trigger: ScheduleTrigger::Daily {
            time: "09:00".into(),
        },
        enabled: true,
        notify_when_done: true,
        created_at_ms: 0,
        clock_reset_at_ms: None,
    }
}

fn run(id: &str, status: RunStatus, started: Option<u64>, ended: Option<u64>) -> ScheduleRun {
    ScheduleRun {
        run_id: id.into(),
        scheduled_for: Some("2026-11-10T09:00".into()),
        started_at_ms: started,
        ended_at_ms: ended,
        status,
        late: false,
        session_id: started.map(|_| format!("s-{id}")),
        exit_code: None,
        reason: None,
        snippet: None,
        phase: None,
        prompted_at_ms: None,
        report: None,
        session_ended: false,
    }
}

fn failed(id: &str, ended: u64, reason: &str) -> ScheduleRun {
    ScheduleRun {
        reason: Some(reason.into()),
        ..run(id, RunStatus::Failed, Some(ended - 1_000), Some(ended))
    }
}

fn skipped(id: &str, at: u64) -> ScheduleRun {
    ScheduleRun {
        reason: Some("the previous Run was still in progress".into()),
        ..run(id, RunStatus::Skipped, None, Some(at))
    }
}

fn with_runs(runs: Vec<ScheduleRun>) -> Facts {
    Facts {
        tasks: vec![TaskFacts {
            schedule: task("sch_1"),
            next_run: None,
            runs: Some(runs),
        }],
        ..Facts::default()
    }
}

fn due_at(due_ms: u64) -> Facts {
    Facts {
        tasks: vec![TaskFacts {
            schedule: task("sch_1"),
            next_run: Some(("2026-11-10T09:00".into(), due_ms)),
            runs: Some(Vec::new()),
        }],
        ..Facts::default()
    }
}

fn super_agent(running: bool, inbox: PendingStats) -> Facts {
    Facts {
        super_agent: Some(SuperAgentFacts {
            session_id: "router-1".into(),
            running,
            inbox,
            hold: Some("busy".into()),
        }),
        ..Facts::default()
    }
}

/// The state a check at `at` leaves with nothing wrong.
fn checked_at(at: u64) -> HealthState {
    check(&Facts::default(), &HealthState::default(), &limits(), at).0
}

/// Checks `facts` at each time in turn, from `state`; every alert raised,
/// with the check's time.
fn checks(facts: &Facts, state: HealthState, times: &[u64]) -> (HealthState, Vec<(u64, Alert)>) {
    times
        .iter()
        .fold((state, Vec::new()), |(state, mut raised), &now| {
            let (state, alerts) = check(facts, &state, &limits(), now);
            raised.extend(alerts.into_iter().map(|alert| (now, alert)));
            (state, raised)
        })
}

// Check 1: failed and skipped Runs.

#[test]
fn a_run_failed_since_the_last_check_alerts_once() {
    let facts = with_runs(vec![failed(
        "run_1",
        T0 + 60_000,
        "the command exited with status 3",
    )]);
    let (_, raised) = checks(&facts, checked_at(T0), &[T0 + 5 * MIN, T0 + 10 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let alert = &raised[0].1;
    assert_eq!(alert.check, Check::RunFailed);
    assert_eq!(alert.schedule_id.as_deref(), Some("sch_1"));
    assert_eq!(alert.session_id.as_deref(), Some("s-run_1"));
    assert_eq!(alert.title, "Morning report");
    assert_eq!(
        alert.text,
        "Health check: Run run_1 of Scheduled Task \"Morning report\" (id:sch_1) failed: the \
         command exited with status 3. Its Session is id:s-run_1. It alerts again only after a \
         Run of the task is done."
    );
    // The Run's own notice already reached the Mac.
    assert!(alert.check.to_super_agent() && !alert.check.to_mac());
}

#[test]
fn a_failure_recorded_before_the_last_check_is_history() {
    let facts = with_runs(vec![failed("run_1", T0 - MIN, "exit 3")]);
    let (_, raised) = checks(&facts, checked_at(T0), &[T0 + 5 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    // A first check ever counts nothing before it as news either.
    let (_, raised) = checks(&facts, HealthState::default(), &[T0, T0 + 5 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
}

#[test]
fn a_tasks_failures_alert_again_only_after_a_run_of_it_is_done() {
    let first = failed("run_1", T0 + MIN, "exit 3");
    let state = checked_at(T0);
    let (state, raised) = checks(&with_runs(vec![first.clone()]), state, &[T0 + 5 * MIN]);
    assert_eq!(raised.len(), 1);
    // It fails again, and a Run in progress in between does not end the
    // episode.
    let again = with_runs(vec![
        first.clone(),
        failed("run_2", T0 + 6 * MIN, "exit 3"),
        run("run_3", RunStatus::Running, Some(T0 + 7 * MIN), None),
    ]);
    let (state, raised) = checks(&again, state, &[T0 + 10 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    // A done Run clears it; the next failure alerts again.
    let done = ScheduleRun {
        exit_code: Some(0),
        ..run(
            "run_3",
            RunStatus::Done,
            Some(T0 + 7 * MIN),
            Some(T0 + 11 * MIN),
        )
    };
    let (state, raised) = checks(
        &with_runs(vec![first.clone(), done.clone()]),
        state,
        &[T0 + 15 * MIN],
    );
    assert!(raised.is_empty());
    let (_, raised) = checks(
        &with_runs(vec![first, done, failed("run_4", T0 + 16 * MIN, "exit 4")]),
        state,
        &[T0 + 20 * MIN],
    );
    assert_eq!(raised.len(), 1, "{raised:?}");
    assert!(raised[0].1.text.contains("run_4"), "{}", raised[0].1.text);
}

#[test]
fn a_run_that_failed_to_start_counts_as_failed() {
    let run = ScheduleRun {
        status: RunStatus::FailedToStart,
        phase: Some(RunPhase::WaitingReady),
        ..failed("run_1", T0 + MIN, "the agent showed no sign of being ready")
    };
    let (_, raised) = checks(&with_runs(vec![run]), checked_at(T0), &[T0 + 5 * MIN]);
    assert_eq!(raised.len(), 1);
    assert!(
        raised[0]
            .1
            .text
            .contains("failed to start: the agent showed no sign"),
        "{}",
        raised[0].1.text
    );
}

#[test]
fn a_skipped_run_alerts_once_naming_the_run_in_its_way() {
    let blocker = ScheduleRun {
        status: RunStatus::NeedsYou,
        ..run("run_1", RunStatus::NeedsYou, Some(T0 - 50 * MIN), None)
    };
    let facts = with_runs(vec![
        blocker.clone(),
        ScheduleRun {
            scheduled_for: Some("2026-11-10T10:00".into()),
            ..skipped("run_2", T0 + MIN)
        },
    ]);
    let (state, raised) = checks(&facts, checked_at(T0), &[T0 + 5 * MIN, T0 + 10 * MIN]);
    let skips: Vec<_> = raised
        .iter()
        .filter(|(_, alert)| alert.check == Check::RunSkipped)
        .collect();
    assert_eq!(skips.len(), 1, "{raised:?}");
    let alert = &skips[0].1;
    assert_eq!(alert.session_id.as_deref(), Some("s-run_1"));
    assert_eq!(
        alert.text,
        "Health check: Scheduled Task \"Morning report\" (id:sch_1) skipped its \
         2026-11-10T10:00 occurrence: the previous Run was still in progress. Run run_1 is \
         still in progress (needs_you) in Session id:s-run_1. It alerts again only after a Run \
         of the task starts."
    );
    assert!(alert.check.to_super_agent() && alert.check.to_mac());
    // Later skips behind the same Run stay one alert.
    let more = with_runs(vec![
        blocker.clone(),
        skipped("run_2", T0 + MIN),
        skipped("run_3", T0 + 61 * MIN),
    ]);
    let (state, raised) = checks(&more, state, &[T0 + 65 * MIN]);
    assert!(
        raised
            .iter()
            .all(|(_, alert)| alert.check != Check::RunSkipped),
        "{raised:?}"
    );
    // A Run that starts ends the episode; a later skip alerts again.
    let started = with_runs(vec![
        ScheduleRun {
            status: RunStatus::Done,
            ended_at_ms: Some(T0 + 66 * MIN),
            ..blocker
        },
        skipped("run_3", T0 + 61 * MIN),
        run("run_4", RunStatus::Running, Some(T0 + 121 * MIN), None),
    ]);
    let (state, raised) = checks(&started, state, &[T0 + 125 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(
        &with_runs(vec![
            run("run_4", RunStatus::Running, Some(T0 + 121 * MIN), None),
            skipped("run_5", T0 + 181 * MIN),
        ]),
        state,
        &[T0 + 185 * MIN],
    );
    assert_eq!(
        raised
            .iter()
            .filter(|(_, alert)| alert.check == Check::RunSkipped)
            .count(),
        1,
        "{raised:?}"
    );
}

#[test]
fn a_skipped_run_now_says_so() {
    let facts = with_runs(vec![
        run("run_1", RunStatus::Running, Some(T0 - MIN), None),
        ScheduleRun {
            scheduled_for: None,
            reason: Some("a Run was already in progress".into()),
            ..skipped("run_2", T0 + MIN)
        },
    ]);
    let (_, raised) = checks(&facts, checked_at(T0), &[T0 + 5 * MIN]);
    assert!(
        raised[0]
            .1
            .text
            .contains("skipped its Run now: a Run was already in progress"),
        "{}",
        raised[0].1.text
    );
}

// Check 2: a Run waiting on a prompt, or blocked.

#[test]
fn a_run_waiting_on_a_prompt_alerts_after_thirty_minutes_of_waiting() {
    let waiting = ScheduleRun {
        phase: Some(RunPhase::Working),
        reason: Some("the agent is waiting for an answer".into()),
        ..run("run_1", RunStatus::NeedsYou, Some(T0 - 60 * MIN), None)
    };
    let facts = with_runs(vec![waiting]);
    let times: Vec<u64> = (0..=7).map(|n| T0 + n * 5 * MIN).collect();
    let (_, raised) = checks(&facts, HealthState::default(), &times);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let (at, alert) = &raised[0];
    // First seen at T0: thirty minutes later, not at the first sight.
    assert_eq!(*at, T0 + 30 * MIN);
    assert_eq!(alert.check, Check::RunWaiting);
    assert_eq!(alert.session_id.as_deref(), Some("s-run_1"));
    assert_eq!(
        alert.text,
        "Health check: Run run_1 of Scheduled Task \"Morning report\" (id:sch_1) has waited on \
         a prompt for 30 min (the agent is waiting for an answer), and the task skips every \
         occurrence until it ends. Answer the prompt in its Session id:s-run_1."
    );
}

#[test]
fn a_running_run_whose_session_asks_is_waiting_too() {
    let running = run("run_1", RunStatus::Running, Some(T0 - MIN), None);
    let mut facts = with_runs(vec![running]);
    let (_, raised) = checks(&facts, HealthState::default(), &[T0, T0 + 30 * MIN]);
    assert!(raised.is_empty(), "nobody asks: {raised:?}");
    facts.asking.insert("s-run_1".into());
    let (_, raised) = checks(&facts, HealthState::default(), &[T0, T0 + 30 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
}

#[test]
fn a_run_that_stops_waiting_starts_over_when_it_waits_again() {
    let waiting = with_runs(vec![run(
        "run_1",
        RunStatus::NeedsYou,
        Some(T0 - MIN),
        None,
    )]);
    let working = with_runs(vec![run("run_1", RunStatus::Running, Some(T0 - MIN), None)]);
    let (state, _) = checks(&waiting, HealthState::default(), &[T0, T0 + 25 * MIN]);
    let (state, _) = checks(&working, state, &[T0 + 30 * MIN]);
    let (state, raised) = checks(&waiting, state, &[T0 + 35 * MIN, T0 + 60 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(&waiting, state, &[T0 + 65 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
}

#[test]
fn a_blocked_run_alerts_thirty_minutes_after_its_report() {
    let report = RunReport {
        status: "blocked".into(),
        summary: "Waiting on a signing key".into(),
        at_ms: T0 - 20 * MIN,
    };
    let blocked = ScheduleRun {
        phase: Some(RunPhase::Working),
        prompted_at_ms: Some(T0 - 59 * MIN),
        report: Some(report.clone()),
        ..run(
            "run_1",
            RunStatus::Done,
            Some(T0 - 60 * MIN),
            Some(T0 - 30 * MIN),
        )
    };
    let facts = with_runs(vec![blocked.clone()]);
    let (state, raised) = checks(&facts, HealthState::default(), &[T0, T0 + 5 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (state, raised) = checks(&facts, state, &[T0 + 10 * MIN, T0 + 15 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let (at, alert) = &raised[0];
    assert_eq!(*at, T0 + 10 * MIN);
    assert_eq!(alert.check, Check::RunBlocked);
    assert_eq!(
        alert.text,
        "Health check: Run run_1 of Scheduled Task \"Morning report\" (id:sch_1) reported \
         blocked 30 min ago and still is: \"Waiting on a signing key\". Read its blocked report \
         and unblock it in its Session id:s-run_1."
    );
    // A new blocked report is a new episode, with its own thirty minutes.
    let again = with_runs(vec![ScheduleRun {
        report: Some(RunReport {
            at_ms: T0 + 16 * MIN,
            summary: "Still no key".into(),
            ..report
        }),
        ..blocked.clone()
    }]);
    let (state, raised) = checks(&again, state, &[T0 + 20 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(&again, state, &[T0 + 46 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    // A failed Run needs no attention, whatever it reported.
    let failed = with_runs(vec![ScheduleRun {
        status: RunStatus::Failed,
        ..blocked
    }]);
    let (_, raised) = checks(&failed, HealthState::default(), &[T0 + 60 * MIN]);
    assert!(raised
        .iter()
        .all(|(_, alert)| alert.check != Check::RunBlocked));
}

// Check 3: a missed fire.

#[test]
fn a_next_run_passed_ten_minutes_ago_is_a_missed_fire() {
    let facts = due_at(T0);
    let (state, raised) = checks(&facts, HealthState::default(), &[T0, T0 + 5 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (state, raised) = checks(&facts, state, &[T0 + 10 * MIN, T0 + 15 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let alert = &raised[0].1;
    assert_eq!(alert.check, Check::MissedFire);
    assert_eq!(alert.session_id, None);
    assert_eq!(alert.schedule_id.as_deref(), Some("sch_1"));
    assert_eq!(
        alert.text,
        "Health check: Scheduled Task \"Morning report\" (id:sch_1) was due at \
         2026-11-10T09:00 (10 min ago), and no Run of it started. The Host's warnings for it \
         say why."
    );
    assert!(alert.check.to_super_agent() && alert.check.to_mac());
    // The scheduler fires it: the next run moves on, the problem clears.
    let (state, _) = checks(&due_at(T0 + 24 * 60 * MIN), state, &[T0 + 20 * MIN]);
    assert!(state.problems.is_empty(), "{:?}", state.problems);
    // A paused task (no next run) never misses one.
    let mut paused = due_at(T0);
    paused.tasks[0].next_run = None;
    let (_, raised) = checks(&paused, HealthState::default(), &[T0 + 60 * MIN]);
    assert!(raised.is_empty());
}

#[test]
fn a_run_log_that_will_not_read_still_shows_the_missed_fire() {
    let mut facts = due_at(T0);
    facts.tasks[0].runs = None;
    let (_, raised) = checks(&facts, HealthState::default(), &[T0 + 10 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
}

// Check 4: the Super Agent is down.

#[test]
fn a_super_agent_that_is_not_running_alerts_the_mac_once() {
    let down = super_agent(false, PendingStats::default());
    let (state, raised) = checks(&down, HealthState::default(), &[T0, T0 + 5 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let (at, alert) = &raised[0];
    assert_eq!(*at, T0);
    assert_eq!(alert.check, Check::SuperAgentDown);
    assert_eq!(alert.session_id.as_deref(), Some("router-1"));
    assert_eq!(alert.title, "Super Agent");
    assert_eq!(
        alert.text,
        "Health check: the Super Agent Session id:router-1 is not running. Worker reports and \
         Host alerts wait in its Inbox until it runs again."
    );
    assert!(!alert.check.to_super_agent() && alert.check.to_mac());
    // Running again clears it; down again alerts again.
    let up = super_agent(true, PendingStats::default());
    let (state, raised) = checks(&up, state, &[T0 + 10 * MIN]);
    assert!(raised.is_empty());
    let (_, raised) = checks(&down, state, &[T0 + 15 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    // No Super Agent marked: nothing to check.
    let (_, raised) = checks(&Facts::default(), HealthState::default(), &[T0]);
    assert!(raised.is_empty());
}

// Check 5: the Super Agent's Inbox.

fn pending(oldest_at: u64, oldest_wake_at: Option<u64>) -> PendingStats {
    PendingStats {
        items: 1,
        wake: oldest_wake_at.is_some(),
        oldest_at: Some(oldest_at),
        oldest_wake_at,
        newest_at: Some(oldest_at),
    }
}

#[test]
fn a_wake_item_undelivered_for_fifteen_minutes_alerts_the_mac() {
    let facts = super_agent(true, pending(T0, Some(T0)));
    // The check has watched the Super Agent run since before the item.
    let state = checks(
        &super_agent(true, PendingStats::default()),
        HealthState::default(),
        &[T0 - MIN],
    )
    .0;
    let (state, raised) = checks(&facts, state, &[T0 + 10 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(&facts, state, &[T0 + 15 * MIN, T0 + 20 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    let alert = &raised[0].1;
    assert_eq!(alert.check, Check::InboxUndelivered);
    assert_eq!(alert.session_id.as_deref(), Some("router-1"));
    assert_eq!(
        alert.text,
        "Health check: the Super Agent's Inbox (Session id:router-1) has had items due for \
         delivery for 15 min (the Host holds them: busy)."
    );
    assert!(!alert.check.to_super_agent() && alert.check.to_mac());
}

#[test]
fn ride_along_items_are_due_once_promoted() {
    let running = checks(
        &super_agent(true, PendingStats::default()),
        HealthState::default(),
        &[T0 - MIN],
    )
    .0;
    let facts = super_agent(true, pending(T0, None));
    // Promoted at 15 min, late 15 min after that.
    let (state, raised) = checks(&facts, running, &[T0 + 15 * MIN, T0 + 25 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(&facts, state, &[T0 + 30 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
    // A wake item queued after an old ride-along one is due from its own time.
    let mixed = super_agent(true, pending(T0, Some(T0 + 5 * MIN)));
    let running = checks(
        &super_agent(true, PendingStats::default()),
        HealthState::default(),
        &[T0 - MIN],
    )
    .0;
    let (_, raised) = checks(&mixed, running, &[T0 + 20 * MIN]);
    assert_eq!(raised.len(), 1, "{raised:?}");
}

#[test]
fn the_inbox_is_not_late_while_the_super_agent_is_down_or_just_back() {
    let stuck = pending(T0, Some(T0));
    // Down: check 4 speaks, not check 5.
    let (state, raised) = checks(
        &super_agent(false, stuck),
        HealthState::default(),
        &[T0 + 30 * MIN],
    );
    assert_eq!(
        raised
            .iter()
            .map(|(_, alert)| alert.check)
            .collect::<Vec<_>>(),
        vec![Check::SuperAgentDown]
    );
    // Back at T0 + 35: its Inbox counts from then.
    let back = super_agent(true, stuck);
    let (state, raised) = checks(&back, state, &[T0 + 35 * MIN, T0 + 45 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
    let (_, raised) = checks(&back, state, &[T0 + 50 * MIN]);
    assert_eq!(
        raised
            .iter()
            .map(|(_, alert)| alert.check)
            .collect::<Vec<_>>(),
        vec![Check::InboxUndelivered]
    );
}

// The state between checks.

#[test]
fn a_restart_alerts_nothing_again() {
    let facts = Facts {
        tasks: due_at(T0).tasks,
        ..super_agent(false, PendingStats::default())
    };
    let (state, raised) = checks(&facts, HealthState::default(), &[T0 + 10 * MIN]);
    assert_eq!(raised.len(), 2, "{raised:?}");
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.json");
    state.save(&path).unwrap();
    let (_, raised) = checks(&facts, HealthState::load(&path), &[T0 + 15 * MIN]);
    assert!(raised.is_empty(), "{raised:?}");
}

#[test]
fn a_check_drops_the_kept_notices_of_problems_that_cleared() {
    let facts = super_agent(false, PendingStats::default());
    let (state, raised) = checks(&facts, HealthState::default(), &[T0]);
    let state = state.keeping(raised[0].1.notice(T0)).keeping(KeptNotice {
        problem: None,
        session_id: "s-run_1".into(),
        schedule_id: Some("sch_1".into()),
        title: "Morning report".into(),
        body: "Failed: exit 3".into(),
        at: T0,
    });
    let (state, _) = checks(&facts, state, &[T0 + 5 * MIN]);
    assert_eq!(state.kept.len(), 2, "still down: still kept");
    let (state, _) = checks(
        &super_agent(true, PendingStats::default()),
        state,
        &[T0 + 10 * MIN],
    );
    assert_eq!(
        state
            .kept
            .iter()
            .map(|notice| notice.problem.clone())
            .collect::<Vec<_>>(),
        vec![None],
        "back up: its notice goes, the Run's own failure stays"
    );
}
