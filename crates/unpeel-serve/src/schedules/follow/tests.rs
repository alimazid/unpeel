//! A done agent Run following its Session, and a Run Session's reports,
//! through the scheduler's step with injected time (#81).

use super::*;
use crate::schedules::agent_run::{
    AgentActivity, AgentObservation, AgentStatus, WORKING_TIMEOUT_MS,
};
use crate::schedules::clock;
use crate::schedules::step::{step, Action, LaunchPlan, RunKind, RunObservation, TaskState};
use jiff::civil::date;
use jiff::tz::{self, TimeZone};
use jiff::Zoned;
use unpeel_core::schedules::{RunPhase, RunStatus, Schedule, ScheduleClock, ScheduleTrigger};

fn now(minute: i8, second: i8) -> Zoned {
    date(2026, 11, 6)
        .at(9, minute, second, 0)
        .to_zoned(TimeZone::fixed(tz::offset(-5)))
        .unwrap()
}

fn ms(minute: i8, second: i8) -> u64 {
    clock::epoch_ms(&now(minute, second))
}

fn task(trigger: ScheduleTrigger) -> TaskState {
    TaskState {
        schedule: Schedule {
            id: "sch_agent".into(),
            name: "Build".into(),
            project_id: "p".into(),
            preset_id: "claude".into(),
            instructions: Some("build and install".into()),
            trigger,
            enabled: true,
            notify_when_done: true,
            created_at_ms: ms(0, 0),
            clock_reset_at_ms: None,
        },
        clock: ScheduleClock::default(),
        latest_run: None,
        observation: RunObservation::Idle,
        report: None,
        run_now: None,
        launch: Ok(LaunchPlan {
            project_id: "p".into(),
            preset_id: "claude".into(),
            command: "claude".into(),
            cwd: "/tmp".into(),
            worktree_path: None,
            worktree_branch: None,
            kind: RunKind::Agent {
                instructions: Some("build and install".into()),
            },
        }),
    }
}

/// The Run as its first idle left it: done at 09:02:00, its instructions
/// typed at 09:01:00, "still compiling" its reply.
fn done_run() -> ScheduleRun {
    ScheduleRun {
        run_id: "run_agent".into(),
        scheduled_for: None,
        started_at_ms: Some(ms(0, 0)),
        ended_at_ms: Some(ms(2, 0)),
        status: RunStatus::Done,
        late: false,
        session_id: Some("session-agent".into()),
        exit_code: None,
        reason: None,
        snippet: Some("Still compiling in the background.".into()),
        phase: Some(RunPhase::Working),
        prompted_at_ms: Some(ms(1, 0)),
        report: None,
    }
}

fn running_run() -> ScheduleRun {
    ScheduleRun {
        ended_at_ms: None,
        status: RunStatus::Running,
        snippet: None,
        ..done_run()
    }
}

fn agent(activity: AgentActivity, seen_working: bool) -> RunObservation {
    RunObservation::Agent(AgentObservation {
        delivery: None,
        activity,
        working_timeout_ms: WORKING_TIMEOUT_MS,
        seen_working,
    })
}

fn idle() -> AgentActivity {
    AgentActivity {
        status: AgentStatus::Idle,
        ..AgentActivity::default()
    }
}

/// An idle agent whose Stop hook brought `reply` at `at`.
fn replied(reply: &str, at: u64) -> AgentActivity {
    AgentActivity {
        status: AgentStatus::Idle,
        finished_at_ms: Some(at),
        hook_reply: Some((reply.into(), at)),
        ..AgentActivity::default()
    }
}

fn report(status: &str, summary: &str, at: u64) -> RunReport {
    RunReport {
        status: status.into(),
        summary: summary.into(),
        at_ms: at,
    }
}

/// The one Run line a step at `at` records for `run`, if any.
fn line(
    run: ScheduleRun,
    observation: RunObservation,
    report: Option<RunReport>,
    at: &Zoned,
) -> Option<ScheduleRun> {
    let state = TaskState {
        latest_run: Some(run),
        observation,
        report,
        ..task(ScheduleTrigger::Daily {
            time: "23:00".into(),
        })
    };
    let actions = step(&[state], at, &mut || "run_new".to_string());
    let mut lines = actions.into_iter().filter_map(|action| match action {
        Action::Record { run, .. } => Some(run),
        _ => None,
    });
    let found = lines.next();
    assert!(lines.next().is_none(), "one line per step");
    found
}

