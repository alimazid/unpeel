use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use unpeel_core::session_inbox::{InboxItem, Priority, Store};

use super::*;
use crate::sessions::{SessionRow, Status, StatusSource};

const T0: u64 = 1_800_000_000_000;
const ROUTER: &str = "router";
const WORKER: &str = "w1";
const MILLION: u64 = 1_000_000;

#[derive(Default)]
struct World {
    readings: HashMap<String, ContextReading>,
    terminal: TerminalFacts,
    deny: bool,
    refuse: Vec<SendOutcome>,
    sends: Vec<(String, u64)>,
    commands: Vec<String>,
    reads: usize,
}

#[derive(Default)]
struct FakeHost(Mutex<World>);

impl FakeHost {
    fn with<T>(&self, change: impl FnOnce(&mut World) -> T) -> T {
        change(&mut self.0.lock().unwrap())
    }
}

impl CompactionHost for FakeHost {
    fn reading(&self, session_id: &str) -> Option<ContextReading> {
        self.with(|world| {
            world.reads += 1;
            world.readings.get(session_id).cloned()
        })
    }
    fn terminal(&self, _session_id: &str) -> Option<TerminalFacts> {
        self.with(|world| Some(world.terminal))
    }
    fn writes_denied(&self) -> bool {
        self.with(|world| world.deny)
    }
    fn send(&self, session_id: &str, command: &str, since: u64) -> Result<SendOutcome, String> {
        self.with(|world| {
            if !world.refuse.is_empty() {
                return Ok(world.refuse.remove(0));
            }
            world.sends.push((session_id.to_owned(), since));
            world.commands.push(command.to_owned());
            Ok(SendOutcome::Submitted)
        })
    }
    fn announce(&self) {}
}

#[derive(Default)]
struct FakeDrain {
    pastes: Vec<(String, u64)>,
    pending: HashSet<String>,
}

impl DrainView for FakeDrain {
    fn pasted_between(&self, session_id: &str, from: u64, to: u64) -> bool {
        self.pastes
            .iter()
            .any(|(id, at)| id == session_id && (from..=to).contains(at))
    }
    fn has_pending(&self, session_id: &str) -> bool {
        self.pending.contains(session_id)
    }
}

struct Fixture {
    _tmp: tempfile::TempDir,
    store: Store,
    host: Arc<FakeHost>,
    drain: FakeDrain,
    workers: HashSet<String>,
    percent: u8,
    compaction: Compaction,
}

/// A running Router with one Worker, its manifest from a guarded PTY core,
/// `supervisor_compact_percent` at 40.
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::at(tmp.path().join("session-inboxes"));
    let host = Arc::new(FakeHost::default());
    host.with(|world| world.terminal.draft_guard = true);
    let compaction = Compaction::new(store.clone(), host.clone());
    Fixture {
        _tmp: tmp,
        store,
        host,
        drain: FakeDrain::default(),
        workers: HashSet::from([WORKER.to_owned()]),
        percent: 40,
        compaction,
    }
}

fn worker(status: Status) -> SessionRow {
    SessionRow {
        host_started_at: None,
        id: WORKER.into(),
        project_id: "p".into(),
        label: "fix-login".into(),
        command: "claude".into(),
        active_runtime_id: Some("claude".into()),
        active_app: None,
        resume_available: false,
        resumable: true,
        resume_agent_available: false,
        running: true,
        status,
        status_source: StatusSource::Program,
        program_status: None,
        created_at: 1,
        pinned: false,
        unread: false,
        latest_alert_body: None,
        cwd: "/tmp".into(),
        activity_at: 1,
        group_id: "p".into(),
        detected_local_urls: Vec::new(),
        spawned_by: None,
        is_worker: true,
        is_router: false,
    }
}

impl Fixture {
    fn context(&self, tokens: u64, model: &str, window: Option<u64>) {
        self.host.with(|world| {
            world.readings.insert(
                WORKER.into(),
                ContextReading {
                    tokens,
                    model: Some(model.into()),
                    window,
                    compact_command: Some("/compact".into()),
                },
            )
        });
    }

    /// The Worker's context at `tokens` of a 1M window.
    fn at(&self, tokens: u64) {
        self.context(tokens, "claude-opus-5-5", Some(MILLION));
    }

    fn step(&mut self, status: Status, now: u64) {
        self.step_row(worker(status), now);
    }

    /// A rescan; a send it starts is waited for and applied.
    fn step_row(&mut self, row: SessionRow, now: u64) {
        let scope = Scope {
            router: ROUTER,
            workers: &self.workers,
            percent: self.percent,
        };
        self.compaction.step(&[row], Some(scope), &self.drain, now);
        self.settle(now);
    }

