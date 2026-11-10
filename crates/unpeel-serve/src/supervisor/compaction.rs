//! Fork-only (#64, ADR 0012): the Host compacts a Worker whose context is
//! `supervisor_compact_percent` full when one of its turns ends. The figure
//! is the agent's own (what Claude Code's status line or Codex's footer
//! shows, or Codewhale's local estimate, #68), read from the Worker's
//! transcript against its model's window from the runtime package; a model
//! the package names no window for is never compacted. It types the
//! package's compact command while the prompt cache is still warm, at most
//! [`WARM_MS`] after the turn ended, under the PTY core's typing and draft
//! guard (ADR 0011), off the tick thread, and only into an idle Worker with
//! no menu on screen, no Inbox items waiting, no Router write a moment
//! before, and writing to other sessions not set to Deny. A miss waits for
//! the next turn end. Scheduled Runs are never compacted.
//!
//! The compaction is a turn of its own (7501 working, then done), which the
//! Worker alerts would report as a finish or a quiet end; they ask
//! [`CompactionView`] and stay silent for it. The Router hears one
//! ride-along notice instead, once the compaction has started. A Codewhale
//! compaction reports no busy, so it is never seen to start and nobody
//! hears of it.

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::time::Duration;

use unpeel_core::session_inbox::{NewItem, Store};
use unpeel_core::transcripts::ContextReading;

use super::notices;
use super::worker_alerts::{DrainView, SELF_CAUSED_MS};
use crate::run_sessions::is_run_session;
use crate::sessions::{SessionRow, Status};

/// A turn end this old is past a 5-minute prompt cache: compacting then
/// would re-read the whole context uncached.
pub const WARM_MS: u64 = 5 * 60_000;
/// A compaction goes busy within this long of the command, or it never
/// started.
pub const START_MS: u64 = 30_000;
/// The longest a compaction may run before its claim on the Worker's turn
/// lapses (a 1M context took ~75 s on 2026-11-08).
const MAX_RUN_MS: u64 = 15 * 60_000;
/// How long after a compaction ends its claim is kept, so the Worker
/// alerts' quiet-end check one step later still sees it.
const CLAIM_GRACE_MS: u64 = 10_000;
/// A refused send tries again this often, while the cache is warm.
const RETRY_MS: u64 = 2_000;
/// A paste the drain started this recently may be about to start a turn.
const PASTE_QUIET_MS: u64 = 5_000;
/// Between the command and Enter, so the TUI takes them as typed keys.
const KEY_SETTLE: Duration = Duration::from_millis(100);
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// What compaction reads and does outside its own state: the real Host in
/// [`HostCompaction`], a fake in tests.
pub trait CompactionHost: Send + Sync {
    /// How full the Session's context is, from its transcript.
    fn reading(&self, session_id: &str) -> Option<ContextReading>;
    /// Manifest facts the rows do not carry.
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts>;
    /// App-wide "Writing to other sessions: Deny".
    fn writes_denied(&self) -> bool;
    /// Type `command` and Enter, unless the user typed at or after `since`
    /// or has a draft on the line. Runs off the tick thread.
    fn send(&self, session_id: &str, command: &str, since: u64) -> Result<SendOutcome, String>;
    /// A notice was queued in some Inbox.
    fn announce(&self);
}

/// How a send went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    Submitted,
    /// Refused before anything was written (typing or a draft).
    NotTyped,
    /// The command went in, then the user typed: it waits on their line and
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
    /// Cleared by a compaction that started, until a reading is under the
    /// threshold, so one that left the context full is not repeated every
    /// turn.
    armed: bool,
    sent: Option<Sent>,
    retry_at: u64,
    /// The core refused this turn's send: the next try re-checks everything
    /// and gives the turn up on the first precondition that fails.
    retrying: bool,
    /// Models already reported as having no known window.
    told_unknown: HashSet<String>,
}

impl Default for Worker {
    fn default() -> Self {
        Self {
            ended_at: None,
            due: None,
            armed: true,
            sent: None,
            retry_at: 0,
            retrying: false,
            told_unknown: HashSet::new(),
        }
    }
}

#[derive(Debug, Clone)]
struct Due {
    percent: u8,
    tokens: u64,
    command: String,
}

/// The Host's compaction from the send on: it owns the turn it starts.
#[derive(Debug, Clone)]
struct Sent {
    at: u64,
    due: Due,
    /// The send thread reported the command and Enter written.
    typed: bool,
    busy_seen: bool,
    ended_at: Option<u64>,
    /// The Router's notice is queued.
    told: bool,
}

impl Sent {
    fn owns(&self, started_at: u64) -> bool {
        started_at >= self.at
            && started_at <= self.at + START_MS
            && self.ended_at.is_none_or(|ended| started_at <= ended)
    }

    fn started(&self) -> bool {
        self.typed && (self.busy_seen || self.ended_at.is_some())
    }

