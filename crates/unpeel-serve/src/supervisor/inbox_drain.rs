//! Fork-only: the Inbox drain. Stepped once per rescan, it decides per
//! target whether its pending items may be pasted (`inbox_rules`), keeps
//! the draft guard's baseline, runs at most one paste per target on its own
//! thread, and marks a batch delivered only once the target takes it — a
//! prompt-submit hook or a Busy edge after the paste. An unconfirmed batch
//! keeps its claim, so the next paste is the same batch marked
//! `(redelivery)`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use unpeel_core::session_inbox::{Batch, Hold, PendingStats, Store};
use unpeel_core::session_input::{GuardedPaste, Refusal};
use unpeel_core::supervision::SupervisorConfig;

use super::inbox_rules::{self, DraftFacts, Facts, HoldReason, Readiness, Timing};
use crate::sessions::{SessionRow, Status};

mod draft_guard;
mod host;
use draft_guard::{guarded_line, EmptyCheck, Guarded};
#[cfg(test)]
use host::cursor_line;
pub use host::HostTerminal;

/// A paste with no prompt submit or Busy edge this long after it is pasted
/// again, as a redelivery of the same batch.
pub const CONFIRM_TIMEOUT_MS: u64 = 30_000;
/// Pastes of one batch before it counts as delivered unconfirmed: a target
/// whose hooks never fire must not get the same batch every 30 s forever.
pub const MAX_PASTE_ATTEMPTS: u32 = 3;
/// A failed paste is retried (as a fresh batch) after this long.
pub const RETRY_MS: u64 = 10_000;
/// A suspected draft holding items this long notifies the user, once.
pub const DRAFT_NOTIFY_MS: u64 = 120_000;
/// Inbox GC runs this often.
const GC_INTERVAL_MS: u64 = 60_000;
const HOUR_MS: u64 = 3_600_000;

/// What the drain reads and does outside its own state: the real Host in
/// [`HostTerminal`], a fake in tests.
pub trait HostIo: Send + Sync {
    /// Manifest facts the rows do not carry; `None` without a manifest.
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts>;
    /// The line the cursor is on, from a quick viewport snapshot.
    fn cursor(&self, session_id: &str) -> Option<CursorLine>;
    /// Paste already-sanitized text and submit it, unless the user types
    /// at or after `since` (`session_input::paste_unless_typed`) or, with
    /// `unless_draft` (#69), has a draft on the line.
    fn paste(
        &self,
        session_id: &str,
        text: &str,
        since: u64,
        unless_draft: bool,
    ) -> Result<GuardedPaste, String>;
    /// Session ids that still have a manifest (Inbox GC).
    fn live_session_ids(&self) -> HashSet<String>;
    /// The supervisor's settings and the app-wide write policy, from one
    /// app-state read.
    fn settings(&self) -> Settings;
    /// Shared Inbox state changed (items delivered, a hold published, an
    /// Inbox collected): announce `SessionMarkers` on the state bus.
    fn announce(&self);
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalFacts {
    pub bracketed_paste: bool,
    pub screen_changed_at: Option<u64>,
    pub menu_prompt: bool,
    /// When the user last typed into the session; `None` from a session
    /// host that does not stamp it, or before anyone typed.
    pub last_input_at: Option<u64>,
    /// The PTY core refuses `unless_draft` writes over the user's draft
    /// (manifest `draft_guard`, ADR 0011). An older core writes them anyway.
    pub draft_guard: bool,
}

/// The draft guard's view of the input line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorLine {
    pub text: String,
    pub col: u16,
}

/// A user notification for the worker to deliver.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    pub session_id: String,
    pub body: String,
    pub kind: NoticeKind,
}

/// How the worker delivers a [`Notice`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoticeKind {
    /// An informational alert (a draft holding queued items).
    Alert,
    /// The Session waits on the user (an unanswered Worker prompt).
    NeedsInput,
}