    fn settle(&mut self, now: u64) {
        let sending = self
            .compaction
            .workers
            .get(WORKER)
            .and_then(|worker| worker.sent.as_ref())
            .is_some_and(|sent| !sent.typed);
        if sending {
            self.compaction.settle_for_test(now);
        }
    }

    fn armed(&self) -> bool {
        self.compaction
            .workers
            .get(WORKER)
            .is_none_or(|worker| worker.armed)
    }

    /// A Worker turn ended at `at`: its Finished edge, then the rescan.
    fn turn_ends(&mut self, at: u64) {
        self.compaction.turn_finished(&worker(Status::Idle), at);
        self.step(Status::Idle, at);
    }

    /// The Host's compaction runs: busy at `at`, done `ms` later.
    fn compaction_runs(&mut self, at: u64, ms: u64) {
        self.step(Status::Busy, at);
        self.compaction
            .turn_finished(&worker(Status::Idle), at + ms);
        self.step(Status::Idle, at + ms);
    }

    fn sends(&self) -> Vec<(String, u64)> {
        self.host.with(|world| world.sends.clone())
    }

    fn queued(&self) -> Vec<InboxItem> {
        let listing = self.store.list(ROUTER).unwrap();
        listing
            .pending
            .iter()
            .map(|header| self.store.item(ROUTER, &header.id).unwrap().unwrap())
            .collect()
    }
}

#[test]
fn a_worker_this_full_when_its_turn_ends_is_compacted_and_the_router_told() {
    let mut fx = fixture();
    fx.at(412_000);
    fx.turn_ends(T0);
    assert_eq!(
        fx.sends(),
        [(WORKER.to_owned(), T0 - 3_000)],
        "typed under the typing guard's 3 s window"
    );
    assert_eq!(fx.host.with(|world| world.commands.clone()), ["/compact"]);
    assert!(fx.queued().is_empty(), "told once it starts");
    fx.step(Status::Busy, T0 + 1_000);
    let queued = fx.queued();
    assert_eq!(queued.len(), 1, "{queued:?}");
    let notice = &queued[0];
    assert_eq!(
        notice.priority,
        Priority::RideAlong,
        "it never wakes the Router"
    );
    assert_eq!(notice.status.as_deref(), Some("compacted"));
    assert_eq!(notice.about.as_deref(), Some(WORKER));
    assert_eq!(
        notice.summary,
        "\"fix-login\" was at 41% of its context (412K tokens) when its turn ended, so the \
         Host compacted it (supervisor_compact_percent is 40)."
    );
}

#[test]
fn a_worker_under_the_threshold_is_left_alone() {
    let mut fx = fixture();
    fx.at(394_999);
    fx.turn_ends(T0);
    fx.step(Status::Idle, T0 + 1_000);
    assert!(fx.sends().is_empty());
    assert!(fx.queued().is_empty());
}

#[test]
fn only_a_turn_end_is_read_and_compacted() {
    let mut fx = fixture();
    fx.at(900_000);
    for at in [T0, T0 + 1_000, T0 + 2_000] {
        fx.step(Status::Idle, at);
    }
    fx.step(Status::Busy, T0 + 3_000);
    assert!(fx.sends().is_empty());
    assert_eq!(fx.host.with(|world| world.reads), 0, "no transcript read");
    // One read per turn end, however long it waits.
    fx.host.with(|world| world.terminal.menu_prompt = true);
    fx.turn_ends(T0 + 4_000);
    fx.step(Status::Idle, T0 + 5_000);
    assert_eq!(fx.host.with(|world| world.reads), 1);
}

#[test]
fn zero_turns_compaction_off() {
    let mut fx = fixture();
    fx.percent = 0;
    fx.at(900_000);
    fx.turn_ends(T0);
    assert!(fx.sends().is_empty());
    assert_eq!(fx.host.with(|world| world.reads), 0);
}

#[test]
fn it_waits_for_an_idle_worker_with_nothing_landing_then_compacts() {
    let mut fx = fixture();
    fx.at(500_000);
    fx.compaction.turn_finished(&worker(Status::Idle), T0);
    // Busy again, or waiting on a prompt.
    fx.step(Status::Busy, T0);
    fx.step(Status::Attention, T0 + 1_000);
    // A select menu would take the keys.
    fx.host.with(|world| world.terminal.menu_prompt = true);
    fx.step(Status::Idle, T0 + 2_000);
    fx.host.with(|world| world.terminal.menu_prompt = false);
    // The Router wrote a moment ago: a task is landing.
    fx.store.touch_router(WORKER, T0 + 1_000).unwrap();
    fx.step(Status::Idle, T0 + 3_000);
    fx.step(Status::Idle, T0 + 6_000);
    // Inbox items wait, or the drain just pasted.
    fx.drain.pending.insert(WORKER.into());
    fx.step(Status::Idle, T0 + 7_000);
    fx.drain.pending.clear();
    fx.drain.pastes.push((WORKER.into(), T0 + 6_500));
    fx.step(Status::Idle, T0 + 8_000);
    assert!(fx.sends().is_empty());
    fx.step(Status::Idle, T0 + 12_000);
    assert_eq!(fx.sends(), [(WORKER.to_owned(), T0 + 9_000)]);
}

