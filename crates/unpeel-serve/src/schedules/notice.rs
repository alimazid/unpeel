//! What the user hears about a Run of a Scheduled Task.
//!
//! A Run Session's own edges notify as every Session's do: its NeedsInput
//! edge always, its Finished edge when the task's "Notify when done" says
//! so ([`notify_when_done`]), in place of the app's global setting. A Run
//! notice covers the outcomes no Session edge reports, once, when its Run
//! line enters them:
//!
//! - `failed` and `failed_to_start` always, with the task's name and the
//!   reason; they leave nothing unread (the SCHEDULED row's status shows
//!   them).
//! - `needs_you` while the Session itself asks nothing: no working signal
//!   after the instructions, past the working window. An agent's question is its Session's
//!   NeedsInput edge.
//! - `done` for a Run that typed nothing (a script, a bare Agent Preset),
//!   or whose agent only its screen saw finish (the screen tier never
//!   sends a Finished edge): no Finished edge reports it. It follows the
//!   task's "Notify when done".
//!
//! `skipped` only shows in the history.

use unpeel_core::schedules::{RunStatus, Schedule, ScheduleRun};

use super::agent_run::AgentActivity;
use crate::notifications::NotificationKind;

/// A banner title stays one short line.
const MAX_TITLE_CHARS: usize = 120;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunNotice {
    pub kind: NotificationKind,
    pub title: String,
    pub body: String,
    /// `Some` for a finished Run: the task's own "Notify when done",
    /// which decides in place of the app's global setting. Every other
    /// notice always notifies.
    pub notify_when_done: Option<bool>,
}

impl RunNotice {
    /// A Run that finished or waits on the user is unread until someone
    /// looks, like its Session's own edges; a failure is not.
    pub fn marks_unread(&self) -> bool {
        self.kind != NotificationKind::Alert
    }
}

/// What a Run's Session reports through its own edges right now, so a Run
/// notice never repeats one of them.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SessionEdges {
    /// Its row shows attention: its NeedsInput edge asks the user.
    pub asks: bool,
    /// It finished a turn since the Run's instructions ([`finished_turn`]):
    /// its Finished edge reports the Run's end.
    pub finished_turn: bool,
}

/// Whether `activity` holds a finished turn since `run`'s instructions were
/// typed (a program done or error report, a Stop hook): what gives a Run
/// Session its own Finished edge. Never for a Run that typed nothing; the
/// screen tier alone never finishes a turn.
pub fn finished_turn(run: &ScheduleRun, activity: &AgentActivity) -> bool {
    run.prompted_at_ms.is_some_and(|prompted_at| {
        activity
            .finished_at_ms
            .is_some_and(|finished_at| finished_at >= prompted_at)
    })
}

/// The notice for `run`'s line just recorded, if it enters an outcome the
/// user hears about. `previous` is the Run's status before this line
/// (`None` for a new Run); `edges` what its Session reports itself.
pub fn for_recorded(
    schedule: &Schedule,
    run: &ScheduleRun,
    previous: Option<RunStatus>,
    edges: SessionEdges,
) -> Option<RunNotice> {
    if previous == Some(run.status) {
        return None;
    }
    let typed_nothing = run.prompted_at_ms.is_none();
    let (kind, outcome, notify_when_done) = match run.status {
        RunStatus::Failed => (NotificationKind::Alert, "Failed", None),
        RunStatus::FailedToStart => (NotificationKind::Alert, "Failed to start", None),
        RunStatus::NeedsYou if !edges.asks => (NotificationKind::NeedsInput, "Needs you", None),
        RunStatus::Done if typed_nothing || !edges.finished_turn => (
            NotificationKind::Done,
            "Finished",
            Some(schedule.notify_when_done),
        ),
        _ => return None,
    };
    let body = match (kind, run.snippet.as_deref(), run.reason.as_deref()) {
        (NotificationKind::Done, Some(snippet), _) => crate::completion_snippet::snippet(snippet),
        (NotificationKind::Done, None, _) | (_, _, None) => None,
        (_, _, Some(reason)) => crate::completion_snippet::snippet(&format!("{outcome}: {reason}")),
    };
    Some(RunNotice {
        kind,
        title: title(schedule),
        body: body.unwrap_or_else(|| outcome.to_owned()),
        notify_when_done,
    })
}