/// Per-target state between steps.
#[derive(Debug, Default)]
struct Target {
    /// The current quiet idle period; dropped by the next Busy → Idle cycle.
    episode: Option<Episode>,
    in_flight: bool,
    /// When the paste in flight (or the last one) was started.
    spawned_at: Option<u64>,
    awaiting: Option<Awaiting>,
    retry_at: u64,
    /// Paste times within the last hour (the budget).
    pastes: VecDeque<u64>,
    published: Option<HoldReason>,
    /// The last baseline taken with nobody typing since the turn began:
    /// the agent's own empty prompt, kept across episodes.
    known_empty: Option<CursorLine>,
    /// The line read against `known_empty` after the latest typing, or the
    /// PTY core's refusal over a draft (#69); asked again only once the user
    /// types again.
    checked: Option<EmptyCheck>,
}

#[derive(Debug, Default)]
struct Episode {
    baseline: Option<CursorLine>,
    /// A paste found the line changed since the baseline: held until the
    /// next Busy → Idle cycle.
    line_changed: bool,
    draft_since: Option<u64>,
    notified: bool,
}

/// When a session's current turn began (#38).
#[derive(Debug, Clone, Copy)]
struct Turn {
    began_at: u64,
    /// Busy, Starting or Attention at the last step. A menu is part of the
    /// turn around it, never the start of one: keys that answer it are
    /// typing within the turn, and a menu over an idle prompt leaves the
    /// draft under it a draft.
    active: bool,
}

/// A pasted batch waiting for the target to take it.
#[derive(Debug)]
struct Awaiting {
    batch_id: String,
    pasted_at: u64,
}

/// A delivery thread's result.
#[derive(Debug)]
enum Outcome {
    /// `delivered`: a best guess, completed at once.
    Pasted {
        batch_id: String,
        pasted_at: u64,
        delivered: bool,
    },
    /// The line changed since the step looked, or the user typed.
    Draft,
    /// The PTY core refused the paste over a draft of the typing stamped
    /// at `typed_at` (#69).
    CoreDraft {
        typed_at: u64,
    },
    Failed(String),
    /// Nothing was left to claim.
    Empty,
}

pub struct Drain {
    store: Store,
    io: Arc<dyn HostIo>,
    targets: HashMap<String, Target>,
    outcomes_tx: Sender<(String, Outcome)>,
    outcomes_rx: Receiver<(String, Outcome)>,
    /// Latest `UserPromptSubmit` per session.
    prompt_submits: HashMap<String, u64>,
    /// Every row's current turn: the draft guard asks whether anyone typed
    /// since it began.
    turns: HashMap<String, Turn>,
    /// Sessions whose Inbox held undelivered items at the last step.
    pending: HashSet<String>,
    last_gc: Option<u64>,
}

impl Default for Drain {
    fn default() -> Self {
        Self::new(Store::home(), Arc::new(HostTerminal))
    }
}

impl std::fmt::Debug for Drain {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Drain")
            .field("targets", &self.targets)
            .finish_non_exhaustive()
    }
}

impl Drain {
    pub fn new(store: Store, io: Arc<dyn HostIo>) -> Self {
        let (outcomes_tx, outcomes_rx) = mpsc::channel();
        Self {
            store,
            io,
            targets: HashMap::new(),
            outcomes_tx,
            outcomes_rx,
            prompt_submits: HashMap::new(),
            turns: HashMap::new(),
            pending: HashSet::new(),
            last_gc: None,
        }
    }

    /// One accepted hook event: a prompt submit may confirm a paste, and
    /// it begins a turn.
    pub fn observe_hook(&mut self, session_id: &str, canonical_event: &str, at_ms: u64) {
        if canonical_event == "UserPromptSubmit" {
            self.prompt_submits.insert(session_id.to_owned(), at_ms);
            let turn = self.turns.entry(session_id.to_owned()).or_insert(Turn {
                began_at: at_ms,
                active: false,
            });
            turn.began_at = turn.began_at.max(at_ms);
        }
    }

    /// A turn begins at the step that sees a row turn Busy or Starting from
    /// Idle. A row first seen counts from then: what was typed before the
    /// drain watched it is not taken for a draft.
    fn observe_turns(&mut self, rows: &[SessionRow], now: u64) {
        for row in rows {
            let active = matches!(
                row.status,
                Status::Busy | Status::Starting | Status::Attention
            );
            let turn = self.turns.entry(row.id.clone()).or_insert(Turn {
                began_at: now,
                active,
            });
            let begins = matches!(row.status, Status::Busy | Status::Starting);
            if begins && !turn.active {
                turn.began_at = now;
            }
            turn.active = active;
        }
        let live: HashSet<&str> = rows.iter().map(|row| row.id.as_str()).collect();
        self.turns.retain(|id, _| live.contains(id.as_str()));
    }

