//! Fork-only (#64, ADR 0012): the Host compacts a Worker whose context is
//! `supervisor_compact_percent` full when one of its turns ends. The figure
//! is the one Claude Code's status line shows, read from the Worker's
//! transcript against its model's window from the runtime package; a model
//! the package names no window for is never compacted. It types `/compact`
//! while the prompt cache is still warm, at most [`WARM_MS`] after the turn
//! ended, under the PTY core's typing and draft guard (ADR 0011), and only
//! into an idle Worker with no menu on screen, no Inbox items waiting, and
//! no Router write a moment before. A miss waits for the next turn end.
//!
//! The compaction is a turn of its own (7501 working, then done), which the
//! Worker alerts would report as a finish or a quiet end; they ask
//! [`CompactionView`] and stay silent for it. The Router hears one
//! ride-along notice instead.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use unpeel_core::session_inbox::{NewItem, Store};
use unpeel_core::session_input::Refusal;
use unpeel_core::transcripts::ContextReading;

use super::notices;
use super::worker_alerts::{DrainView, SELF_CAUSED_MS};
use crate::sessions::{SessionRow, Status};

/// A turn end this old is past a 5-minute prompt cache: compacting then
/// would re-read the whole context uncached.
pub const WARM_MS: u64 = 5 * 60_000;
/// A compaction goes busy within this long of `/compact`, or it never
/// started.
pub const START_MS: u64 = 30_000;
/// The longest a compaction may run before its claim on the Worker's turn
/// lapses (a 1M context took ~75 s on 2026-11-08).
const MAX_RUN_MS: u64 = 15 * 60_000;
/// How long after a compaction ends its claim is kept, so the Worker
/// alerts' quiet-end check one step later still sees it.
const CLAIM_GRACE_MS: u64 = 10_000;
/// A refused send tries again this often.
const RETRY_MS: u64 = 2_000;
/// A paste the drain started this recently may be about to start a turn.
const PASTE_QUIET_MS: u64 = 5_000;
/// Between `/compact` and Enter, so the TUI takes them as typed keys.
const KEY_SETTLE: Duration = Duration::from_millis(100);
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// What compaction reads and does outside its own state: the real Host in
/// [`HostCompaction`], a fake in tests.
pub trait CompactionHost: Send + Sync {
    /// How full the Session's context is, from its transcript.
    fn reading(&self, session_id: &str) -> Option<ContextReading>;
    /// Manifest facts the rows do not carry.
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts>;
    /// Type `/compact` and Enter, unless the user typed at or after `since`
    /// or has a draft on the line.
    fn send(&self, session_id: &str, since: u64) -> Result<SendOutcome, String>;
    /// A notice was queued in some Inbox.
    fn announce(&self);
}

/// How a send went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    Submitted,
    /// Refused before anything was written.
    NotTyped(Refusal),
    /// `/compact` went in, then the user typed: it waits on their line and
    /// Enter was not pressed.
    Unsubmitted,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalFacts {
    /// A select menu is on screen: it would take the keys.
    pub menu_prompt: bool,
    /// The PTY core refuses writes over a draft (ADR 0011). An older core
    /// would type into a half-written prompt.
    pub draft_guard: bool,
}

/// What the Worker alerts ask about the Host's compactions.
pub trait CompactionView {
    /// When the Host sent the compaction that a turn started at
    /// `started_at` is, if it is one.
    fn compaction_sent_at(&self, session_id: &str, started_at: u64) -> Option<u64>;
}

/// The running Router's Workers and the setting, from the Worker alerts'
/// last step.
#[derive(Debug, Clone, Copy)]
pub struct Scope<'a> {
    pub router: &'a str,
    pub workers: &'a HashSet<String>,
    /// `supervisor_compact_percent`; `0`: off.
    pub percent: u8,
}

/// One Worker between steps.
#[derive(Debug)]
struct Worker {
    /// A finished turn not decided on yet: when it ended.
    ended_at: Option<u64>,
    /// Its reading, over the threshold, once taken.
    due: Option<Due>,
    /// Cleared by a compaction until a reading is under the threshold, so a
    /// compaction that left the context full is not repeated every turn.
    armed: bool,
    sent: Option<Sent>,
    retry_at: u64,
    /// The model last reported as having no known window.
    told_unknown: Option<String>,
}

