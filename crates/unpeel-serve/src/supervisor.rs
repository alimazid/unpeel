//! Fork-only: the Host side of the Super Agent. The workspace worker owns
//! one [`Supervisor`] and calls it from a few one-line `// Fork-only` hunks in
//! `driver.rs`: every accepted hook event, every lifecycle edge before it
//! becomes a user notification, once per rescan, and before the auto-stop
//! sweep. Until a Router exists every method leaves the worker's behavior
//! exactly as it was.

use std::borrow::Cow;
use std::time::{SystemTime, UNIX_EPOCH};

use unpeel_core::activity_log::ActivityLogKind;

use crate::sessions::{SessionRow, SidebarModel};

#[derive(Debug, Default)]
pub struct Supervisor {}

impl Supervisor {
    /// One accepted hook event for `session_id` (canonical name, as
    /// `activity::normalize_event_name` returns it), received at `at_ms`.
    pub fn observe_hook(&mut self, session_id: &str, canonical_event: &str, at_ms: u64) {
        let _ = (session_id, canonical_event, at_ms);
    }

    /// A lifecycle edge of `row` about to notify the user. `true` takes it
    /// for the Router instead: the worker then sends no notification and
    /// marks the row read, so an unread Worker never pins itself in the
    /// sidebar. `body` is the finished snippet, already taken.
    pub fn divert_edge(
        &mut self,
        row: &SessionRow,
        kind: ActivityLogKind,
        body: Option<&str>,
        now_ms: u64,
    ) -> bool {
        let _ = (row, kind, body, now_ms);
        false
    }

    /// Once per rescan, after the keep-limit sweep.
    pub fn step(&mut self, model: &SidebarModel, now_ms: u64) {
        let _ = (model, now_ms);
    }

    /// The rows the auto-stop sweep may consider.
    pub fn auto_stop_rows<'a>(&self, rows: &'a [SessionRow]) -> Cow<'a, [SessionRow]> {
        Cow::Borrowed(rows)
    }
}

/// Keep-limit rank of each row in `stopped` (indices into `rows`, display
/// order): the user's stopped rows first, then Workers, each in display
/// order. Ranks below the window are kept, so Workers expire first.
pub fn stopped_keep_ranks(rows: &[SessionRow], stopped: &[usize]) -> Vec<usize> {
    let users = stopped
        .iter()
        .filter(|&&index| !rows[index].is_worker)
        .count();
    stopped
        .iter()
        .scan((0, users), |(next_user, next_worker), &index| {
            let next = if rows[index].is_worker {
                next_worker
            } else {
                next_user
            };
            let rank = *next;
            *next += 1;
            Some(rank)
        })
        .collect()
}

/// A hook receipt in unix ms.
pub fn unix_ms(at: SystemTime) -> u64 {
    at.duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}