    /// Once per rescan: settle finished pastes, then decide every Inbox
    /// with pending items. Returns notifications for the user.
    pub fn step(&mut self, rows: &[SessionRow], now: u64) -> Vec<Notice> {
        while let Ok((session_id, outcome)) = self.outcomes_rx.try_recv() {
            self.apply(&session_id, outcome, now);
        }
        self.collect_garbage(now);
        self.observe_turns(rows, now);
        let ids = self.store.inbox_ids();
        let mut settings = None;
        let mut notices = Vec::new();
        self.pending.clear();
        for id in &ids {
            let stats = self.store.pending_stats(id);
            if stats.items > 0 {
                self.pending.insert(id.clone());
            }
            let hold = if stats.items == 0 {
                self.forget(id);
                None
            } else {
                let row = rows.iter().find(|row| row.id == *id);
                let settings = settings.get_or_insert_with(|| Settings::load(self.io.as_ref()));
                self.decide(id, row, stats, settings, now, &mut notices)
            };
            self.publish(id, hold, now);
        }
        self.targets.retain(|id, target| {
            target.pastes.retain(|at| at + HOUR_MS > now);
            ids.contains(id) || target.in_flight || !target.pastes.is_empty()
        });
        self.prompt_submits
            .retain(|id, _| self.targets.contains_key(id));
        notices
    }

    /// The hold for one target with pending items; `None` once a paste
    /// starts or a batch is confirmed.
    fn decide(
        &mut self,
        id: &str,
        row: Option<&SessionRow>,
        stats: PendingStats,
        settings: &Settings,
        now: u64,
        notices: &mut Vec<Notice>,
    ) -> Option<HoldReason> {
        if let Some(hold) = self.settle_paste(id, row, now) {
            return hold;
        }
        let Some(row) = row else {
            return Some(HoldReason::Exited);
        };
        let turn_began_at = self.turns.get(id).map_or(now, |turn| turn.began_at);
        let target = self.targets.entry(id.to_owned()).or_default();
        let candidate = Candidate {
            id,
            row,
            stats,
            settings,
            now,
            turn_began_at,
        };
        let ready = match ready_to_paste(target, self.io.as_ref(), &candidate, notices) {
            Ok(ready) => ready,
            Err(hold) => return Some(hold),
        };
        if !self.spawn_delivery(id, ready.guarded, ready.confident, now) {
            return Some(HoldReason::Retry);
        }
        if let Some(target) = self.targets.get_mut(id) {
            target.in_flight = true;
            target.spawned_at = Some(now);
        }
        Some(HoldReason::InFlight)
    }

    /// A paste in flight or waiting for its confirmation decides the hold
    /// on its own (`Some`); `None` lets the drain consider a new paste.
    fn settle_paste(
        &mut self,
        id: &str,
        row: Option<&SessionRow>,
        now: u64,
    ) -> Option<Option<HoldReason>> {
        let target = self.targets.get_mut(id)?;
        if target.in_flight {
            return Some(Some(HoldReason::InFlight));
        }
        let awaiting = target.awaiting.as_ref()?;
        let submitted = self
            .prompt_submits
            .get(id)
            .is_some_and(|at| *at >= awaiting.pasted_at);
        if submitted || row.is_some_and(|row| took_paste(row, awaiting.pasted_at)) {
            let batch_id = awaiting.batch_id.clone();
            target.awaiting = None;
            target.episode = None;
            self.complete(id, &batch_id, now);
            return Some(None);
        }
        if now.saturating_sub(awaiting.pasted_at) >= CONFIRM_TIMEOUT_MS {
            // The claim stays: the next paste is this batch again, marked
            // as a redelivery.
            target.awaiting = None;
        }
        Some(Some(HoldReason::Unconfirmed))
    }

    fn spawn_delivery(&self, id: &str, guarded: Guarded, confident: bool, now: u64) -> bool {
        let (store, io, outcomes) = (
            self.store.clone(),
            self.io.clone(),
            self.outcomes_tx.clone(),
        );
        let session_id = id.to_owned();
        std::thread::Builder::new()
            .name("unpeel-inbox-drain".into())
            .spawn(move || {
                let outcome = deliver(&store, io.as_ref(), &session_id, &guarded, confident, now);
                let _ = outcomes.send((session_id, outcome));
            })
            .is_ok()
    }

