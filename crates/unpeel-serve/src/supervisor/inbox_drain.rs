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
use std::time::Duration;

use unpeel_core::session_inbox::{Hold, PendingStats, Store};
use unpeel_core::supervision::SupervisorConfig;

use super::inbox_rules::{self, Facts, HoldReason, Readiness, Timing};
use crate::sessions::{SessionRow, Status};

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
const SNAPSHOT_TIMEOUT: Duration = Duration::from_millis(100);
const PASTE_TIMEOUT: Duration = Duration::from_secs(5);

/// What the drain reads and does outside its own state: the real Host in
/// [`HostTerminal`], a fake in tests.
pub trait HostIo: Send + Sync {
    /// Manifest facts the rows do not carry; `None` without a manifest.
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts>;
    /// The line the cursor is on, from a quick viewport snapshot.
    fn cursor(&self, session_id: &str) -> Option<CursorLine>;
    /// Paste already-sanitized text and submit it.
    fn paste(&self, session_id: &str, text: &str) -> Result<(), String>;
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
}

#[derive(Debug, Default)]
struct Episode {
    baseline: Option<CursorLine>,
    draft_since: Option<u64>,
    notified: bool,
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
    Draft,
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
            pending: HashSet::new(),
            last_gc: None,
        }
    }

    /// One accepted hook event: a prompt submit may confirm a paste.
    pub fn observe_hook(&mut self, session_id: &str, canonical_event: &str, at_ms: u64) {
        if canonical_event == "UserPromptSubmit" {
            self.prompt_submits.insert(session_id.to_owned(), at_ms);
        }
    }

    /// Once per rescan: settle finished pastes, then decide every Inbox
    /// with pending items. Returns notifications for the user.
    pub fn step(&mut self, rows: &[SessionRow], now: u64) -> Vec<Notice> {
        while let Ok((session_id, outcome)) = self.outcomes_rx.try_recv() {
            self.apply(&session_id, outcome, now);
        }
        self.collect_garbage(now);
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
        let target = self.targets.entry(id.to_owned()).or_default();
        let candidate = Candidate {
            id,
            row,
            stats,
            settings,
            now,
        };
        let ready = match ready_to_paste(target, self.io.as_ref(), &candidate, notices) {
            Ok(ready) => ready,
            Err(hold) => return Some(hold),
        };
        if !self.spawn_delivery(id, ready.baseline, ready.confident, now) {
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

    fn spawn_delivery(&self, id: &str, baseline: CursorLine, confident: bool, now: u64) -> bool {
        let (store, io, outcomes) = (
            self.store.clone(),
            self.io.clone(),
            self.outcomes_tx.clone(),
        );
        let session_id = id.to_owned();
        std::thread::Builder::new()
            .name("unpeel-inbox-drain".into())
            .spawn(move || {
                let outcome = deliver(&store, io.as_ref(), &session_id, &baseline, confident, now);
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
            Outcome::Draft => {
                if let Some(episode) = target.episode.as_mut() {
                    episode.draft_since.get_or_insert(now);
                }
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
            .recv_timeout(Duration::from_secs(5))
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
}

/// Everything a paste needs once nothing holds it.
struct Ready {
    baseline: CursorLine,
    confident: bool,
}

/// The gates before a paste, in order: the target's readiness, its quiet
/// idle episode and draft-guard baseline, then the draft, retry and pacing
/// holds. `Err` is the first hold that applies.
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
    let episode = target.episode.get_or_insert_with(Episode::default);
    if episode.baseline.is_none() {
        episode.baseline = io.cursor(candidate.id);
    }
    let baseline = episode.baseline.clone().ok_or(HoldReason::Snapshot)?;
    if !candidate.stats.wake {
        return Err(HoldReason::RideAlong);
    }
    pacing(target, candidate, notices)?;
    Ok(Ready {
        baseline,
        confident,
    })
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

/// A suspected draft (telling the user once it has held long enough), a
/// failed paste's retry delay, then the debounce and the hourly budget
/// (`inbox_rules::send_hold`).
fn pacing(
    target: &mut Target,
    candidate: &Candidate,
    notices: &mut Vec<Notice>,
) -> Result<(), HoldReason> {
    let now = candidate.now;
    if let Some(episode) = target.episode.as_mut() {
        if let Some(since) = episode.draft_since {
            if now.saturating_sub(since) >= DRAFT_NOTIFY_MS && !episode.notified {
                episode.notified = true;
                notices.push(draft_notice(candidate.row, candidate.stats.items));
            }
            return Err(HoldReason::Draft);
        }
    }
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
/// delivered at once.
fn deliver(
    store: &Store,
    io: &dyn HostIo,
    id: &str,
    baseline: &CursorLine,
    confident: bool,
    now: u64,
) -> Outcome {
    match io.cursor(id) {
        None => return Outcome::Failed("the screen could not be read".into()),
        Some(cursor) if cursor != *baseline => return Outcome::Draft,
        Some(_) => {}
    }
    let batch = match store.claim_batch(id, now) {
        Ok(Some(batch)) => batch,
        Ok(None) => return Outcome::Empty,
        Err(error) => return Outcome::Failed(error.to_string()),
    };
    let text = unpeel_core::session_inbox::render_batch(&batch);
    if let Err(error) = io.paste(id, &text) {
        // The next paste is a fresh batch; a claim left behind would make it
        // this one again, marked as a redelivery.
        match store.release(id, &batch.batch_id) {
            Ok(true) => io.announce(),
            Ok(false) => {}
            Err(release) => crate::tracelog::trace(
                "supervisor",
                &format!(
                    "inbox claim {} for {id} not released: {release}",
                    batch.batch_id
                ),
            ),
        }
        return Outcome::Failed(error);
    }
    // Nothing will confirm a best guess; a last attempt stops the loop.
    let last_attempt = batch.attempt >= MAX_PASTE_ATTEMPTS;
    let delivered = (!confident || last_attempt)
        && matches!(store.complete(id, &batch.batch_id, now), Ok(true));
    if confident && last_attempt {
        crate::tracelog::trace(
            "supervisor",
            &format!(
                "inbox batch {} for {id} never confirmed; delivered after {} pastes",
                batch.batch_id, batch.attempt
            ),
        );
    }
    Outcome::Pasted {
        batch_id: batch.batch_id,
        pasted_at: now,
        delivered,
    }
}

/// The real Host: manifests, viewport snapshots, the paste recipe.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostTerminal;

impl HostIo for HostTerminal {
    fn terminal(&self, session_id: &str) -> Option<TerminalFacts> {
        let manifest = unpeel_core::session_host::load_manifest(session_id)?;
        Some(TerminalFacts {
            bracketed_paste: manifest
                .terminal_modes
                .as_ref()
                .is_some_and(|modes| modes.set.contains(&2004)),
            screen_changed_at: manifest.screen_changed_at,
            menu_prompt: manifest.menu_prompt_active,
        })
    }

    fn cursor(&self, session_id: &str) -> Option<CursorLine> {
        let snapshot = unpeel_core::session_host::request_current_viewport_snapshot_with_timeout(
            session_id,
            0,
            None,
            SNAPSHOT_TIMEOUT,
        )
        .ok()?;
        let line = snapshot
            .viewport_rows
            .get(usize::from(snapshot.cursor_row))
            .map(|row| row.text.trim_end().to_owned())
            .unwrap_or_default();
        Some(CursorLine {
            text: line,
            col: snapshot.cursor_col,
        })
    }

    fn paste(&self, session_id: &str, text: &str) -> Result<(), String> {
        unpeel_core::session_input::deliver_sanitized_text_with_timeout(
            session_id,
            text,
            true,
            Some(PASTE_TIMEOUT),
        )
    }

    fn live_session_ids(&self) -> HashSet<String> {
        let Ok(entries) = std::fs::read_dir(unpeel_core::app_paths::app_sessions_root()) else {
            return HashSet::new();
        };
        entries
            .flatten()
            .filter(|entry| entry.path().join("manifest.json").is_file())
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect()
    }

    fn settings(&self) -> Settings {
        let (config, policy_deny) = unpeel_core::supervision::config_and_write_deny();
        Settings {
            config,
            policy_deny,
        }
    }

    fn announce(&self) {
        unpeel_core::state_bus::announce(unpeel_core::state_bus::Change::SessionMarkers, None);
    }
}

#[cfg(test)]
mod tests;