    fn lapsed(&self, now: u64) -> bool {
        let never_started = !self.started() && now > self.at + START_MS;
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
    outcomes_tx: Outcomes,
    outcomes_rx: Receiver<(String, Result<SendOutcome, String>)>,
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
        let sent = self.workers.get(session_id)?.sent.as_ref()?;
        sent.owns(started_at).then_some(sent.at)
    }
}

impl Compaction {
    pub fn new(store: Store, io: Arc<dyn CompactionHost>) -> Self {
        let (outcomes_tx, outcomes_rx) = mpsc::channel();
        Self {
            store,
            io,
            workers: HashMap::new(),
            outcomes_tx,
            outcomes_rx,
        }
    }

    /// A Worker's Finished edge. The first one after the Host's command
    /// ends that compaction; any other is a turn end to decide on.
    pub fn turn_finished(&mut self, row: &SessionRow, now: u64) {
        if !row.is_worker || is_run_session(row) {
            return;
        }
        let worker = self.workers.entry(row.id.clone()).or_default();
        match worker.sent.as_mut() {
            Some(sent) if sent.ended_at.is_none() => sent.ended_at = Some(now),
            _ => {
                drop_turn(worker);
                worker.ended_at = Some(now);
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
        while let Ok((session_id, outcome)) = self.outcomes_rx.try_recv() {
            self.apply(&session_id, outcome, now);
        }
        let Some(scope) = scope else {
            // No Router: a compaction in flight keeps its claim until it
            // lapses, so a Router back from a restart does not hear it as
            // a finish.
            self.workers.retain(|_, worker| worker.sent.is_some());
            for row in rows {
                if let Some(worker) = self.workers.get_mut(&row.id) {
                    observe_sent(worker, row, now);
                }
            }
            return;
        };
        self.workers.retain(|id, _| scope.workers.contains(id));
        for row in rows
            .iter()
            .filter(|row| row.running && scope.workers.contains(&row.id) && !is_run_session(row))
        {
            self.step_worker(scope, row, drain, now);
        }
    }

    fn step_worker(&mut self, scope: Scope, row: &SessionRow, drain: &dyn DrainView, now: u64) {
        let worker = self.workers.entry(row.id.clone()).or_default();
        observe_sent(worker, row, now);
        if let Some(notice) = started_notice(worker, row, scope.percent) {
            self.enqueue(scope.router, notice, now);
        }
        let Some(worker) = self.workers.get_mut(&row.id) else {
            return;
        };
        let Some(ended_at) = worker.ended_at else {
            return;
        };
        if scope.percent == 0 || now > ended_at + WARM_MS {
            drop_turn(worker);
            return;
        }
        if worker.due.is_none() && !self.take_reading(scope, row, now) {
            return;
        }
        self.try_send(row, drain, now);
    }

    /// The reading for a just-finished turn. `true`: it is due.
    fn take_reading(&mut self, scope: Scope, row: &SessionRow, now: u64) -> bool {
        let reading = self.io.reading(&row.id);
        let Some(worker) = self.workers.get_mut(&row.id) else {
            return false;
        };
        let ended_at = worker.ended_at;
        drop_turn(worker);
        let Some(reading) = reading else {
            trace(&format!("no context reading for Worker {}", row.id));
            return false;
        };
        let Some(percent) = reading.percent() else {
            let model = reading
                .model
                .filter(|model| worker.told_unknown.insert(model.clone()));
            if let Some(model) = model {
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
            return false;
        }
        if !worker.armed {
            return false;
        }
        let Some(command) = reading.compact_command else {
            trace(&format!(
                "not compacting Worker {}: its runtime package names no compact command",
                row.id
            ));
            return false;
        };
        worker.ended_at = ended_at;
        worker.due = Some(Due {
            percent,
            tokens: reading.tokens,
            command,
        });
        true
    }

    fn try_send(&mut self, row: &SessionRow, drain: &dyn DrainView, now: u64) {
        let touched = self.store.router_touched_at(&row.id);
        let terminal = self.io.terminal(&row.id);
        let Some(worker) = self.workers.get_mut(&row.id) else {
            return;
        };
        let Some(due) = worker.due.clone() else {
            return;
        };
        let readiness = match readiness(worker, row, terminal, touched, drain, now) {
            // A retry's timer; every step until then still checks the rest.
            Readiness::Ready if now < worker.retry_at => Readiness::Wait,
            Readiness::Ready if self.io.writes_denied() => {
                Readiness::Never("writing to other sessions is set to Deny")
            }
            readiness => readiness,
        };
        match readiness {
            Readiness::Wait => {}
            Readiness::Never(why) => {
                trace(&format!("not compacting Worker {}: {why}", row.id));
                drop_turn(worker);
            }
            Readiness::Ready => {
                let since = unpeel_core::agent_send::typing_window_start(now);
                let send = (self.io.clone(), self.outcomes_tx.clone());
                if spawn_send(send, &row.id, &due.command, since) {
                    worker.sent = Some(Sent {
                        at: now,
                        due,
                        typed: false,
                        busy_seen: false,
                        ended_at: None,
                        told: false,
                    });
                } else {
                    worker.retrying = true;
                    worker.retry_at = now + RETRY_MS;
                }
            }
        }
    }

    fn apply(&mut self, id: &str, outcome: Result<SendOutcome, String>, now: u64) {
        let Some(worker) = self.workers.get_mut(id) else {
            return;
        };
        match outcome {
            Ok(SendOutcome::Submitted) => {
                if let Some(sent) = worker.sent.as_mut() {
                    sent.typed = true;
                }
                drop_turn(worker);
                return;
            }
            Ok(SendOutcome::NotTyped) => {
                worker.retrying = true;
                worker.retry_at = now + RETRY_MS;
            }
            Ok(SendOutcome::Unsubmitted) => {
                trace(&format!(
                    "Worker {id}: the user typed after the compact command; not submitted"
                ));
                drop_turn(worker);
            }
            Err(error) => {
                trace(&format!("compacting Worker {id} failed: {error}"));
                drop_turn(worker);
            }
        }
        worker.sent = None;
    }

    fn enqueue(&self, router: &str, notice: NewItem, now: u64) {
        match self.store.enqueue(router, notice, now) {
            Ok(_) => self.io.announce(),
            Err(error) => trace(&format!(
                "compaction notice for Router {router} not queued: {error}"
            )),
        }
    }

    /// Tests: wait for the send a step just started, then apply it.
    #[cfg(test)]
    fn settle_for_test(&mut self, now: u64) {
        let (session_id, outcome) = self
            .outcomes_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("a send thread reports back");
        self.apply(&session_id, outcome, now);
    }
}

enum Readiness {
    Ready,
    /// Not now; the next step looks again (never on a retry).
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
    if worker.retrying && changed_since_turn_end(worker, row, touched, drain, now) {
        return Readiness::Never("a retry found it changed since its turn ended");
    }
    let router_wrote = touched.is_some_and(|at| at + SELF_CAUSED_MS >= now);
    let paste_landing = drain.pasted_between(&row.id, now.saturating_sub(PASTE_QUIET_MS), now);
    let waiting = row.status != Status::Idle
        || terminal.menu_prompt
        || worker.sent.is_some()
        || router_wrote
        || paste_landing
        || drain.has_pending(&row.id);
    match (waiting, worker.retrying) {
        (false, _) => Readiness::Ready,
        (true, false) => Readiness::Wait,
        (true, true) => Readiness::Never("a retry found it no longer ready"),
    }
}

/// Since the turn ended: a Router write, a drain paste, or a program
/// report of another turn (one that came and went between two rescans).
fn changed_since_turn_end(
    worker: &Worker,
    row: &SessionRow,
    touched: Option<u64>,
    drain: &dyn DrainView,
    now: u64,
) -> bool {
    let Some(ended_at) = worker.ended_at else {
        return true;
    };
    let program_active = row
        .program_status
        .as_ref()
        .and_then(|program| program.last_non_idle_at);
    touched.is_some_and(|at| at > ended_at)
        || drain.pasted_between(&row.id, ended_at.saturating_add(1), now)
        || program_active.is_some_and(|at| at > ended_at)
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
        if !sent.started() {
            trace(&format!("Worker {}'s compaction never started", row.id));
        }
        worker.sent = None;
    }
}

/// The Router's notice, once the compaction has started: from then on it
/// is not repeated until a reading is under the threshold.
fn started_notice(worker: &mut Worker, row: &SessionRow, threshold: u8) -> Option<NewItem> {
    let sent = worker
        .sent
        .as_mut()
        .filter(|sent| sent.started() && !sent.told)?;
    sent.told = true;
    worker.armed = false;
    Some(notices::compacted(
        row,
        sent.due.percent,
        sent.due.tokens,
        threshold,
        sent.at,
    ))
}

type Outcomes = Sender<(String, Result<SendOutcome, String>)>;

/// The send, off the tick thread: two guarded writes and the pause between
/// them. Its outcome is applied at the next step.
fn spawn_send(
    (io, outcomes): (Arc<dyn CompactionHost>, Outcomes),
    id: &str,
    command: &str,
    since: u64,
) -> bool {
    let (session_id, command) = (id.to_owned(), command.to_owned());
    std::thread::Builder::new()
        .name("unpeel-compaction".into())
        .spawn(move || {
            let outcome = io.send(&session_id, &command, since);
            let _ = outcomes.send((session_id, outcome));
        })
        .is_ok()
}

fn drop_turn(worker: &mut Worker) {
    worker.ended_at = None;
    worker.due = None;
    worker.retrying = false;
}

fn trace(message: &str) {
    crate::tracelog::trace("supervisor", message);
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

    fn writes_denied(&self) -> bool {
        unpeel_core::supervision::config_and_write_deny().1
    }

    fn send(&self, session_id: &str, command: &str, since: u64) -> Result<SendOutcome, String> {
        let write = |keys: &str| {
            unpeel_core::session_input::write_key_unless_user_is_typing_within(
                session_id,
                keys,
                since,
                WRITE_TIMEOUT,
            )
        };
        if write(command)?.is_some() {
            return Ok(SendOutcome::NotTyped);
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