    fn apply(&mut self, id: &str, outcome: Outcome, now: u64) {
        let target = self.targets.entry(id.to_owned()).or_default();
        target.in_flight = false;
        match outcome {
            Outcome::Pasted {
                batch_id,
                pasted_at,
                delivered,
            } => {
                target.pastes.push_back(pasted_at);
                if delivered {
                    target.episode = None;
                    self.io.announce();
                } else {
                    target.awaiting = Some(Awaiting {
                        batch_id,
                        pasted_at,
                    });
                }
            }
            Outcome::Draft => target.held_for_draft(None, now),
            Outcome::CoreDraft { typed_at } => {
                let found = EmptyCheck {
                    typed_at,
                    empty: false,
                };
                target.held_for_draft(Some(found), now);
            }
            Outcome::Failed(error) => {
                target.retry_at = now + RETRY_MS;
                crate::tracelog::trace(
                    "supervisor",
                    &format!("inbox paste to {id} failed: {error}"),
                );
            }
            Outcome::Empty => {}
        }
    }

    fn complete(&self, id: &str, batch_id: &str, now: u64) {
        match self.store.complete(id, batch_id, now) {
            Ok(true) => self.io.announce(),
            Ok(false) => {}
            Err(error) => crate::tracelog::trace(
                "supervisor",
                &format!("inbox complete for {id} failed: {error}"),
            ),
        }
    }

    /// Nothing pending: only the budget history outlives the Inbox's items.
    fn forget(&mut self, id: &str) {
        if let Some(target) = self.targets.get_mut(id) {
            target.episode = None;
            target.awaiting = None;
        }
    }

    /// Edge-write the hold reason for other processes, and announce it.
    fn publish(&mut self, id: &str, hold: Option<HoldReason>, now: u64) {
        let target = self.targets.entry(id.to_owned()).or_default();
        if target.published == hold {
            return;
        }
        target.published = hold;
        let record = hold.map(|reason| Hold {
            reason: reason.word().to_owned(),
            since: now,
        });
        match self.store.set_hold(id, record.as_ref()) {
            Ok(()) => self.io.announce(),
            Err(error) => {
                crate::tracelog::trace("supervisor", &format!("inbox hold for {id}: {error}"));
            }
        }
    }

    fn collect_garbage(&mut self, now: u64) {
        if self
            .last_gc
            .is_some_and(|last| now.saturating_sub(last) < GC_INTERVAL_MS)
        {
            return;
        }
        self.last_gc = Some(now);
        match self.store.gc(&self.io.live_session_ids(), now) {
            Ok(removed) if !removed.is_empty() => self.io.announce(),
            Ok(_) => {}
            Err(error) => {
                crate::tracelog::trace("supervisor", &format!("inbox gc failed: {error}"))
            }
        }
    }

    /// Tests: wait for the paste a step just started, then apply it.
    #[cfg(test)]
    fn settle_for_test(&mut self, now: u64) {
        let (session_id, outcome) = self
            .outcomes_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("a delivery thread reports back");
        self.apply(&session_id, outcome, now);
    }
}

impl super::worker_alerts::DrainView for Drain {
    fn pasted_between(&self, session_id: &str, from: u64, to: u64) -> bool {
        self.targets.get(session_id).is_some_and(|target| {
            let within = |at: &u64| (from..=to).contains(at);
            target.spawned_at.as_ref().is_some_and(within) || target.pastes.iter().any(within)
        })
    }

    fn has_pending(&self, session_id: &str) -> bool {
        self.pending.contains(session_id)
    }
}

/// Settings read once per step, only when some Inbox has pending items.
#[derive(Debug, Clone, Copy)]
pub struct Settings {
    pub config: SupervisorConfig,
    /// App-wide "Writing to other sessions: Deny".
    pub policy_deny: bool,
}

impl Settings {
    fn load(io: &dyn HostIo) -> Self {
        io.settings()
    }
}

/// One target with pending items, as `decide` sees it this step.
struct Candidate<'a> {
    id: &'a str,
    row: &'a SessionRow,
    stats: PendingStats,
    settings: &'a Settings,
    now: u64,
    turn_began_at: u64,
}

