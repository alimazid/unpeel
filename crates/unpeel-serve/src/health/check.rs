//! Fork-only (#84): the health check's rules. Pure: what the Host sees now,
//! the state the last check left and the time in; the state this check
//! leaves and the alerts it raises out, so every rule is tested with
//! injected time, like the scheduler's step.
//!
//! Each problem has a key. A problem alerts when it has lasted its limit,
//! once; it alerts again only after a check saw it gone and a later one saw
//! it back. A problem a Run line reports (a failed or skipped Run) is news
//! only when that line was recorded after the last check, so history never
//! alerts, on a first check or after a restart.

use std::collections::{BTreeMap, HashSet};

use unpeel_core::schedules::{self, RunStatus, Schedule, ScheduleRun};
use unpeel_core::session_inbox::PendingStats;

use super::state::{HealthState, RunningSince, Tracked};
use super::Limits;
use crate::supervisor::duration;

/// A quoted report summary stays one short line.
const MAX_QUOTED_CHARS: usize = 300;
/// The banner title of a Router problem: the app's name for the Router.
pub const SUPER_AGENT_TITLE: &str = "Super Agent";

/// What the Host sees at a check.
#[derive(Debug, Clone, Default)]
pub struct Facts {
    pub tasks: Vec<TaskFacts>,
    /// The workspace's Router, when one is marked.
    pub router: Option<RouterFacts>,
    /// Running Sessions whose row asks the user something.
    pub asking: HashSet<String>,
}

#[derive(Debug, Clone)]
pub struct TaskFacts {
    pub schedule: Schedule,
    /// The next occurrence as the scheduler publishes it, as a local
    /// date-time and an instant; `None` while it is paused, for a Trigger
    /// that never fires, or a clock that will not read.
    pub next_run: Option<(String, u64)>,
    /// Every Run's latest line, oldest Run first; `None` when the Run log
    /// will not read.
    pub runs: Option<Vec<ScheduleRun>>,
}

#[derive(Debug, Clone)]
pub struct RouterFacts {
    pub session_id: String,
    pub running: bool,
    pub inbox: PendingStats,
    /// Why the Inbox drain holds its items, as `hold.json` says.
    pub hold: Option<String>,
}

/// Which check found a problem.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Check {
    RunFailed,
    RunSkipped,
    /// A Run in progress waits on a prompt.
    RunWaiting,
    /// A Run's own Session reported `blocked` (#81).
    RunBlocked,
    MissedFire,
    RouterDown,
    InboxUndelivered,
}

impl Check {
    /// Whether the alert goes to the Router's Inbox. Not its own being
    /// down, and not its stuck Inbox, where the report would sit too.
    pub fn to_router(self) -> bool {
        !matches!(self, Self::RouterDown | Self::InboxUndelivered)
    }

    /// Whether the alert is a Mac notification. A failed Run's own notice
    /// already is one (`schedules::notice`).
    pub fn to_mac(self) -> bool {
        self != Self::RunFailed
    }
}

/// One problem to alert about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub key: String,
    pub check: Check,
    /// When the problem's clock started.
    pub since: u64,
    pub schedule_id: Option<String>,
    pub session_id: Option<String>,
    /// The task's name, or [`SUPER_AGENT_TITLE`].
    pub title: String,
    /// Plain words: what is wrong, the task or Session id, what to do.
    pub text: String,
}

/// One check over `facts`.
pub fn check(
    facts: &Facts,
    prior: &HealthState,
    limits: &Limits,
    now: u64,
) -> (HealthState, Vec<Alert>) {
    let running = router_running(facts, prior, now);
    let findings = findings(facts, running.as_ref(), limits, now);
    let news_after = prior.last_check_ms.unwrap_or(now);
    let mut problems = BTreeMap::new();
    let mut alerts = Vec::new();
    for finding in findings {
        let tracked = prior.problems.get(&finding.key);
        let history = finding.recorded_at.is_some_and(|at| at <= news_after);
        if tracked.is_none() && history {
            continue;
        }
        let since = finding
            .began_at
            .or(tracked.map(|tracked| tracked.since))
            .unwrap_or(now);
        let lasted = now.saturating_sub(since);
        let alerted = tracked.is_some_and(|tracked| tracked.alerted);
        let due = lasted >= finding.limit_ms;
        if due && !alerted {
            alerts.push(Alert {
                key: finding.key.clone(),
                check: finding.check,
                since,
                schedule_id: finding.schedule_id,
                session_id: finding.session_id,
                title: finding.title,
                text: (finding.text)(lasted),
            });
        }
        problems.insert(
            finding.key,
            Tracked {
                since,
                alerted: alerted || due,
            },
        );
    }
    let state = HealthState {
        last_check_ms: Some(now),
        problems,
        router_running: running,
        ..prior.clone()
    };
    (state.without_cleared_notices(), alerts)
}

