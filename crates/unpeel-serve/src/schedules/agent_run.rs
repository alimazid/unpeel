//! An agent Run's lifecycle (a task with instructions on an Agent Preset):
//!
//! ```text
//! launching ─▶ waiting_ready ─▶ prompted ─▶ working ─▶ done
//!     │              │              │          │
//!   failed     failed_to_start  needs_you  needs_you
//! ```
//!
//! The preset launches exactly as typed; a helper thread waits for the
//! agent's first readiness signal and types the instructions (ticket 02's
//! `initial_text::deliver`, 120 s budget). From then on the Run follows the
//! Host's activity rows, which the worker rebuilds every rescan whoever owns
//! notifications. `working` starts at the first working signal after the
//! paste; `done` is the first idle or done edge after that. No working
//! signal within the window, or an attention edge, is `needs_you`: no
//! timeout and no kill, and a later done edge still makes it `done`. The
//! agent exiting first is `failed` with its exit code.
//!
//! A Session's default "idle" (a source that has said nothing) is never an
//! edge: only a status from a tier that spoke counts.

use unpeel_core::schedules::{RunPhase, RunStatus, ScheduleRun};

use super::step::RunObservation;

/// How long after its instructions are typed an agent has to show a working
/// signal before its Run needs you.
pub const WORKING_TIMEOUT_MS: u64 = 60_000;
/// Test Hosts (`UNPEEL_TEST=1`) may shorten the window, like the readiness
/// budget's `UNPEEL_AGENT_READY_TIMEOUT_MS`.
const WORKING_TIMEOUT_OVERRIDE_ENV: &str = "UNPEEL_AGENT_WORKING_TIMEOUT_MS";

/// The working window this Host uses.
pub fn working_timeout_ms() -> u64 {
    working_timeout_from(
        std::env::var("UNPEEL_TEST").ok().as_deref(),
        std::env::var(WORKING_TIMEOUT_OVERRIDE_ENV).ok().as_deref(),
    )
}

fn working_timeout_from(test_host: Option<&str>, override_ms: Option<&str>) -> u64 {
    override_ms
        .filter(|_| test_host == Some("1"))
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(WORKING_TIMEOUT_MS)
}

/// What an agent Run's Session shows, once it is up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentObservation {
    /// News from the helper typing the instructions; `None` once they are
    /// typed (nothing more will come).
    pub delivery: Option<Delivery>,
    pub activity: AgentActivity,
    /// [`WORKING_TIMEOUT_MS`], shortened on test Hosts.
    pub working_timeout_ms: u64,
}

/// The helper's progress typing the instructions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// The Session is up; the helper waits for the agent to be ready.
    Waiting,
    /// Typed and submitted at this wall-clock ms.
    Typed { at_ms: u64 },
    /// No readiness signal within the budget; nothing was typed.
    NotReady,
    /// The Session ended before the agent was ready.
    SessionEnded,
    /// The instructions could not be typed.
    Failed(String),
    /// No helper is typing and none reported: the Host restarted while the
    /// Run was starting.
    Interrupted,
}

/// The agent's activity, from its Session's row.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentActivity {
    pub status: AgentStatus,
    /// Wall-clock ms of the program's last non-idle report.
    pub working_at_ms: Option<u64>,
    /// Wall-clock ms of the latest completion evidence (a program's done or
    /// error report, a Stop hook).
    pub finished_at_ms: Option<u64>,
    /// The program's summary from its finished report, with the report's ms.
    pub program_reply: Option<(String, u64)>,
    /// The last Stop hook's final reply, with when the Host received it.
    pub hook_reply: Option<(String, u64)>,
}

impl AgentActivity {
    /// What a Session's row says, as the worker rebuilt it this rescan.
    /// `completed_at` is the row's completion evidence (`SessionRow::
    /// completed_at`); `hook_reply` the last Stop reply the worker received.
    pub fn from_row(
        row: &crate::sessions::SessionRow,
        completed_at: Option<u64>,
        hook_reply: Option<(&str, u64)>,
    ) -> Self {
        use crate::sessions::{Status, StatusSource};
        let status = match (row.running, row.status, row.status_source) {
            (false, _, _) => AgentStatus::Silent,
            (true, Status::Attention, _) => AgentStatus::Attention,
            (true, _, StatusSource::None) => AgentStatus::Silent,
            (true, Status::Busy, _) => AgentStatus::Working,
            (true, Status::Idle, _) => AgentStatus::Idle,
            (true, Status::Starting | Status::Exited, _) => AgentStatus::Silent,
        };
        let program = row.program_status.as_ref().filter(|_| row.running);
        Self {
            status,
            working_at_ms: program.and_then(|program| program.last_non_idle_at),
            finished_at_ms: program
                .and_then(|program| program.last_finished_at)
                .max(completed_at),
            program_reply: program
                .filter(|program| program.state.is_finished())
                .and_then(|program| Some((program.msg.clone()?, program.last_finished_at?))),
            hook_reply: hook_reply.map(|(text, at)| (text.to_owned(), at)),
        }
    }
}

/// An activity status that some tier actually reported.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum AgentStatus {
    Working,
    Idle,
    Attention,
    /// No tier has spoken (the default idle), or no row at all.
    #[default]
    Silent,
}