/// Everything a paste needs once nothing holds it.
struct Ready {
    guarded: Guarded,
    confident: bool,
}

/// The gates before a paste, in order: the target's readiness, its quiet
/// idle episode and the line the draft guard allows, then the draft, retry
/// and pacing holds. `Err` is the first hold that applies.
fn ready_to_paste(
    target: &mut Target,
    io: &dyn HostIo,
    candidate: &Candidate,
    notices: &mut Vec<Notice>,
) -> Result<Ready, HoldReason> {
    let terminal = io.terminal(candidate.id);
    let confident = readiness(target, candidate, terminal.as_ref())?;
    let screen_changed_at = terminal.and_then(|terminal| terminal.screen_changed_at);
    if let Some(reason) = inbox_rules::quiet_hold(confident, candidate.now, screen_changed_at) {
        return Err(reason);
    }
    let facts = DraftFacts {
        now: candidate.now,
        turn_began_at: candidate.turn_began_at,
        last_input_at: terminal.and_then(|terminal| terminal.last_input_at),
    };
    let core_guard = terminal.is_some_and(|terminal| terminal.draft_guard);
    let line = guarded_line(target, io, candidate.id, &facts, core_guard);
    if line == Err(HoldReason::Snapshot) {
        return Err(HoldReason::Snapshot);
    }
    if !candidate.stats.wake {
        return Err(HoldReason::RideAlong);
    }
    let guarded = line.map_err(|hold| draft_hold(target, candidate, hold, notices))?;
    pacing(target, candidate)?;
    Ok(Ready { guarded, confident })
}

/// A suspected draft holds the paste, telling the user once it has held
/// long enough. Other holds pass through.
fn draft_hold(
    target: &mut Target,
    candidate: &Candidate,
    hold: HoldReason,
    notices: &mut Vec<Notice>,
) -> HoldReason {
    if hold != HoldReason::Draft {
        return hold;
    }
    let episode = target.episode.get_or_insert_with(Episode::default);
    let since = *episode.draft_since.get_or_insert(candidate.now);
    if candidate.now.saturating_sub(since) >= DRAFT_NOTIFY_MS && !episode.notified {
        episode.notified = true;
        notices.push(draft_notice(candidate.row, candidate.stats.items));
    }
    hold
}

/// Whether the target may take a paste now (`Ok(confident)`); a hold that
/// ends the idle episode drops its baseline. Ride-along items alone never
/// report the target's own hold.
fn readiness(
    target: &mut Target,
    candidate: &Candidate,
    terminal: Option<&TerminalFacts>,
) -> Result<bool, HoldReason> {
    match inbox_rules::readiness(&facts(candidate.row, terminal, candidate.settings)) {
        Readiness::Deliver { confident } => Ok(confident),
        Readiness::Hold(reason) => {
            if reason.ends_idle_episode() {
                target.episode = None;
            }
            Err(if candidate.stats.wake {
                reason
            } else {
                HoldReason::RideAlong
            })
        }
    }
}

/// A failed paste's retry delay, then the debounce and the hourly budget
/// (`inbox_rules::send_hold`).
fn pacing(target: &Target, candidate: &Candidate) -> Result<(), HoldReason> {
    let now = candidate.now;
    if now < target.retry_at {
        return Err(HoldReason::Retry);
    }
    let timing = Timing {
        now,
        oldest_at: candidate.stats.oldest_at,
        newest_at: candidate.stats.newest_at,
        deliveries_last_hour: target
            .pastes
            .iter()
            .filter(|&&at| at + HOUR_MS > now)
            .count(),
        max_deliveries_per_hour: candidate.settings.config.max_deliveries_per_hour,
    };
    inbox_rules::send_hold(&timing).map_or(Ok(()), Err)
}

fn facts(row: &SessionRow, terminal: Option<&TerminalFacts>, settings: &Settings) -> Facts {
    Facts {
        // No manifest: nothing to paste into.
        running: row.running && terminal.is_some(),
        policy_deny: settings.policy_deny,
        status: row.status,
        source: row.status_source,
        program_state: row.program_status.as_ref().map(|program| program.state),
        foreground: row.active_runtime_id.is_some() || row.active_app.is_some(),
        menu_prompt: terminal.is_some_and(|terminal| terminal.menu_prompt),
        bracketed_paste: terminal.is_some_and(|terminal| terminal.bracketed_paste),
        low_confidence: settings.config.inbox_low_confidence,
    }
}