#[test]
fn a_turn_end_past_the_warm_cache_is_left_for_the_next_one() {
    let mut fx = fixture();
    fx.at(500_000);
    fx.host.with(|world| world.terminal.menu_prompt = true);
    fx.turn_ends(T0);
    fx.host.with(|world| world.terminal.menu_prompt = false);
    fx.step(Status::Idle, T0 + WARM_MS + 1);
    fx.step(Status::Idle, T0 + WARM_MS + 2_000);
    assert!(fx.sends().is_empty(), "never on a cold cache");
    fx.turn_ends(T0 + WARM_MS + 60_000);
    assert_eq!(fx.sends().len(), 1, "the next turn end");
}

#[test]
fn an_older_pty_core_is_never_typed_into() {
    let mut fx = fixture();
    fx.host.with(|world| world.terminal.draft_guard = false);
    fx.at(500_000);
    fx.turn_ends(T0);
    fx.host.with(|world| world.terminal.draft_guard = true);
    fx.step(Status::Idle, T0 + 1_000);
    assert!(fx.sends().is_empty(), "dropped for that turn, not retried");
}

#[test]
fn a_refused_send_tries_again_and_counts_only_once_it_lands() {
    let mut fx = fixture();
    fx.at(500_000);
    fx.host
        .with(|world| world.refuse = vec![SendOutcome::NotTyped, SendOutcome::NotTyped]);
    fx.turn_ends(T0);
    fx.step(Status::Idle, T0 + 1_000);
    fx.step(Status::Busy, T0 + 1_500);
    assert!(fx.queued().is_empty(), "nothing was typed");
    fx.step(Status::Idle, T0 + 2_000);
    fx.step(Status::Idle, T0 + 4_000);
    assert_eq!(fx.sends(), [(WORKER.to_owned(), T0 + 1_000)]);
    fx.step(Status::Busy, T0 + 5_000);
    assert_eq!(fx.queued().len(), 1);
}

#[test]
fn compact_left_unsubmitted_is_never_typed_again() {
    let mut fx = fixture();
    fx.at(500_000);
    fx.host
        .with(|world| world.refuse = vec![SendOutcome::Unsubmitted]);
    fx.turn_ends(T0);
    fx.step(Status::Idle, T0 + 5_000);
    assert!(fx.sends().is_empty());
    assert!(fx.queued().is_empty());
}

#[test]
fn it_compacts_again_only_after_a_reading_under_the_threshold() {
    let mut fx = fixture();
    fx.at(450_000);
    fx.turn_ends(T0);
    fx.compaction_runs(T0 + 1_000, 60_000);
    assert_eq!(fx.sends().len(), 1);
    // The compaction left it full: not again every turn.
    fx.turn_ends(T0 + 120_000);
    fx.turn_ends(T0 + 180_000);
    assert_eq!(fx.sends().len(), 1);
    // Under the threshold re-arms it.
    fx.at(30_000);
    fx.turn_ends(T0 + 240_000);
    fx.at(420_000);
    fx.turn_ends(T0 + 300_000);
    assert_eq!(fx.sends().len(), 2);
}

#[test]
fn the_compactions_own_finish_is_not_a_turn_to_decide_on() {
    let mut fx = fixture();
    fx.at(450_000);
    fx.turn_ends(T0);
    fx.at(30_000);
    fx.compaction_runs(T0 + 1_000, 30_000);
    assert_eq!(
        fx.host.with(|world| world.reads),
        1,
        "its end is not read as a turn end"
    );
}

#[test]
fn a_model_with_no_known_window_is_never_compacted_and_said_once() {
    let mut fx = fixture();
    fx.context(900_000, "claude-opus-4-5", None);
    fx.turn_ends(T0);
    fx.turn_ends(T0 + 60_000);
    assert!(fx.sends().is_empty());
    // Each model once, however the Worker switches between them.
    fx.context(900_000, "claude-opus-4-1", None);
    fx.turn_ends(T0 + 120_000);
    fx.context(900_000, "claude-opus-4-5", None);
    fx.turn_ends(T0 + 180_000);
    let queued = fx.queued();
    assert_eq!(queued.len(), 2, "{queued:?}");
    assert_eq!(queued[0].status.as_deref(), Some("not_compacted"));
    assert_eq!(queued[0].priority, Priority::RideAlong);
    assert!(
        queued[0].summary.contains("claude-opus-4-5"),
        "{}",
        queued[0].summary
    );
}