/// The agent Run's next line, if this observation changes it. `run` is in
/// progress (`running` or `needs_you`).
pub fn advance(
    run: &ScheduleRun,
    observation: &RunObservation,
    now_ms: u64,
) -> Option<ScheduleRun> {
    match observation {
        RunObservation::Exited(code) => Some(ended(
            run,
            RunStatus::Failed,
            Some(*code),
            Some(format!(
                "the agent exited with status {code} before it was done"
            )),
            now_ms,
        )),
        RunObservation::Agent(agent) => match run.phase {
            Some(RunPhase::Launching | RunPhase::WaitingReady) => agent
                .delivery
                .as_ref()
                .and_then(|d| delivered(run, d, now_ms)),
            Some(RunPhase::Prompted | RunPhase::Working) => follow(run, agent, now_ms),
            Some(RunPhase::Unknown) | None => None,
        },
        lost => super::step::session_lost(lost)
            .map(|reason| ended(run, RunStatus::Failed, None, Some(reason), now_ms)),
    }
}

/// While the agent starts: what the helper typing its instructions said.
fn delivered(run: &ScheduleRun, delivery: &Delivery, now_ms: u64) -> Option<ScheduleRun> {
    let failed = |reason: String| Some(ended(run, RunStatus::Failed, None, Some(reason), now_ms));
    match delivery {
        Delivery::Waiting => (run.phase != Some(RunPhase::WaitingReady)).then(|| ScheduleRun {
            phase: Some(RunPhase::WaitingReady),
            ..run.clone()
        }),
        Delivery::Typed { at_ms } => Some(ScheduleRun {
            phase: Some(RunPhase::Prompted),
            prompted_at_ms: Some(*at_ms),
            ..run.clone()
        }),
        Delivery::NotReady => Some(ended(
            run,
            RunStatus::FailedToStart,
            None,
            Some(
                "the agent showed no sign of being ready, so its instructions were not typed; \
                 its Session is left open"
                    .into(),
            ),
            now_ms,
        )),
        Delivery::SessionEnded => failed("the Session ended before the agent was ready".into()),
        Delivery::Failed(error) => failed(format!("its instructions could not be typed: {error}")),
        Delivery::Interrupted => failed("the Host restarted before the agent was ready".into()),
    }
}

/// After the paste: the first working signal is `working`; the first idle or
/// done edge after one is `done`; a question, or no working signal in time,
/// is `needs_you`.
fn follow(run: &ScheduleRun, agent: &AgentObservation, now_ms: u64) -> Option<ScheduleRun> {
    let activity = &agent.activity;
    let prompted_at = run.prompted_at_ms.or(run.started_at_ms).unwrap_or(0);
    let since_paste = |at: Option<u64>| at.is_some_and(|at| at >= prompted_at);
    let finished = since_paste(activity.finished_at_ms);
    let worked = run.phase == Some(RunPhase::Working)
        || matches!(
            activity.status,
            AgentStatus::Working | AgentStatus::Attention
        )
        || since_paste(activity.working_at_ms)
        || finished;
    if worked && (finished || activity.status == AgentStatus::Idle) {
        return Some(ScheduleRun {
            snippet: reply_since(activity, prompted_at),
            phase: Some(RunPhase::Working),
            ..ended(run, RunStatus::Done, None, None, now_ms)
        });
    }
    if activity.status == AgentStatus::Attention && run.status != RunStatus::NeedsYou {
        return Some(ScheduleRun {
            status: RunStatus::NeedsYou,
            phase: Some(RunPhase::Working),
            reason: Some("the agent is waiting for an answer".into()),
            ..run.clone()
        });
    }
    if worked && run.phase != Some(RunPhase::Working) {
        return Some(ScheduleRun {
            phase: Some(RunPhase::Working),
            ..run.clone()
        });
    }
    let silent_too_long = now_ms.saturating_sub(prompted_at) > agent.working_timeout_ms;
    (!worked && run.status == RunStatus::Running && silent_too_long).then(|| ScheduleRun {
        status: RunStatus::NeedsYou,
        reason: Some(format!(
            "the agent showed no working signal within {} s of its instructions",
            agent.working_timeout_ms / 1000
        )),
        ..run.clone()
    })
}

/// The turn's reply: the program's own summary, else the Stop hook's final
/// reply, either only from after the paste.
fn reply_since(activity: &AgentActivity, prompted_at: u64) -> Option<String> {
    let after = |reply: &Option<(String, u64)>| {
        reply
            .as_ref()
            .filter(|(_, at)| *at >= prompted_at)
            .map(|(text, _)| text.clone())
    };
    crate::completion_snippet::finished_body(
        after(&activity.program_reply).as_deref(),
        after(&activity.hook_reply).as_deref(),
    )
}

/// The Run's final line.
fn ended(
    run: &ScheduleRun,
    status: RunStatus,
    exit_code: Option<i32>,
    reason: Option<String>,
    now_ms: u64,
) -> ScheduleRun {
    ScheduleRun {
        status,
        exit_code,
        reason,
        ended_at_ms: Some(now_ms),
        ..run.clone()
    }
}

#[cfg(test)]
mod tests;