#[test]
fn a_later_idle_moves_the_runs_end_and_snippet_and_the_status_stays_done() {
    let later = line(
        done_run(),
        agent(replied("Build 135 installed.", ms(9, 0)), false),
        None,
        &now(9, 1),
    )
    .expect("the later turn is recorded");
    assert_eq!(later.status, RunStatus::Done);
    assert_eq!(later.ended_at_ms, Some(ms(9, 1)));
    assert_eq!(later.snippet.as_deref(), Some("Build 135 installed."));
    assert_eq!(later.phase, Some(RunPhase::Working));

    // Seen again on the next sweep, the same turn records nothing more.
    assert_eq!(
        line(
            later,
            agent(replied("Build 135 installed.", ms(9, 0)), false),
            None,
            &now(9, 2)
        ),
        None
    );
}

#[test]
fn a_turn_seen_working_is_recorded_when_its_agent_idles_again() {
    // While the agent works there is nothing to record.
    let working = AgentActivity {
        status: AgentStatus::Working,
        ..AgentActivity::default()
    };
    assert_eq!(
        line(done_run(), agent(working, true), None, &now(5, 0)),
        None
    );
    // A screen-tier agent has no stamps: the Host saw it working, and now
    // it is idle. Without a newer reply the snippet stays the last one.
    let later = line(done_run(), agent(idle(), true), None, &now(6, 0)).expect("recorded");
    assert_eq!(later.ended_at_ms, Some(ms(6, 0)));
    assert_eq!(later.snippet, done_run().snippet);
    // A program that reported working after the line counts as well.
    let program = AgentActivity {
        working_at_ms: Some(ms(4, 0)),
        ..idle()
    };
    assert!(line(done_run(), agent(program, false), None, &now(6, 0)).is_some());
}

#[test]
fn an_idle_agent_with_nothing_newer_records_nothing() {
    let stale = AgentActivity {
        working_at_ms: Some(ms(1, 30)),
        ..replied("Still compiling in the background.", ms(1, 59))
    };
    assert_eq!(
        line(done_run(), agent(stale, false), None, &now(3, 0)),
        None
    );
    // Neither does a Session no tier speaks for, or a question.
    let silent = AgentActivity::default();
    assert_eq!(
        line(done_run(), agent(silent, true), None, &now(3, 0)),
        None
    );
    let asking = AgentActivity {
        status: AgentStatus::Attention,
        ..replied("Ship it?", ms(2, 30))
    };
    assert_eq!(
        line(done_run(), agent(asking, false), None, &now(3, 0)),
        None
    );
}

#[test]
fn following_stops_when_the_session_ends_and_the_run_stays_done() {
    for gone in [
        RunObservation::Exited(0),
        RunObservation::Exited(1),
        RunObservation::Ended,
        RunObservation::Missing,
        RunObservation::Live,
        RunObservation::Idle,
    ] {
        assert_eq!(
            line(done_run(), gone.clone(), None, &now(9, 0)),
            None,
            "{gone:?}"
        );
    }
}

#[test]
fn a_run_that_typed_nothing_is_not_followed() {
    let bare = ScheduleRun {
        prompted_at_ms: None,
        phase: Some(RunPhase::WaitingReady),
        snippet: None,
        ..done_run()
    };
    assert!(!is_followed(&bare));
    assert_eq!(
        line(
            bare.clone(),
            agent(replied("the user's own turn", ms(9, 0)), true),
            None,
            &now(9, 1)
        ),
        None
    );
    assert_eq!(
        line(
            bare,
            agent(idle(), false),
            Some(report("blocked", "?", ms(9, 0))),
            &now(9, 1)
        ),
        None,
        "its Session is the user's once its agent was ready"
    );
    let script = ScheduleRun {
        phase: None,
        prompted_at_ms: None,
        ..done_run()
    };
    assert!(!is_followed(&script));
}