/// The target reacted after the paste: Busy (or a prompt) now, or a
/// program turn that came and went between two rescans.
fn took_paste(row: &SessionRow, pasted_at: u64) -> bool {
    matches!(row.status, Status::Busy | Status::Attention)
        || row
            .program_status
            .as_ref()
            .and_then(|program| program.last_non_idle_at)
            .is_some_and(|at| at >= pasted_at)
}

fn draft_notice(row: &SessionRow, items: usize) -> Notice {
    let label = match row.label.trim() {
        "" => "a session",
        label => label,
    };
    let (count, verb) = match items {
        1 => ("1 queued message".to_owned(), "is"),
        n => (format!("{n} queued messages"), "are"),
    };
    Notice {
        session_id: row.id.clone(),
        body: format!("{count} for {label} {verb} waiting"),
        kind: NoticeKind::Alert,
    }
}

/// One delivery, off the tick thread: re-check the draft guard, claim
/// everything pending, paste it as one, and (for a best guess) mark it
/// delivered at once. A key the user types from `now` on stops the paste: before
/// it, nothing is written; after it, the paste waits on the line unsubmitted
/// and confirms like any other.
fn deliver(
    store: &Store,
    io: &dyn HostIo,
    id: &str,
    guarded: &Guarded,
    confident: bool,
    now: u64,
) -> Outcome {
    match io.cursor(id) {
        None => return Outcome::Failed("the screen could not be read".into()),
        Some(cursor) if cursor != guarded.line => return Outcome::Draft,
        Some(_) => {}
    }
    let batch = match store.claim_batch(id, now) {
        Ok(Some(batch)) => batch,
        Ok(None) => return Outcome::Empty,
        Err(error) => return Outcome::Failed(error.to_string()),
    };
    let text = unpeel_core::session_inbox::render_batch(&batch);
    let submitted = match io.paste(id, &text, now, guarded.ask_core.is_some()) {
        Ok(GuardedPaste::Submitted) => true,
        Ok(GuardedPaste::NotSubmitted) => false,
        Ok(GuardedPaste::NotPasted(refusal)) => {
            release_claim(store, io, id, &batch.batch_id);
            return match (refusal, guarded.ask_core) {
                (Refusal::Draft, Some(typed_at)) => Outcome::CoreDraft { typed_at },
                (Refusal::Draft, None) | (Refusal::Typing, _) => Outcome::Draft,
            };
        }
        Err(error) => {
            release_claim(store, io, id, &batch.batch_id);
            return Outcome::Failed(error);
        }
    };
    let delivered = submitted && delivered_at_once(store, id, &batch, confident, now);
    Outcome::Pasted {
        batch_id: batch.batch_id,
        pasted_at: now,
        delivered,
    }
}

/// A submitted paste that counts as delivered without a confirmation:
/// nothing will confirm a best guess, and a last attempt stops the loop.
fn delivered_at_once(store: &Store, id: &str, batch: &Batch, confident: bool, now: u64) -> bool {
    let last_attempt = batch.attempt >= MAX_PASTE_ATTEMPTS;
    if confident && last_attempt {
        crate::tracelog::trace(
            "supervisor",
            &format!(
                "inbox batch {} for {id} never confirmed; delivered after {} pastes",
                batch.batch_id, batch.attempt
            ),
        );
    }
    (!confident || last_attempt) && matches!(store.complete(id, &batch.batch_id, now), Ok(true))
}

/// A paste that wrote nothing gives its claim back: the next paste is a
/// fresh batch, where a claim left behind would make it this one again,
/// marked as a redelivery.
fn release_claim(store: &Store, io: &dyn HostIo, id: &str, batch_id: &str) {
    match store.release(id, batch_id) {
        Ok(true) => io.announce(),
        Ok(false) => {}
        Err(release) => crate::tracelog::trace(
            "supervisor",
            &format!("inbox claim {batch_id} for {id} not released: {release}"),
        ),
    }
}

#[cfg(test)]
mod tests;