impl Default for Worker {
    fn default() -> Self {
        Self {
            ended_at: None,
            due: None,
            armed: true,
            sent: None,
            retry_at: 0,
            told_unknown: None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Due {
    percent: u8,
    tokens: u64,
}

/// The Host's compaction in progress: it owns the turn it starts.
#[derive(Debug, Clone, Copy)]
struct Sent {
    at: u64,
    busy_seen: bool,
    ended_at: Option<u64>,
}

impl Sent {
    fn owns(&self, started_at: u64) -> bool {
        started_at >= self.at
            && started_at <= self.at + START_MS
            && self.ended_at.is_none_or(|ended| started_at <= ended)
    }

    fn lapsed(&self, now: u64) -> bool {
        let never_started = !self.busy_seen && now > self.at + START_MS;
        let ended = self
            .ended_at
            .is_some_and(|ended| now > ended + CLAIM_GRACE_MS);
        never_started || ended || now > self.at + MAX_RUN_MS
    }
}

pub struct Compaction {
    store: Store,
    io: Arc<dyn CompactionHost>,
    workers: HashMap<String, Worker>,
}

impl Default for Compaction {
    fn default() -> Self {
        Self::new(Store::home(), Arc::new(HostCompaction))
    }
}

impl std::fmt::Debug for Compaction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Compaction")
            .field("workers", &self.workers)
            .finish_non_exhaustive()
    }
}

impl CompactionView for Compaction {
    fn compaction_sent_at(&self, session_id: &str, started_at: u64) -> Option<u64> {
        let sent = self.workers.get(session_id)?.sent?;
        sent.owns(started_at).then_some(sent.at)
    }
}

impl Compaction {
    pub fn new(store: Store, io: Arc<dyn CompactionHost>) -> Self {
        Self {
            store,
            io,
            workers: HashMap::new(),
        }
    }

    /// A Worker's Finished edge. The first one after the Host's `/compact`
    /// ends that compaction; any other is a turn end to decide on.
    pub fn turn_finished(&mut self, row: &SessionRow, now: u64) {
        if !row.is_worker {
            return;
        }
        let worker = self.workers.entry(row.id.clone()).or_default();
        match worker.sent.as_mut() {
            Some(sent) if sent.ended_at.is_none() => sent.ended_at = Some(now),
            _ => {
                worker.ended_at = Some(now);
                worker.due = None;
            }
        }
    }

    /// Once per rescan, after the Worker alerts and the Inbox drain.
    pub fn step(
        &mut self,
        rows: &[SessionRow],
        scope: Option<Scope>,
        drain: &dyn DrainView,
        now: u64,
    ) {
        let Some(scope) = scope else {
            self.workers.clear();
            return;
        };
        self.workers.retain(|id, _| scope.workers.contains(id));
        for row in rows
            .iter()
            .filter(|row| row.running && scope.workers.contains(&row.id))
        {
            let worker = self.workers.entry(row.id.clone()).or_default();
            observe_sent(worker, row, now);
            let Some(ended_at) = worker.ended_at else {
                continue;
            };
            if scope.percent == 0 || now > ended_at + WARM_MS {
                drop_turn(worker);
                continue;
            }
            if worker.due.is_none() && !self.take_reading(scope, row, now) {
                continue;
            }
            self.try_send(scope, row, drain, now);
        }
    }

    /// The reading for a just-finished turn. `true`: it is due.
    fn take_reading(&mut self, scope: Scope, row: &SessionRow, now: u64) -> bool {
        let reading = self.io.reading(&row.id);
        let Some(worker) = self.workers.get_mut(&row.id) else {
            return false;
        };
        let Some(reading) = reading else {
            drop_turn(worker);
            return false;
        };
        let Some(percent) = reading.percent() else {
            let model = reading
                .model
                .filter(|model| worker.told_unknown.as_ref() != Some(model));
            drop_turn(worker);
            if let Some(model) = model {
                worker.told_unknown = Some(model.clone());
                self.enqueue(
                    scope.router,
                    notices::unknown_context_window(row, &model),
                    now,
                );
            }
            return false;
        };
        if percent < scope.percent {
            worker.armed = true;
            drop_turn(worker);
            return false;
        }
        if !worker.armed {
            drop_turn(worker);
            return false;
        }
        worker.due = Some(Due {
            percent,
            tokens: reading.tokens,
        });
        true
    }

