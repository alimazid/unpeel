//! Fork-only: the Host notices a Worker's lifecycle and the watchdog queue
//! for its Router. Each is `about` the Worker and carries its label; wake
//! notices are pasted, ride-along ones wait for the next wake batch (§17.2).
//! The Router's Worker cards read a Finished notice by its exact shape
//! (`supervision_mcp/workers/cards.rs`): a Host `lifecycle` item about the
//! Worker, status [`FINISHED_STATUS`], the reply as its body.

use unpeel_core::session_inbox::{ItemKind, NewItem, Priority, Sender};

use super::watchdog::Alarm;
use crate::sessions::{SessionRow, Status};

/// Must equal `supervision_mcp::workers::cards::FINISHED_STATUS`.
pub const FINISHED_STATUS: &str = "finished";
pub const NEEDS_INPUT_STATUS: &str = "needs_input";
pub const EXITED_STATUS: &str = "exited";
pub const STARTED_STATUS: &str = "started";

/// Who a Worker's turn answers to, as far as the Host can tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnCause {
    /// A Host paste or Router write came just before it or during it, nobody
    /// saw it start, or it follows such a turn: its reply may be what the
    /// Router is waiting for.
    HostOrUnseen,
    /// The user typed into the Worker just before it or during it: its reply
    /// was for the user.
    UserTyped,
    /// Seen starting from idle with neither: a timer, a background task, a
    /// prompt from outside the terminal.
    Unprompted,
}

impl TurnCause {
    /// A turn nobody prompted waits for the next wake batch.
    fn priority(self) -> Priority {
        match self {
            Self::HostOrUnseen | Self::UserTyped => Priority::Wake,
            Self::Unprompted => Priority::RideAlong,
        }
    }
}

/// A Worker finished a turn. `reply` is its final reply (the snippet the
/// user's notification would have shown).
pub fn finished(
    row: &SessionRow,
    reply: Option<&str>,
    cause: TurnCause,
    stamp: Option<u64>,
) -> NewItem {
    let summary = match cause {
        TurnCause::HostOrUnseen => format!("{} finished.", name(row)),
        TurnCause::UserTyped => format!(
            "{} finished after the user talked to it directly; its reply was for the user, \
             not a report to you.",
            name(row)
        ),
        TurnCause::Unprompted => format!(
            "{} finished a turn neither you nor the user's typing started (a timer, a \
             background task, or a prompt from outside the terminal).",
            name(row)
        ),
    };
    NewItem {
        dedupe_key: stamp.map(|stamp| format!("fin:{}:{stamp}", row.id)),
        ..lifecycle(row, FINISHED_STATUS, cause.priority(), summary, reply)
    }
}

/// A Worker only its screen speaks for went idle after a turn. The screen
/// tier never makes a Finished edge, so this best guess stands in for one,
/// marked as such; there is no reply to carry. Once per turn.
pub fn screen_finished(row: &SessionRow, turn_started_at: u64, cause: TurnCause) -> NewItem {
    let summary = format!(
        "{} finished (screen-detected: no reply was captured; read its screen for the result).",
        name(row)
    );
    NewItem {
        dedupe_key: Some(format!("fin:{}:screen:{turn_started_at}", row.id)),
        ..lifecycle(row, FINISHED_STATUS, cause.priority(), summary, None)
    }
}

/// A Worker waits on a prompt or a menu.
pub fn needs_input(row: &SessionRow) -> NewItem {
    let program = row.program_status.as_ref();
    let what = program
        .and_then(|program| program.kind)
        .map_or(String::new(), |kind| format!(" ({} prompt)", kind.as_str()));
    let summary = format!("{} is waiting for input{what}.", name(row));
    let detail = program.and_then(|program| program.msg.as_deref());
    lifecycle(row, NEEDS_INPUT_STATUS, Priority::Wake, summary, detail)
}

/// A Worker started (only when `supervisor_notify_started`).
pub fn started(row: &SessionRow) -> NewItem {
    let summary = format!("{} started.", name(row));
    lifecycle(row, STARTED_STATUS, Priority::RideAlong, summary, None)
}

/// A Worker's process ended. An exit with a failing code, or while it was
/// busy or waiting, is the watchdog's `exited_unexpectedly` and wakes the
/// Router; a clean exit rides along. One item either way, deduped on the
/// exit itself so a Host restart never repeats it.
pub fn exited(row: &SessionRow, code: Option<i32>, before: Option<Status>, at: u64) -> NewItem {
    let while_doing = match before {
        Some(Status::Busy | Status::Starting) => " while busy",
        Some(Status::Attention) => " while waiting for input",
        _ => "",
    };
    let code_text = code.map_or(String::new(), |code| format!(" with code {code}"));
    let unexpected = code.is_some_and(|code| code != 0) || !while_doing.is_empty();
    let dedupe_key = Some(format!("exit:{}:{at}", row.id));
    if unexpected {
        let summary = format!("{} exited unexpectedly{code_text}{while_doing}.", name(row));
        return NewItem {
            kind: ItemKind::Watchdog,
            dedupe_key,
            ..lifecycle(
                row,
                super::watchdog::Rule::ExitedUnexpectedly.word(),
                Priority::Wake,
                summary,
                None,
            )
        };
    }
    let summary = format!("{} exited{code_text}.", name(row));
    NewItem {
        dedupe_key,
        ..lifecycle(row, EXITED_STATUS, Priority::RideAlong, summary, None)
    }
}

/// A watchdog alarm, once per episode (`wd:<worker>:<rule>:<episode>`).
pub fn alarm(row: &SessionRow, alarm: &Alarm) -> NewItem {
    let summary = format!("{} {}", name(row), alarm.text());
    NewItem {
        kind: ItemKind::Watchdog,
        dedupe_key: Some(format!(
            "wd:{}:{}:{}",
            row.id,
            alarm.rule.word(),
            alarm.episode
        )),
        ..lifecycle(row, alarm.rule.word(), Priority::Wake, summary, None)
    }
}

fn lifecycle(
    row: &SessionRow,
    status: &str,
    priority: Priority,
    summary: String,
    body: Option<&str>,
) -> NewItem {
    NewItem {
        sender: Sender::Host,
        kind: ItemKind::Lifecycle,
        priority,
        about: Some(row.id.clone()),
        status: Some(status.to_owned()),
        label: Some(row.label.trim().to_owned()).filter(|label| !label.is_empty()),
        summary,
        body: body.unwrap_or_default().to_owned(),
        dedupe_key: None,
    }
}

/// `"fix-login"`, or the id for an unlabeled Worker.
fn name(row: &SessionRow) -> String {
    match row.label.trim() {
        "" => format!("Worker id:{}", row.id),
        label => format!("\"{label}\""),
    }
}

/// `45 s`, `5 min`, `2 h 10 min`.
pub fn duration(ms: u64) -> String {
    let seconds = ms / 1_000;
    match seconds {
        0..=59 => format!("{seconds} s"),
        60..=3_599 => format!("{} min", seconds / 60),
        _ if (seconds / 60).is_multiple_of(60) => format!("{} h", seconds / 3_600),
        _ => format!("{} h {} min", seconds / 3_600, (seconds / 60) % 60),
    }
}
