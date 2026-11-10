//! After its first idle (#81). An agent Run is `done` at the first idle
//! after its instructions (`agent_run`), but its Session often keeps
//! working, so the Host keeps following it:
//!
//! - **Each later idle** after the agent worked again (seen working since
//!   the Run's last line, or a program, hook or report stamp newer than
//!   it) moves the Run's end to now and its snippet to the newer reply,
//!   if there is one. The status stays `done`: the first idle is still
//!   when the Run became done, and when "Notify when done" fires.
//! - **A report** the Run Session sends during the Run (`sessions report`,
//!   kept by `unpeel_core::schedules::run_report`) lands on the Run line,
//!   the last one replacing the one before, in progress or done. A
//!   `blocked` one shows the Run as needing attention to Controllers; it
//!   never changes the status, so it never holds back the next
//!   occurrence. A `done` one is the final word: once the turn that sent
//!   it has ended, nothing moves the Run again.
//!
//! Following stops when the Session ends (the Run stays `done`), when a
//! newer Run becomes the task's latest (only the latest Run is stepped),
//! and after a done report's turn. A task without instructions is not
//! followed: its Session is the user's once its agent was ready.

use unpeel_core::schedules::{RunReport, RunStatus, ScheduleRun};

use super::agent_run::{self, AgentObservation, AgentStatus};
use super::step::RunObservation;

/// A done agent Run whose Session the Host still follows: its instructions
/// were typed, and no done report's turn has ended it.
pub fn is_followed(run: &ScheduleRun) -> bool {
    run.status == RunStatus::Done
        && run.is_agent_run()
        && run.prompted_at_ms.is_some()
        && !closed_by_report(run)
}

/// Whether a report from the Run's Session still lands on it: while the Run
/// is in progress, or followed.
pub fn takes_reports(run: &ScheduleRun) -> bool {
    run.status.is_in_progress() || is_followed(run)
}

/// The Run with `report` on it, when it is news the Run still takes.
pub fn with_report(run: &ScheduleRun, report: Option<&RunReport>) -> Option<ScheduleRun> {
    let report = report.filter(|report| run.report.as_ref() != Some(*report))?;
    takes_reports(run).then(|| ScheduleRun {
        report: Some(report.clone()),
        ..run.clone()
    })
}

/// A followed Run's next line: a later turn ended. Nothing once its Session
/// is gone, or while the agent works or waits on a question.
pub fn advance(
    run: &ScheduleRun,
    observation: &RunObservation,
    now_ms: u64,
) -> Option<ScheduleRun> {
    let RunObservation::Agent(agent) = observation else {
        return None;
    };
    (worked_since_line(run, agent) && agent.activity.status == AgentStatus::Idle).then(|| {
        let line_at = run.ended_at_ms.unwrap_or(0);
        ScheduleRun {
            ended_at_ms: Some(now_ms),
            snippet: agent_run::reply_since(&agent.activity, line_at + 1)
                .or_else(|| run.snippet.clone()),
            ..run.clone()
        }
    })
}

/// Evidence that the agent took a turn after the Run's last line: the Host
/// saw it working (the only sign a screen-tier agent gives), or something
/// it reported is newer than the line.
fn worked_since_line(run: &ScheduleRun, agent: &AgentObservation) -> bool {
    let activity = &agent.activity;
    let line_at = run.ended_at_ms.unwrap_or(0);
    let stamped = |reply: &Option<(String, u64)>| reply.as_ref().map(|(_, at)| *at);
    agent.seen_working
        || [
            activity.working_at_ms,
            activity.finished_at_ms,
            stamped(&activity.program_reply),
            stamped(&activity.hook_reply),
            run.report.as_ref().map(|report| report.at_ms),
        ]
        .into_iter()
        .flatten()
        .any(|at| at > line_at)
}

/// A done report ends following once a line was recorded at or after it.
fn closed_by_report(run: &ScheduleRun) -> bool {
    run.report.as_ref().is_some_and(|report| {
        report.is_done() && run.ended_at_ms.is_some_and(|ended| ended >= report.at_ms)
    })
}

#[cfg(test)]
mod tests;