#[test]
fn a_report_lands_on_the_run_line_whatever_the_run_is_doing() {
    let blocked = report("blocked", "Waiting on a signing key", ms(1, 30));
    // In progress: the line keeps its status and phase.
    let working = AgentActivity {
        status: AgentStatus::Working,
        ..AgentActivity::default()
    };
    let running = line(
        running_run(),
        agent(working.clone(), false),
        Some(blocked.clone()),
        &now(1, 31),
    )
    .expect("the report is recorded");
    assert_eq!(running.status, RunStatus::Running);
    assert_eq!(running.report, Some(blocked.clone()));
    // The same report seen again records nothing.
    assert_eq!(
        line(
            running,
            agent(working, false),
            Some(blocked.clone()),
            &now(1, 32)
        ),
        None
    );

    // A later report replaces it; the agent still works, so the end stays.
    let update = report("update", "Signed; uploading", ms(5, 0));
    let still = AgentActivity {
        status: AgentStatus::Working,
        ..AgentActivity::default()
    };
    let replaced = line(
        done_run(),
        agent(still, true),
        Some(update.clone()),
        &now(5, 1),
    )
    .expect("replaced");
    assert_eq!(replaced.report, Some(update));
    assert_eq!(replaced.ended_at_ms, done_run().ended_at_ms);
    assert_eq!(replaced.status, RunStatus::Done);

    // A report and the Session's exit in one sweep: the report is kept.
    let exited = line(
        done_run(),
        RunObservation::Exited(0),
        Some(blocked.clone()),
        &now(5, 2),
    )
    .expect("kept");
    assert_eq!(
        (exited.status, exited.report),
        (RunStatus::Done, Some(blocked))
    );
}

#[test]
fn a_report_after_the_last_line_is_the_agents_turn() {
    // A report sent after the Run's last line, its agent idle by the time
    // the Host reads it: that turn ended, so the line ends now.
    let blocked = report("blocked", "Need the operator's approval", ms(7, 0));
    let ended = line(
        done_run(),
        agent(idle(), false),
        Some(blocked.clone()),
        &now(7, 2),
    )
    .expect("recorded");
    assert_eq!(ended.report, Some(blocked.clone()));
    assert_eq!(ended.ended_at_ms, Some(ms(7, 2)));
    assert_eq!(
        ended.status,
        RunStatus::Done,
        "a blocked report never changes the status"
    );
    assert!(is_followed(&ended), "a blocked Run is still followed");
    assert_eq!(
        line(ended, agent(idle(), false), Some(blocked), &now(7, 3)),
        None
    );
}

#[test]
fn a_done_report_is_the_final_word_once_its_turn_ends() {
    let done = report("done", "Build 135 installed", ms(8, 0));
    // The agent reports done, then finishes its turn.
    let working = AgentActivity {
        status: AgentStatus::Working,
        ..AgentActivity::default()
    };
    let reported = line(
        done_run(),
        agent(working, true),
        Some(done.clone()),
        &now(8, 1),
    )
    .expect("the report");
    assert!(is_followed(&reported), "its turn is still going");
    let last = line(
        reported,
        agent(replied("Installed and verified.", ms(8, 30)), true),
        Some(done.clone()),
        &now(8, 31),
    )
    .expect("the turn that sent it");
    assert_eq!(last.ended_at_ms, Some(ms(8, 31)));
    assert_eq!(last.snippet.as_deref(), Some("Installed and verified."));
    assert!(!is_followed(&last));

    // After it, nothing moves the Run: not a later turn, not a new report.
    assert_eq!(
        line(
            last.clone(),
            agent(replied("Something else", ms(20, 0)), true),
            Some(done),
            &now(20, 1)
        ),
        None
    );
    assert_eq!(
        line(
            last,
            agent(idle(), false),
            Some(report("blocked", "?", ms(21, 0))),
            &now(21, 1)
        ),
        None
    );
}

#[test]
fn a_done_report_before_the_first_idle_ends_with_it() {
    let done = report("done", "Nothing to build", ms(1, 20));
    let finished = AgentActivity {
        status: AgentStatus::Idle,
        working_at_ms: Some(ms(1, 10)),
        ..AgentActivity::default()
    };
    let first = line(
        running_run(),
        agent(finished, false),
        Some(done.clone()),
        &now(1, 30),
    )
    .expect("done at its first idle");
    assert_eq!(first.status, RunStatus::Done);
    assert_eq!(first.report, Some(done));
    assert!(!is_followed(&first));
}

#[test]
fn a_followed_run_never_holds_back_the_next_occurrence() {
    // Due at 09:05: the Run still followed is done, so the occurrence runs.
    let state = TaskState {
        latest_run: Some(done_run()),
        observation: agent(idle(), false),
        ..task(ScheduleTrigger::Daily {
            time: "09:05".into(),
        })
    };
    let actions = step(&[state], &now(5, 0), &mut || "run_next".to_string());
    assert!(
        actions.iter().any(|action| matches!(
            action,
            Action::Start { run, .. } if run.run_id == "run_next"
        )),
        "{actions:?}"
    );
}