/// When a check first saw the Router running, since it was last seen
/// down (or another Session became it); `None` while it is down.
fn router_running(facts: &Facts, prior: &HealthState, now: u64) -> Option<RunningSince> {
    let router = facts.router.as_ref().filter(|agent| agent.running)?;
    let since = prior
        .router_running
        .as_ref()
        .filter(|seen| seen.session_id == router.session_id)
        .map_or(now, |seen| seen.since);
    Some(RunningSince {
        session_id: router.session_id.clone(),
        since,
    })
}

/// A problem as one check finds it.
struct Finding<'a> {
    key: String,
    check: Check,
    /// When the problem began, when the Host knows; else its clock starts
    /// when a check first sees it.
    began_at: Option<u64>,
    /// For a problem a Run line reports: when the line was recorded.
    recorded_at: Option<u64>,
    limit_ms: u64,
    schedule_id: Option<String>,
    session_id: Option<String>,
    title: String,
    /// The alert's words, given how long the problem has lasted.
    text: Box<dyn Fn(u64) -> String + 'a>,
}

fn findings<'a>(
    facts: &'a Facts,
    running: Option<&RunningSince>,
    limits: &Limits,
    now: u64,
) -> Vec<Finding<'a>> {
    let mut found = Vec::new();
    for task in &facts.tasks {
        found.extend(missed_fire(task, limits, now));
        let Some(runs) = task.runs.as_deref() else {
            continue;
        };
        found.extend(failed(task, runs));
        found.extend(skipped(task, runs));
        found.extend(waiting(task, runs, &facts.asking, limits));
        found.extend(blocked(task, runs, limits));
    }
    if let Some(router) = &facts.router {
        found.extend(router_down(router));
        found.extend(inbox_undelivered(router, running, limits, now));
    }
    found
}

/// Check 1: the task's newest finished Run failed (or failed to start). A
/// task's failures alert once, and again only after a Run of it is done.
/// Newest in log order, not by end: a done agent Run's end moves on with
/// each later turn of its Session (#81).
fn failed<'a>(task: &'a TaskFacts, runs: &'a [ScheduleRun]) -> Option<Finding<'a>> {
    let run = runs.iter().rev().find(|run| {
        matches!(
            run.status,
            RunStatus::Done | RunStatus::Failed | RunStatus::FailedToStart
        )
    })?;
    if run.status == RunStatus::Done {
        return None;
    }
    let at = run.ended_at_ms.unwrap_or(0);
    let outcome = match run.status {
        RunStatus::FailedToStart => "failed to start",
        _ => "failed",
    };
    Some(Finding {
        recorded_at: Some(at),
        began_at: Some(at),
        limit_ms: 0,
        session_id: run.session_id.clone(),
        text: Box::new(move |_| {
            format!(
                "Health check: Run {} of Scheduled Task {} {outcome}{}.{} It alerts again only \
                 after a Run of the task is done.",
                run.run_id,
                named(&task.schedule),
                reason(run),
                in_session(run, |id| format!(" Its Session is id:{id}.")),
            )
        }),
        ..task_finding(
            task,
            Check::RunFailed,
            format!("failed:{}", task.schedule.id),
        )
    })
}