/// The task's name as one short line; its id when it has none.
fn title(schedule: &Schedule) -> String {
    let name = schedule.name.trim();
    let name = if name.is_empty() {
        schedule.id.as_str()
    } else {
        name
    };
    let line = name
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if line.chars().count() <= MAX_TITLE_CHARS {
        return line;
    }
    let cut = line.chars().take(MAX_TITLE_CHARS - 1).collect::<String>();
    format!("{}…", cut.trim_end())
}

/// A Run Session's Finished-edge eligibility: its task's "Notify when
/// done". `None` (the app's own settings decide) when the task is gone.
pub fn notify_when_done(schedules: &[Schedule], schedule_id: &str) -> Option<bool> {
    schedules
        .iter()
        .find(|schedule| schedule.id == schedule_id)
        .map(|schedule| schedule.notify_when_done)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schedules::agent_run::AgentActivity;
    use unpeel_core::schedules::{RunPhase, ScheduleTrigger};

    fn task(notify_when_done: bool) -> Schedule {
        Schedule {
            id: "sch_1".into(),
            name: "Morning report".into(),
            project_id: "p".into(),
            preset_id: "ok".into(),
            instructions: None,
            trigger: ScheduleTrigger::Daily {
                time: "09:00".into(),
            },
            enabled: true,
            notify_when_done,
            created_at_ms: 0,
            clock_reset_at_ms: None,
        }
    }

    fn line(status: RunStatus, reason: Option<&str>) -> ScheduleRun {
        ScheduleRun {
            run_id: "run_1".into(),
            scheduled_for: Some("2026-11-06T09:00".into()),
            started_at_ms: Some(1),
            ended_at_ms: Some(2),
            status,
            late: false,
            session_id: Some("s-1".into()),
            exit_code: None,
            reason: reason.map(str::to_owned),
            snippet: None,
            phase: None,
            prompted_at_ms: None,
            report: None,
            session_ended: false,
        }
    }

    /// A Session whose own edges report nothing about the Run.
    fn quiet() -> SessionEdges {
        SessionEdges::default()
    }

    /// A Session whose row asks the user something.
    fn asking() -> SessionEdges {
        SessionEdges {
            asks: true,
            ..SessionEdges::default()
        }
    }

    fn prompted(run: ScheduleRun, phase: RunPhase) -> ScheduleRun {
        ScheduleRun {
            phase: Some(phase),
            prompted_at_ms: Some(1),
            ..run
        }
    }

    #[test]
    fn a_failed_run_always_notifies_with_the_task_name_and_reason() {
        let run = line(RunStatus::Failed, Some("the command exited with status 3"));
        let notice = for_recorded(&task(false), &run, Some(RunStatus::Running), quiet());
        assert_eq!(
            notice,
            Some(RunNotice {
                kind: NotificationKind::Alert,
                title: "Morning report".into(),
                body: "Failed: the command exited with status 3".into(),
                notify_when_done: None,
            })
        );
        assert!(!notice.unwrap().marks_unread());
    }

    #[test]
    fn a_run_that_could_not_launch_notifies_without_a_session() {
        let run = ScheduleRun {
            session_id: None,
            ..line(RunStatus::Failed, Some("the preset ok no longer exists"))
        };
        let notice = for_recorded(&task(true), &run, None, quiet()).expect("a notice");
        assert_eq!(notice.body, "Failed: the preset ok no longer exists");
    }

    #[test]
    fn a_run_that_failed_to_start_says_so() {
        let reason = "the agent showed no sign of being ready, so nothing was typed; \
                      its Session is left open";
        let run = prompted(
            line(RunStatus::FailedToStart, Some(reason)),
            RunPhase::WaitingReady,
        );
        let notice =
            for_recorded(&task(true), &run, Some(RunStatus::Running), quiet()).expect("a notice");
        assert_eq!(notice.kind, NotificationKind::Alert);
        assert_eq!(notice.body, format!("Failed to start: {reason}"));
        assert_eq!(notice.notify_when_done, None);
    }

    #[test]
    fn a_failure_without_a_reason_still_names_the_outcome() {
        let run = line(RunStatus::Failed, None);
        let notice = for_recorded(&task(true), &run, Some(RunStatus::Running), quiet());
        assert_eq!(notice.map(|notice| notice.body), Some("Failed".into()));
    }

    /// A followed Run's later lines (#81) stay done: "Notify when done"
    /// fired at its first idle and never again, a report included.
    #[test]
    fn a_done_runs_later_turn_or_report_is_no_new_notice() {
        let later = ScheduleRun {
            snippet: Some("Build 135 installed.".into()),
            report: Some(unpeel_core::schedules::RunReport {
                status: "blocked".into(),
                summary: "Waiting on a signing key".into(),
                at_ms: 3,
            }),
            ..prompted(line(RunStatus::Done, None), RunPhase::Working)
        };
        let previous = Some(RunStatus::Done);
        assert_eq!(for_recorded(&task(true), &later, previous, quiet()), None);
    }

    #[test]
    fn a_skipped_or_still_running_line_is_history_only() {
        for status in [RunStatus::Skipped, RunStatus::Running] {
            let run = line(status, Some("the previous Run was still in progress"));
            assert_eq!(
                for_recorded(&task(true), &run, None, quiet()),
                None,
                "{status:?}"
            );
        }
    }

    #[test]
    fn a_line_that_keeps_its_status_notifies_nothing_new() {
        // `needs_you` is re-recorded when a late working signal moves its
        // phase on; a failure is never recorded twice, but would not repeat.
        let needs_you = prompted(
            line(RunStatus::NeedsYou, Some("no working signal")),
            RunPhase::Working,
        );
        assert_eq!(
            for_recorded(&task(true), &needs_you, Some(RunStatus::NeedsYou), quiet()),
            None
        );
        let failed = line(RunStatus::Failed, Some("exit 3"));
        assert_eq!(
            for_recorded(&task(true), &failed, Some(RunStatus::Failed), quiet()),
            None
        );
    }

    #[test]
    fn needs_you_without_a_question_notifies_and_leaves_the_run_unread() {
        let reason = "the agent showed no working signal within 60 s of its instructions";
        let run = prompted(line(RunStatus::NeedsYou, Some(reason)), RunPhase::Prompted);
        let notice =
            for_recorded(&task(false), &run, Some(RunStatus::Running), quiet()).expect("a notice");
        assert_eq!(notice.kind, NotificationKind::NeedsInput);
        assert_eq!(notice.body, format!("Needs you: {reason}"));
        assert_eq!(notice.notify_when_done, None);
        assert!(notice.marks_unread());
    }

    #[test]
    fn an_agent_question_is_left_to_its_sessions_needs_input_edge() {
        let run = prompted(
            line(
                RunStatus::NeedsYou,
                Some("the agent is waiting for an answer"),
            ),
            RunPhase::Working,
        );
        assert_eq!(
            for_recorded(&task(true), &run, Some(RunStatus::Running), asking()),
            None
        );
    }

    #[test]
    fn a_script_run_that_finished_follows_the_tasks_notify_when_done() {
        for notify in [true, false] {
            let run = ScheduleRun {
                exit_code: Some(0),
                ..line(RunStatus::Done, None)
            };
            let notice = for_recorded(&task(notify), &run, Some(RunStatus::Running), quiet())
                .expect("a notice");
            assert_eq!(notice.kind, NotificationKind::Done);
            assert_eq!(notice.title, "Morning report");
            assert_eq!(notice.body, "Finished");
            assert_eq!(notice.notify_when_done, Some(notify));
            assert!(notice.marks_unread());
        }
    }

    #[test]
    fn a_bare_agent_preset_run_finished_when_its_agent_was_ready() {
        let run = ScheduleRun {
            phase: Some(RunPhase::WaitingReady),
            ..line(RunStatus::Done, None)
        };
        let notice = for_recorded(&task(true), &run, Some(RunStatus::Running), quiet());
        assert_eq!(
            notice.map(|notice| notice.kind),
            Some(NotificationKind::Done)
        );
    }

    #[test]
    fn an_agent_run_that_finished_its_instructions_is_left_to_its_finished_edge() {
        let run = ScheduleRun {
            snippet: Some("Report sent.".into()),
            ..prompted(line(RunStatus::Done, None), RunPhase::Working)
        };
        let edges = SessionEdges {
            finished_turn: true,
            ..SessionEdges::default()
        };
        assert_eq!(
            for_recorded(&task(true), &run, Some(RunStatus::Running), edges),
            None
        );
    }

    /// The screen tier never sends a Finished edge: a Run its agent's
    /// screen alone saw done gets the done notice instead, once, by the
    /// task's setting and with the reply.
    #[test]
    fn an_agent_run_done_by_its_screen_alone_notifies_once() {
        for notify in [true, false] {
            let run = ScheduleRun {
                snippet: Some("Report sent.".into()),
                ..prompted(line(RunStatus::Done, None), RunPhase::Working)
            };
            let notice = for_recorded(&task(notify), &run, Some(RunStatus::Running), quiet())
                .expect("a notice");
            assert_eq!(notice.kind, NotificationKind::Done);
            assert_eq!(notice.body, "Report sent.");
            assert_eq!(notice.notify_when_done, Some(notify));
            assert_eq!(
                for_recorded(&task(notify), &run, Some(RunStatus::Done), quiet()),
                None,
                "once"
            );
        }
    }

    #[test]
    fn a_finished_turn_counts_only_after_the_instructions() {
        let run = prompted(line(RunStatus::Done, None), RunPhase::Working);
        let finished_at = |at| AgentActivity {
            finished_at_ms: at,
            ..AgentActivity::default()
        };
        // Typed at 1.
        assert!(finished_turn(&run, &finished_at(Some(1))));
        assert!(finished_turn(&run, &finished_at(Some(5))));
        assert!(!finished_turn(&run, &finished_at(Some(0))));
        assert!(!finished_turn(&run, &finished_at(None)));
        let typed_nothing = line(RunStatus::Done, None);
        assert!(!finished_turn(&typed_nothing, &finished_at(Some(5))));
    }

    #[test]
    fn the_reply_snippet_is_the_body_when_a_run_has_one() {
        let run = ScheduleRun {
            snippet: Some("All 12 checks passed.".into()),
            ..line(RunStatus::Done, None)
        };
        let notice = for_recorded(&task(true), &run, Some(RunStatus::Running), quiet());
        assert_eq!(
            notice.map(|notice| notice.body),
            Some("All 12 checks passed.".into())
        );
    }

    #[test]
    fn an_unnamed_task_is_titled_by_its_id_and_a_long_name_is_cut() {
        let unnamed = Schedule {
            name: "  ".into(),
            ..task(true)
        };
        let run = line(RunStatus::Failed, Some("exit 3"));
        let notice = for_recorded(&unnamed, &run, None, quiet()).unwrap();
        assert_eq!(notice.title, "sch_1");

        let long = Schedule {
            name: "word ".repeat(60),
            ..task(true)
        };
        let title = for_recorded(&long, &run, None, quiet()).unwrap().title;
        assert!(title.chars().count() <= MAX_TITLE_CHARS, "{title}");
        assert!(title.ends_with('…'), "{title}");
    }

    #[test]
    fn a_run_sessions_finished_edge_follows_its_task() {
        let tasks = [task(false)];
        assert_eq!(notify_when_done(&tasks, "sch_1"), Some(false));
        let tasks = [task(true)];
        assert_eq!(notify_when_done(&tasks, "sch_1"), Some(true));
        // A deleted task's Runs are ordinary Sessions again.
        assert_eq!(notify_when_done(&tasks, "sch_gone"), None);
    }
}