#[test]
fn only_the_running_routers_workers_are_compacted() {
    let mut fx = fixture();
    fx.at(900_000);
    fx.compaction.turn_finished(&worker(Status::Idle), T0);
    fx.compaction
        .step(&[worker(Status::Idle)], None, &fx.drain, T0);
    fx.workers.clear();
    fx.turn_ends(T0 + 1_000);
    let user = SessionRow {
        is_worker: false,
        ..worker(Status::Idle)
    };
    fx.compaction.turn_finished(&user, T0 + 2_000);
    fx.workers.insert(WORKER.into());
    fx.step(Status::Idle, T0 + 3_000);
    assert!(fx.sends().is_empty());
}

#[test]
fn the_host_owns_the_turn_its_compaction_starts() {
    let mut fx = fixture();
    fx.at(450_000);
    fx.turn_ends(T0);
    let sent = T0;
    assert_eq!(fx.compaction.compaction_sent_at(WORKER, sent - 1), None);
    fx.step(Status::Busy, sent + 1_000);
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, sent + 1_000),
        Some(sent)
    );
    // Its quiet end: the next step still knows it.
    fx.step(Status::Idle, sent + 40_000);
    fx.step(Status::Idle, sent + 41_000);
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, sent + 1_000),
        Some(sent)
    );
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, sent + 40_001),
        None,
        "a turn after it ended is not it"
    );
    fx.step(Status::Idle, sent + 40_000 + CLAIM_GRACE_MS + 1);
    assert_eq!(fx.compaction.compaction_sent_at(WORKER, sent + 1_000), None);
}

#[test]
fn a_compaction_that_never_starts_owns_nothing_and_tells_nobody() {
    let mut fx = fixture();
    fx.at(450_000);
    fx.turn_ends(T0);
    fx.step(Status::Idle, T0 + START_MS + 1);
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, T0 + START_MS + 2),
        None
    );
    assert_eq!(fx.compaction.compaction_sent_at(WORKER, T0 + 1_000), None);
    assert!(fx.queued().is_empty(), "nothing was compacted");
    assert!(fx.armed(), "the next full turn end compacts");
    fx.turn_ends(T0 + 60_000);
    assert_eq!(fx.sends().len(), 2);
}

#[test]
fn writing_to_other_sessions_denied_is_never_typed_through() {
    let mut fx = fixture();
    fx.host.with(|world| world.deny = true);
    fx.at(500_000);
    fx.turn_ends(T0);
    fx.host.with(|world| world.deny = false);
    fx.step(Status::Idle, T0 + 1_000);
    assert!(fx.sends().is_empty(), "dropped for that turn");
}

#[test]
fn a_scheduled_run_is_never_compacted() {
    let mut fx = fixture();
    let run = SessionRow {
        spawned_by: Some("schedule:sch_1".into()),
        ..worker(Status::Idle)
    };
    assert!(is_run_session(&run));
    fx.at(900_000);
    fx.compaction.turn_finished(&run, T0);
    fx.step_row(run.clone(), T0);
    fx.step_row(run, T0 + 1_000);
    assert!(fx.sends().is_empty());
    assert_eq!(fx.host.with(|world| world.reads), 0);
}

#[test]
fn a_runtime_with_no_compact_command_is_never_compacted() {
    let mut fx = fixture();
    fx.at(900_000);
    fx.host.with(|world| {
        if let Some(reading) = world.readings.get_mut(WORKER) {
            reading.compact_command = None;
        }
    });
    fx.turn_ends(T0);
    fx.step(Status::Idle, T0 + 1_000);
    assert!(fx.sends().is_empty());
}

/// The Router restarting mid-compaction (a Resume) must not hear the
/// compaction's finish as the Worker's.
#[test]
fn a_compaction_keeps_its_claim_while_the_router_is_away() {
    let mut fx = fixture();
    fx.at(450_000);
    fx.turn_ends(T0);
    fx.step(Status::Busy, T0 + 1_000);
    fx.compaction
        .step(&[worker(Status::Busy)], None, &fx.drain, T0 + 2_000);
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, T0 + 1_000),
        Some(T0)
    );
    fx.step(Status::Busy, T0 + 3_000);
    fx.compaction
        .turn_finished(&worker(Status::Idle), T0 + 30_000);
    assert_eq!(
        fx.compaction.compaction_sent_at(WORKER, T0 + 1_000),
        Some(T0)
    );
}