/// Check 1: the task's newest occurrence (or Run now) was skipped, and no
/// Run of it has started since. Alerts once, and again only after a Run
/// of the task starts.
fn skipped<'a>(task: &'a TaskFacts, runs: &'a [ScheduleRun]) -> Option<Finding<'a>> {
    let skip = runs
        .iter()
        .filter(|run| run.status == RunStatus::Skipped)
        .max_by_key(|run| run.ended_at_ms.unwrap_or(0))?;
    let at = skip.ended_at_ms.unwrap_or(0);
    let started_since = runs
        .iter()
        .filter_map(|run| run.started_at_ms)
        .any(|started| started > at);
    if started_since {
        return None;
    }
    let blocker = schedules::current_run(runs).filter(|run| run.status.is_in_progress());
    let occurrence = skip
        .scheduled_for
        .as_deref()
        .map_or("its Run now".to_owned(), |at| {
            format!("its {at} occurrence")
        });
    Some(Finding {
        recorded_at: Some(at),
        began_at: Some(at),
        limit_ms: 0,
        session_id: blocker.and_then(|run| run.session_id.clone()),
        text: Box::new(move |_| {
            let blocking = blocker.map_or(String::new(), |run| {
                format!(
                    " Run {} is still in progress ({}){}.",
                    run.run_id,
                    run.status.word(),
                    in_session(run, |id| format!(" in Session id:{id}"))
                )
            });
            format!(
                "Health check: Scheduled Task {} skipped {occurrence}{}.{blocking} It alerts \
                 again only after a Run of the task starts.",
                named(&task.schedule),
                reason(skip),
            )
        }),
        ..task_finding(
            task,
            Check::RunSkipped,
            format!("skipped:{}", task.schedule.id),
        )
    })
}

/// Check 2: the task's Run in progress waits on a prompt (`needs_you`, or
/// its Session asks), counted from when a check first saw it so. Not one
/// that reported `blocked`: its report is the one alert (`blocked`).
fn waiting<'a>(
    task: &'a TaskFacts,
    runs: &'a [ScheduleRun],
    asking: &HashSet<String>,
    limits: &Limits,
) -> Option<Finding<'a>> {
    let run = schedules::current_run(runs)
        .filter(|run| run.status.is_in_progress() && !run.needs_attention())?;
    let asks = run
        .session_id
        .as_ref()
        .is_some_and(|session_id| asking.contains(session_id));
    if run.status != RunStatus::NeedsYou && !asks {
        return None;
    }
    Some(Finding {
        limit_ms: limits.run_waiting_ms,
        session_id: run.session_id.clone(),
        text: Box::new(move |lasted| {
            let why = run
                .reason
                .as_deref()
                .map_or(String::new(), |reason| format!(" ({reason})"));
            format!(
                "Health check: Run {} of Scheduled Task {} has waited on a prompt for {}{why}, \
                 and the task skips every occurrence until it ends. Answer the prompt in {}.",
                run.run_id,
                named(&task.schedule),
                duration(lasted),
                run.session_id
                    .as_deref()
                    .map_or("its Session".to_owned(), |id| format!(
                        "its Session id:{id}"
                    )),
            )
        }),
        ..task_finding(task, Check::RunWaiting, format!("waiting:{}", run.run_id))
    })
}

/// Check 2, #81: each Run of the task that reported `blocked` and still
/// needs attention, counted from the report. A later Run does not clear it
/// (a done Run holds back no occurrence); a new report or a failure does.
fn blocked<'a>(
    task: &'a TaskFacts,
    runs: &'a [ScheduleRun],
    limits: &Limits,
) -> impl Iterator<Item = Finding<'a>> + 'a {
    let limit_ms = limits.run_waiting_ms;
    runs.iter()
        .filter(|run| run.needs_attention())
        .filter_map(move |run| blocked_run(task, run, limit_ms))
}

fn blocked_run<'a>(
    task: &'a TaskFacts,
    run: &'a ScheduleRun,
    limit_ms: u64,
) -> Option<Finding<'a>> {
    let report = run.report.as_ref()?;
    Some(Finding {
        began_at: Some(report.at_ms),
        limit_ms,
        session_id: run.session_id.clone(),
        text: Box::new(move |lasted| {
            format!(
                "Health check: Run {} of Scheduled Task {} reported blocked {} ago and still is: \
                 \"{}\". Read its blocked report and unblock it{}.",
                run.run_id,
                named(&task.schedule),
                duration(lasted),
                quoted(&report.summary),
                in_session(run, |id| format!(" in its Session id:{id}")),
            )
        }),
        ..task_finding(
            task,
            Check::RunBlocked,
            format!("blocked:{}:{}", run.run_id, report.at_ms),
        )
    })
}