    fn try_send(&mut self, scope: Scope, row: &SessionRow, drain: &dyn DrainView, now: u64) {
        let touched = self.store.router_touched_at(&row.id);
        let terminal = self.io.terminal(&row.id);
        let Some(worker) = self.workers.get_mut(&row.id) else {
            return;
        };
        let Some(due) = worker.due else {
            return;
        };
        match readiness(worker, row, terminal, touched, drain, now) {
            Readiness::Wait => return,
            Readiness::Never(why) => {
                crate::tracelog::trace(
                    "supervisor",
                    &format!("not compacting Worker {}: {why}", row.id),
                );
                drop_turn(worker);
                return;
            }
            Readiness::Ready => {}
        }
        match self
            .io
            .send(&row.id, unpeel_core::agent_send::typing_window_start(now))
        {
            Ok(SendOutcome::Submitted) => {
                drop_turn(worker);
                worker.armed = false;
                worker.sent = Some(Sent {
                    at: now,
                    busy_seen: false,
                    ended_at: None,
                });
                let notice = notices::compacted(row, due.percent, due.tokens, scope.percent, now);
                self.enqueue(scope.router, notice, now);
            }
            Ok(SendOutcome::NotTyped(_)) => worker.retry_at = now + RETRY_MS,
            Ok(SendOutcome::Unsubmitted) => {
                crate::tracelog::trace(
                    "supervisor",
                    &format!(
                        "Worker {}: the user typed after /compact; not submitted",
                        row.id
                    ),
                );
                drop_turn(worker);
            }
            Err(error) => {
                crate::tracelog::trace(
                    "supervisor",
                    &format!("compacting Worker {} failed: {error}", row.id),
                );
                drop_turn(worker);
            }
        }
    }

    fn enqueue(&self, router: &str, notice: NewItem, now: u64) {
        match self.store.enqueue(router, notice, now) {
            Ok(_) => self.io.announce(),
            Err(error) => crate::tracelog::trace(
                "supervisor",
                &format!("compaction notice for Router {router} not queued: {error}"),
            ),
        }
    }
}

enum Readiness {
    Ready,
    /// Not now; the next step looks again.
    Wait,
    /// Not for this turn.
    Never(&'static str),
}

fn readiness(
    worker: &Worker,
    row: &SessionRow,
    terminal: Option<TerminalFacts>,
    touched: Option<u64>,
    drain: &dyn DrainView,
    now: u64,
) -> Readiness {
    let Some(terminal) = terminal else {
        return Readiness::Never("no manifest");
    };
    if !terminal.draft_guard {
        return Readiness::Never("its PTY core predates the draft guard");
    }
    let router_wrote = touched.is_some_and(|at| at + SELF_CAUSED_MS >= now);
    let paste_landing = drain.pasted_between(&row.id, now.saturating_sub(PASTE_QUIET_MS), now);
    if row.status != Status::Idle
        || terminal.menu_prompt
        || worker.sent.is_some()
        || now < worker.retry_at
        || router_wrote
        || paste_landing
        || drain.has_pending(&row.id)
    {
        return Readiness::Wait;
    }
    Readiness::Ready
}

/// The compaction in flight: its busy start, its quiet end (a Finished
/// edge ends it first, in `turn_finished`), and its claim lapsing.
fn observe_sent(worker: &mut Worker, row: &SessionRow, now: u64) {
    let Some(sent) = worker.sent.as_mut() else {
        return;
    };
    let active = matches!(row.status, Status::Busy | Status::Attention);
    if active && sent.ended_at.is_none() {
        sent.busy_seen = true;
    } else if !active && sent.busy_seen && sent.ended_at.is_none() {
        sent.ended_at = Some(now);
    }
    if sent.lapsed(now) {
        if !sent.busy_seen {
            crate::tracelog::trace(
                "supervisor",
                &format!("Worker {}'s compaction never started", row.id),
            );
        }
        worker.sent = None;
    }
}

fn drop_turn(worker: &mut Worker) {
    worker.ended_at = None;
    worker.due = None;
}

/// The real Host: transcripts, manifests, the PTY core's guarded write.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostCompaction;

impl CompactionHost for HostCompaction {
    fn reading(&self, session_id: &str) -> Option<ContextReading> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        unpeel_core::transcripts::read_context(&manifest)
    }

    fn terminal(&self, session_id: &str) -> Option<TerminalFacts> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        Some(TerminalFacts {
            menu_prompt: manifest.menu_prompt_active,
            draft_guard: manifest.draft_guard,
        })
    }

    fn send(&self, session_id: &str, since: u64) -> Result<SendOutcome, String> {
        let write = |keys: &str| {
            unpeel_core::session_input::write_key_unless_user_is_typing_within(
                session_id,
                keys,
                since,
                WRITE_TIMEOUT,
            )
        };
        if let Some(refusal) = write("/compact")? {
            return Ok(SendOutcome::NotTyped(refusal));
        }
        std::thread::sleep(KEY_SETTLE);
        Ok(match write("\r")? {
            None => SendOutcome::Submitted,
            Some(_) => SendOutcome::Unsubmitted,
        })
    }

    fn announce(&self) {
        unpeel_core::supervision::announce_markers();
    }
}

#[cfg(test)]
mod tests;
