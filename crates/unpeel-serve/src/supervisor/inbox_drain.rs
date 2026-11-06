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
    /// App-wide "Writing to other sessions: Deny".
    fn policy_deny(&self) -> bool;
    fn config(&self) -> SupervisorConfig;
    /// Inbox items were marked delivered.
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
        let terminal = self.io.terminal(id);
        let target = self.targets.entry(id.to_owned()).or_default();
        let facts = facts(row, terminal.as_ref(), settings);
        let confident = match inbox_rules::readiness(&facts) {
            Readiness::Deliver { confident } => confident,
            Readiness::Hold(reason) => {
                if reason.ends_idle_episode() {
                    target.episode = None;
                }
                return Some(if stats.wake {
                    reason
                } else {
                    HoldReason::RideAlong
                });
            }
        };
        let screen_changed_at = terminal.and_then(|terminal| terminal.screen_changed_at);
        if let Some(reason) = inbox_rules::quiet_hold(confident, now, screen_changed_at) {
            return Some(reason);
        }
        let episode = target.episode.get_or_insert_with(Episode::default);
        if episode.baseline.is_none() {
            episode.baseline = self.io.cursor(id);
        }
        let Some(baseline) = episode.baseline.clone() else {
            return Some(HoldReason::Snapshot);
        };
        if !stats.wake {
            return Some(HoldReason::RideAlong);
        }
        if let Some(since) = episode.draft_since {
            if now.saturating_sub(since) >= DRAFT_NOTIFY_MS && !episode.notified {
                episode.notified = true;
                notices.push(draft_notice(row, stats.items));
            }
            return Some(HoldReason::Draft);
        }
        if now < target.retry_at {
            return Some(HoldReason::Retry);
        }
        let timing = Timing {
            now,
            oldest_at: stats.oldest_at,
            newest_at: stats.newest_at,
            deliveries_last_hour: target
                .pastes
                .iter()
                .filter(|&&at| at + HOUR_MS > now)
                .count(),
            max_deliveries_per_hour: settings.config.max_deliveries_per_hour,
        };
        if let Some(reason) = inbox_rules::send_hold(&timing) {
            return Some(reason);
        }
        if !self.spawn_delivery(id, baseline, confident, now) {
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

    /// Edge-write the hold reason for other processes.
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
        if let Err(error) = self.store.set_hold(id, record.as_ref()) {
            crate::tracelog::trace("supervisor", &format!("inbox hold for {id}: {error}"));
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
        if let Err(error) = self.store.gc(&self.io.live_session_ids(), now) {
            crate::tracelog::trace("supervisor", &format!("inbox gc failed: {error}"));
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
struct Settings {
    config: SupervisorConfig,
    policy_deny: bool,
}

impl Settings {
    fn load(io: &dyn HostIo) -> Self {
        Self {
            config: io.config(),
            policy_deny: io.policy_deny(),
        }
    }
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
        let _ = store.release(id, &batch.batch_id);
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

    fn policy_deny(&self) -> bool {
        unpeel_core::app_state::load()
            .ok()
            .and_then(|state| {
                state
                    .get("mcp_nonchild_write_access")
                    .and_then(serde_json::Value::as_str)
                    .map(unpeel_core::state::McpNonChildWriteAccess::from_state_str)
            })
            .is_some_and(|access| access == unpeel_core::state::McpNonChildWriteAccess::Deny)
    }

    fn config(&self) -> SupervisorConfig {
        unpeel_core::supervision::load_config()
    }

    fn announce(&self) {
        unpeel_core::state_bus::announce(unpeel_core::state_bus::Change::SessionMarkers, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::{SessionRow, Status, StatusSource};
    use std::sync::Mutex;
    use unpeel_core::session_inbox::{ItemKind, NewItem, Priority, Sender};

    const T0: u64 = 1_800_000_000_000;

    #[derive(Default)]
    struct World {
        terminal: TerminalFacts,
        cursor: Option<CursorLine>,
        pastes: Vec<(String, String)>,
        paste_error: Option<String>,
        deny: bool,
        config: unpeel_core::supervision::SupervisorConfig,
        live: HashSet<String>,
    }

    #[derive(Default)]
    struct FakeIo(Mutex<World>);

    impl FakeIo {
        fn with<T>(&self, change: impl FnOnce(&mut World) -> T) -> T {
            change(&mut self.0.lock().unwrap())
        }
    }

    impl HostIo for FakeIo {
        fn terminal(&self, _session_id: &str) -> Option<TerminalFacts> {
            Some(self.with(|world| world.terminal))
        }
        fn cursor(&self, _session_id: &str) -> Option<CursorLine> {
            self.with(|world| world.cursor.clone())
        }
        fn paste(&self, session_id: &str, text: &str) -> Result<(), String> {
            self.with(|world| match world.paste_error.clone() {
                Some(error) => Err(error),
                None => {
                    world.pastes.push((session_id.into(), text.into()));
                    Ok(())
                }
            })
        }
        fn live_session_ids(&self) -> HashSet<String> {
            self.with(|world| world.live.clone())
        }
        fn policy_deny(&self) -> bool {
            self.with(|world| world.deny)
        }
        fn config(&self) -> unpeel_core::supervision::SupervisorConfig {
            self.with(|world| world.config)
        }
        fn announce(&self) {}
    }

    struct Fixture {
        _tmp: tempfile::TempDir,
        store: Store,
        io: Arc<FakeIo>,
        drain: Drain,
    }

    fn fixture() -> Fixture {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::at(tmp.path().join("session-inboxes"));
        let io = Arc::new(FakeIo::default());
        io.with(|world| {
            world.terminal = TerminalFacts {
                bracketed_paste: true,
                screen_changed_at: Some(T0 - 60_000),
                menu_prompt: false,
            };
            world.cursor = Some(prompt(""));
            world.live = HashSet::from(["router".to_string()]);
        });
        let drain = Drain::new(store.clone(), io.clone());
        Fixture {
            _tmp: tmp,
            store,
            io,
            drain,
        }
    }

    fn prompt(draft: &str) -> CursorLine {
        CursorLine {
            text: format!("> {draft}"),
            col: 2 + draft.len() as u16,
        }
    }

    fn item(summary: &str, status: &str, priority: Priority) -> NewItem {
        NewItem {
            sender: Sender::Session("w1".into()),
            kind: ItemKind::Report,
            priority,
            about: None,
            status: Some(status.into()),
            label: Some("worker".into()),
            summary: summary.into(),
            body: String::new(),
            dedupe_key: None,
        }
    }

    fn report(fx: &Fixture, summary: &str, at: u64) -> String {
        fx.store
            .enqueue("router", item(summary, "done", Priority::Wake), at)
            .unwrap()
            .item_id
    }

    /// The Router, at its prompt per its hooks, with Claude in front.
    fn router(status: Status) -> SessionRow {
        SessionRow {
            host_started_at: None,
            id: "router".into(),
            project_id: "p".into(),
            label: "Router".into(),
            command: "claude".into(),
            active_runtime_id: Some("claude".into()),
            active_app: None,
            resume_available: false,
            resumable: true,
            resume_agent_available: false,
            running: true,
            status,
            status_source: StatusSource::Hooks,
            program_status: None,
            created_at: 1,
            pinned: false,
            unread: false,
            latest_alert_body: None,
            cwd: "/tmp".into(),
            activity_at: 1,
            group_id: "p".into(),
            detected_local_urls: Vec::new(),
            is_worker: false,
        }
    }

    impl Fixture {
        fn step(&mut self, row: &SessionRow, now: u64) -> Vec<Notice> {
            self.drain.step(std::slice::from_ref(row), now)
        }

        /// One step that starts a paste, then that paste's outcome.
        fn step_and_settle(&mut self, row: &SessionRow, now: u64) -> Vec<Notice> {
            let notices = self.step(row, now);
            self.drain.settle_for_test(now);
            notices
        }

        fn pastes(&self) -> Vec<String> {
            self.io
                .with(|world| world.pastes.iter().map(|(_, text)| text.clone()).collect())
        }

        fn hold(&self) -> Option<String> {
            self.store.hold("router").map(|hold| hold.reason)
        }

        fn pending(&self) -> usize {
            self.store.pending_stats("router").items
        }
    }

    #[test]
    fn a_busy_target_holds_and_an_idle_one_gets_everything_in_one_paste() {
        let mut fx = fixture();
        report(&fx, "first summary", T0 - 10_000);
        report(&fx, "second summary", T0 - 9_000);

        fx.step(&router(Status::Busy), T0);
        assert!(fx.pastes().is_empty());
        assert_eq!(fx.hold().as_deref(), Some("busy"));

        fx.step_and_settle(&router(Status::Idle), T0 + 1_000);
        let pastes = fx.pastes();
        assert_eq!(pastes.len(), 1, "{pastes:?}");
        let paste = &pastes[0];
        assert!(paste.starts_with("[unpeel inbox for id:router · batch "));
        assert!(paste.contains("· 2 items ·"));
        let first = paste.find("first summary").unwrap();
        assert!(first < paste.find("second summary").unwrap());
        // Pasted, not yet taken: still pending until the target confirms.
        assert_eq!(fx.pending(), 2);
    }

    #[test]
    fn a_prompt_submit_after_the_paste_marks_the_batch_delivered() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        // A prompt the user submitted before the paste confirms nothing.
        fx.drain.observe_hook("router", "UserPromptSubmit", T0 - 1);
        fx.step_and_settle(&idle, T0);
        fx.step(&idle, T0 + 500);
        assert_eq!(fx.pending(), 1);
        assert_eq!(fx.hold().as_deref(), Some("unconfirmed"));

        fx.drain.observe_hook("router", "Stop", T0 + 600);
        fx.step(&idle, T0 + 700);
        assert_eq!(fx.pending(), 1, "only a prompt submit confirms");

        fx.drain
            .observe_hook("router", "UserPromptSubmit", T0 + 800);
        fx.step(&idle, T0 + 900);
        assert_eq!(fx.pending(), 0);
        assert_eq!(fx.store.list("router").unwrap().delivered.len(), 1);
        assert_eq!(fx.hold(), None);
        assert_eq!(fx.pastes().len(), 1);
    }

    #[test]
    fn a_busy_edge_after_the_paste_also_confirms_it() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        fx.step_and_settle(&router(Status::Idle), T0);
        fx.step(&router(Status::Busy), T0 + 1_000);
        assert_eq!(fx.pending(), 0);

        // A program that went working and back to idle between two rescans
        // still left its mark.
        report(&fx, "next", T0 + 2_000);
        let program = |last_non_idle_at| SessionRow {
            status_source: StatusSource::Program,
            program_status: Some(unpeel_core::program_status::ProgramStatusSummary {
                state: unpeel_core::program_status::ProgramState::Idle,
                kind: None,
                progress: None,
                app: None,
                title: None,
                msg: None,
                id: None,
                changed_at: 0,
                last_non_idle_at,
                last_finished_at: None,
                finished_edges: 0,
            }),
            ..router(Status::Idle)
        };
        let later = T0 + 20_000;
        fx.step_and_settle(&program(Some(T0 + 1_000)), later);
        assert_eq!(fx.pastes().len(), 2);
        fx.step(&program(Some(T0 + 1_000)), later + 500);
        assert_eq!(fx.pending(), 1, "a turn from before the paste");
        fx.step(&program(Some(later + 200)), later + 1_000);
        assert_eq!(fx.pending(), 0);
    }

    #[test]
    fn an_unconfirmed_paste_is_pasted_again_as_a_redelivery() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        fx.step_and_settle(&idle, T0);
        fx.step(&idle, T0 + CONFIRM_TIMEOUT_MS - 1);
        assert_eq!(fx.pastes().len(), 1);

        fx.step(&idle, T0 + CONFIRM_TIMEOUT_MS);
        fx.step_and_settle(&idle, T0 + CONFIRM_TIMEOUT_MS + 100);
        let pastes = fx.pastes();
        assert_eq!(pastes.len(), 2, "{pastes:?}");
        let batch = |paste: &str| {
            paste
                .split_once("batch ")
                .and_then(|(_, rest)| rest.split_whitespace().next())
                .map(str::to_owned)
        };
        assert!(batch(&pastes[0]).is_some());
        assert_eq!(batch(&pastes[0]), batch(&pastes[1]), "the same batch");
        assert!(pastes[1].contains("(redelivery)"));
        assert!(!pastes[0].contains("(redelivery)"));
        assert_eq!(fx.pending(), 1);
    }

    #[test]
    fn a_batch_that_is_never_confirmed_stops_at_its_last_attempt() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        // Hooks that never fire: each cycle times out and pastes again.
        let mut now = T0;
        for _ in 1..MAX_PASTE_ATTEMPTS {
            fx.step_and_settle(&idle, now);
            now += CONFIRM_TIMEOUT_MS;
            fx.step(&idle, now);
            now += 100;
        }
        assert_eq!(fx.pending(), 1);
        fx.step_and_settle(&idle, now);
        assert_eq!(fx.pastes().len() as u32, MAX_PASTE_ATTEMPTS);
        assert_eq!(fx.pending(), 0, "the last attempt counts as delivered");
        for _ in 0..3 {
            now += CONFIRM_TIMEOUT_MS;
            fx.step(&idle, now);
        }
        assert_eq!(fx.pastes().len() as u32, MAX_PASTE_ATTEMPTS);
    }

    #[test]
    fn a_ride_along_item_alone_never_pastes_but_goes_with_the_next_wake_item() {
        let mut fx = fixture();
        fx.store
            .enqueue(
                "router",
                item("halfway", "progress", Priority::RideAlong),
                T0 - 60_000,
            )
            .unwrap();
        let idle = router(Status::Idle);
        for second in 0..5 {
            fx.step(&idle, T0 + second * 1_000);
        }
        assert!(fx.pastes().is_empty());
        assert_eq!(fx.hold().as_deref(), Some("ride_along"));

        report(&fx, "finished", T0 + 5_000);
        fx.step_and_settle(&idle, T0 + 8_000);
        let pastes = fx.pastes();
        assert_eq!(pastes.len(), 1);
        assert!(pastes[0].contains("halfway") && pastes[0].contains("finished"));
    }

    #[test]
    fn the_quiet_window_and_the_debounce_hold_a_paste() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        fx.io
            .with(|world| world.terminal.screen_changed_at = Some(T0 - 1_000));
        fx.step(&idle, T0);
        assert_eq!(fx.hold().as_deref(), Some("quiet"));

        fx.io
            .with(|world| world.terminal.screen_changed_at = Some(T0 - 60_000));
        report(&fx, "another", T0 - 500);
        fx.step(&idle, T0);
        assert_eq!(fx.hold().as_deref(), Some("debounce"));
        assert!(fx.pastes().is_empty());
        fx.step_and_settle(&idle, T0 + 1_500);
        assert_eq!(fx.pastes().len(), 1);
    }

    #[test]
    fn the_hourly_budget_counts_pastes_per_target() {
        let mut fx = fixture();
        fx.io.with(|world| world.config.max_deliveries_per_hour = 1);
        report(&fx, "one", T0 - 10_000);
        fx.step_and_settle(&router(Status::Idle), T0);
        fx.step(&router(Status::Busy), T0 + 1_000);
        assert_eq!(fx.pending(), 0);

        report(&fx, "two", T0 + 2_000);
        fx.step(&router(Status::Idle), T0 + 10_000);
        assert_eq!(fx.hold().as_deref(), Some("budget"));
        fx.step_and_settle(&router(Status::Idle), T0 + 3_600_000);
        assert_eq!(fx.pastes().len(), 2);
    }

    #[test]
    fn a_changed_input_line_holds_the_paste_and_tells_the_user_once() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        fx.step(&router(Status::Busy), T0);
        // The first quiet idle step takes the baseline (an empty prompt);
        // a fresh item keeps the debounce from pasting yet.
        report(&fx, "more", T0 + 50);
        fx.step(&idle, T0 + 100);
        assert_eq!(fx.hold().as_deref(), Some("debounce"));
        // Then the user starts typing.
        fx.io.with(|world| world.cursor = Some(prompt("hel")));
        fx.step_and_settle(&idle, T0 + 3_000);
        fx.step(&idle, T0 + 3_100);
        assert!(fx.pastes().is_empty(), "never paste over a draft");
        assert_eq!(fx.hold().as_deref(), Some("draft"));

        assert!(fx.step(&idle, T0 + 3_000 + DRAFT_NOTIFY_MS - 1).is_empty());
        let notices = fx.step(&idle, T0 + 3_000 + DRAFT_NOTIFY_MS);
        assert_eq!(
            notices,
            [Notice {
                session_id: "router".into(),
                body: "2 queued messages for Router are waiting".into(),
                kind: NoticeKind::Alert,
            }]
        );
        assert!(fx
            .step(&idle, T0 + 3_000 + DRAFT_NOTIFY_MS + 1_000)
            .is_empty());
        assert!(fx.pastes().is_empty());

        // The next Busy -> Idle cycle starts over with a fresh baseline.
        fx.step(&router(Status::Busy), T0 + 200_000);
        fx.io.with(|world| world.cursor = Some(prompt("")));
        fx.step_and_settle(&idle, T0 + 201_000);
        assert_eq!(fx.pastes().len(), 1);
    }

    #[test]
    fn a_failed_paste_releases_its_claim_and_retries_after_ten_seconds() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        fx.io
            .with(|world| world.paste_error = Some("socket closed".into()));
        fx.step_and_settle(&idle, T0);
        fx.step(&idle, T0 + RETRY_MS - 1);
        assert_eq!(fx.hold().as_deref(), Some("retry"));

        fx.io.with(|world| world.paste_error = None);
        fx.step_and_settle(&idle, T0 + RETRY_MS);
        let pastes = fx.pastes();
        assert_eq!(pastes.len(), 1);
        assert!(!pastes[0].contains("(redelivery)"), "a fresh batch");
    }

    #[test]
    fn a_best_guess_waits_ten_quiet_seconds_and_needs_no_confirmation() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 60_000);
        let screen = SessionRow {
            status_source: StatusSource::Screen,
            ..router(Status::Idle)
        };
        fx.io
            .with(|world| world.terminal.screen_changed_at = Some(T0 - 5_000));
        fx.step(&screen, T0);
        assert_eq!(fx.hold().as_deref(), Some("quiet"));
        fx.step_and_settle(&screen, T0 + 5_000);
        assert_eq!(fx.pastes().len(), 1);
        assert_eq!(fx.pending(), 0, "delivered once pasted");

        fx.io
            .with(|world| world.config.inbox_low_confidence = false);
        report(&fx, "next", T0 + 6_000);
        fx.step(&screen, T0 + 30_000);
        assert_eq!(fx.hold().as_deref(), Some("low_confidence"));
    }

    #[test]
    fn deny_is_read_again_at_every_drain() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let idle = router(Status::Idle);
        fx.io.with(|world| world.deny = true);
        fx.step(&idle, T0);
        assert_eq!(fx.hold().as_deref(), Some("policy_deny"));
        fx.io.with(|world| world.deny = false);
        fx.step_and_settle(&idle, T0 + 1_000);
        assert_eq!(fx.pastes().len(), 1);
    }

    #[test]
    fn a_plain_shell_or_a_missing_session_is_held_for_pulling() {
        let mut fx = fixture();
        report(&fx, "result", T0 - 10_000);
        let cat = SessionRow {
            command: "cat".into(),
            active_runtime_id: None,
            status_source: StatusSource::None,
            ..router(Status::Idle)
        };
        fx.io.with(|world| world.terminal.bracketed_paste = false);
        fx.step(&cat, T0);
        assert_eq!(fx.hold().as_deref(), Some("no_agent_authority"));
        fx.drain.step(&[], T0 + 1_000);
        assert_eq!(fx.hold().as_deref(), Some("exited"));
        assert!(fx.pastes().is_empty());
    }

    #[test]
    fn inboxes_of_long_gone_sessions_are_collected() {
        let mut fx = fixture();
        fx.store
            .enqueue("gone", item("lost", "done", Priority::Wake), T0)
            .unwrap();
        fx.drain.step(&[], T0);
        fx.drain.step(&[], T0 + 11 * 60_000);
        assert_eq!(fx.store.inbox_ids(), Vec::<String>::new());
    }
}