/// Check 3: the task's next occurrence has come due and no Run of it
/// started (the scheduler moves the next run on as it fires or skips one).
fn missed_fire<'a>(task: &'a TaskFacts, limits: &Limits, now: u64) -> Option<Finding<'a>> {
    let (due_at, due_ms) = task.next_run.as_ref().filter(|(_, ms)| *ms <= now)?;
    Some(Finding {
        began_at: Some(*due_ms),
        limit_ms: limits.missed_fire_ms,
        text: Box::new(move |lasted| {
            format!(
                "Health check: Scheduled Task {} was due at {due_at} ({} ago), and no Run of it \
                 started. The Host's warnings for it say why.",
                named(&task.schedule),
                duration(lasted),
            )
        }),
        ..task_finding(
            task,
            Check::MissedFire,
            format!("missed:{}:{due_ms}", task.schedule.id),
        )
    })
}

/// Check 4: the Router's Session is not running.
fn router_down(router: &RouterFacts) -> Option<Finding<'_>> {
    (!router.running).then(|| Finding {
        text: Box::new(move |_| {
            format!(
                "Health check: the Super Agent Session id:{} is not running. Worker reports and \
                 Host alerts wait in its Inbox until it runs again.",
                router.session_id
            )
        }),
        ..router_finding(
            router,
            Check::RouterDown,
            format!("router_down:{}", router.session_id),
        )
    })
}

/// Check 5: the Router's Inbox has had a delivery due for too long.
/// A delivery is due from a wake item's queue time, or once the oldest item
/// is old enough for ride-along items to be promoted (#83); never before
/// a check saw the Router running, so its being down is check 4's.
fn inbox_undelivered<'a>(
    router: &'a RouterFacts,
    running: Option<&RunningSince>,
    limits: &Limits,
    now: u64,
) -> Option<Finding<'a>> {
    let running_since = running?.since;
    let promoted_at = router
        .inbox
        .oldest_at
        .map(|at| at.saturating_add(limits.ride_along_promote_ms));
    let due = [router.inbox.oldest_wake_at, promoted_at]
        .into_iter()
        .flatten()
        .min()
        .filter(|due| *due <= now)?;
    Some(Finding {
        began_at: Some(due.max(running_since)),
        limit_ms: limits.inbox_undelivered_ms,
        text: Box::new(move |lasted| {
            let held = router.hold.as_deref().map_or(String::new(), |reason| {
                format!(" (the Host holds them: {reason})")
            });
            format!(
                "Health check: the Super Agent's Inbox (Session id:{}) has had items due for \
                 delivery for {}{held}.",
                router.session_id,
                duration(lasted),
            )
        }),
        ..router_finding(
            router,
            Check::InboxUndelivered,
            format!("inbox:{}", router.session_id),
        )
    })
}

fn task_finding<'a>(task: &TaskFacts, check: Check, key: String) -> Finding<'a> {
    Finding {
        key,
        check,
        began_at: None,
        recorded_at: None,
        limit_ms: 0,
        schedule_id: Some(task.schedule.id.clone()),
        session_id: None,
        title: crate::schedules::notice::title(&task.schedule),
        text: Box::new(|_| String::new()),
    }
}

fn router_finding<'a>(router: &RouterFacts, check: Check, key: String) -> Finding<'a> {
    Finding {
        key,
        check,
        began_at: None,
        recorded_at: None,
        limit_ms: 0,
        schedule_id: None,
        session_id: Some(router.session_id.clone()),
        title: SUPER_AGENT_TITLE.to_owned(),
        text: Box::new(|_| String::new()),
    }
}

/// `"Morning report" (id:sch_1)`.
fn named(schedule: &Schedule) -> String {
    format!(
        "\"{}\" (id:{})",
        crate::schedules::notice::title(schedule),
        schedule.id
    )
}

/// `: <reason>`, or nothing.
fn reason(run: &ScheduleRun) -> String {
    run.reason
        .as_deref()
        .map_or(String::new(), |reason| format!(": {reason}"))
}

/// `words` for the Run's Session id, or nothing.
fn in_session(run: &ScheduleRun, words: impl FnOnce(&str) -> String) -> String {
    run.session_id.as_deref().map_or(String::new(), words)
}

/// One line, at most [`MAX_QUOTED_CHARS`].
fn quoted(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() <= MAX_QUOTED_CHARS {
        return line;
    }
    let cut = line.chars().take(MAX_QUOTED_CHARS - 1).collect::<String>();
    format!("{}…", cut.trim_end())
}

#[cfg(test)]
mod tests;
