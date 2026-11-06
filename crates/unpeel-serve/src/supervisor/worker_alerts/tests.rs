use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use unpeel_core::activity_log::ActivityLogKind;
use unpeel_core::program_status::{BlockedKind, ProgramState, ProgramStatusSummary};
use unpeel_core::session_inbox::{InboxItem, ItemKind, NewItem, Priority, Sender, Store};
use unpeel_core::supervision::SupervisorConfig;

use super::*;
use crate::sessions::{SessionRow, Status, StatusSource};
use crate::supervisor::inbox_drain::NoticeKind;
use crate::supervisor::worker_host::{Exit, WorkerHost};

const T0: u64 = 1_800_000_000_000;
const MIN: u64 = 60_000;
const ROUTER: &str = "router";
const WORKER: &str = "w1";

#[derive(Default)]
struct World {
    router: Option<String>,
    config: SupervisorConfig,
    markers: HashMap<String, String>,
    exits: HashMap<String, Exit>,
    progress: HashMap<String, u64>,
    heartbeat: Option<u64>,
    heartbeats_written: Vec<u64>,
}

#[derive(Default)]
struct FakeHost(Mutex<World>);

impl FakeHost {
    fn with<T>(&self, change: impl FnOnce(&mut World) -> T) -> T {
        change(&mut self.0.lock().unwrap())
    }
}

impl WorkerHost for FakeHost {
    fn router_and_config(&self) -> (Option<String>, SupervisorConfig) {
        self.with(|world| (world.router.clone(), world.config))
    }
    fn worker_router(&self, session_id: &str) -> Option<String> {
        self.with(|world| world.markers.get(session_id).cloned())
    }
    fn running(&self, _session_id: &str) -> bool {
        true
    }
    fn exit(&self, session_id: &str) -> Option<Exit> {
        self.with(|world| world.exits.get(session_id).copied())
    }
    fn durable_progress(&self, row: &SessionRow) -> Option<u64> {
        self.with(|world| world.progress.get(&row.id).copied())
    }
    fn heartbeat(&self) -> Option<u64> {
        self.with(|world| world.heartbeat)
    }
    fn write_heartbeat(&self, at_ms: u64) {
        self.with(|world| world.heartbeats_written.push(at_ms));
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
    alerts: WorkerAlerts,
}

/// A running Router with one Worker, the supervisor started at `T0`.
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::at(tmp.path().join("session-inboxes"));
    let host = Arc::new(FakeHost::default());
    host.with(|world| {
        world.router = Some(ROUTER.into());
        world.markers.insert(WORKER.into(), ROUTER.into());
    });
    let alerts = WorkerAlerts::starting_at(store.clone(), host.clone(), T0);
    Fixture {
        _tmp: tmp,
        store,
        host,
        drain: FakeDrain::default(),
        alerts,
    }
}

fn row(id: &str, status: Status) -> SessionRow {
    SessionRow {
        host_started_at: None,
        id: id.into(),
        project_id: "p".into(),
        label: if id == WORKER { "fix-login" } else { "" }.into(),
        command: "claude".into(),
        active_runtime_id: Some("claude".into()),
        active_app: None,
        resume_available: false,
        resumable: true,
        resume_agent_available: false,
        running: status != Status::Exited,
        status,
        status_source: if status == Status::Exited {
            StatusSource::None
        } else {
            StatusSource::Program
        },
        program_status: None,
        created_at: 1,
        pinned: false,
        unread: false,
        latest_alert_body: None,
        cwd: "/tmp".into(),
        activity_at: 1,
        group_id: "p".into(),
        detected_local_urls: Vec::new(),
        is_worker: id != ROUTER && id != "user",
        is_router: id == ROUTER,
    }
}

fn worker(status: Status) -> SessionRow {
    row(WORKER, status)
}

fn program(state: ProgramState, last_finished_at: Option<u64>) -> Option<ProgramStatusSummary> {
    Some(ProgramStatusSummary {
        state,
        kind: None,
        progress: None,
        app: None,
        title: None,
        msg: None,
        id: None,
        changed_at: T0,
        last_non_idle_at: None,
        last_finished_at,
        finished_edges: u64::from(last_finished_at.is_some()),
    })
}

impl Fixture {
    /// One rescan: the Router and these rows.
    fn step(&mut self, rows: &[SessionRow], now: u64) -> Vec<Notice> {
        let mut all = vec![row(ROUTER, Status::Idle)];
        all.extend(rows.iter().cloned());
        self.alerts.step(&all, now)
    }

    fn divert(
        &mut self,
        row: &SessionRow,
        kind: ActivityLogKind,
        body: Option<&str>,
        now: u64,
    ) -> bool {
        self.alerts.divert(row, kind, body, now, &self.drain)
    }

    /// A Worker turn the supervisor watched start at `start`.
    fn turn(&mut self, start: u64) {
        self.step(&[worker(Status::Idle)], start - 1_000);
        self.step(&[worker(Status::Busy)], start);
    }

    fn queued(&self) -> Vec<InboxItem> {
        let listing = self.store.list(ROUTER).unwrap();
        listing
            .pending
            .iter()
            .map(|header| self.store.item(ROUTER, &header.id).unwrap().unwrap())
            .collect()
    }

    fn statuses(&self) -> Vec<String> {
        self.queued()
            .iter()
            .map(|item| item.status.clone().unwrap_or_default())
            .collect()
    }

    fn report_from_worker(&self, status: &str, at: u64) {
        self.store
            .enqueue(
                ROUTER,
                NewItem {
                    sender: Sender::Session(WORKER.into()),
                    kind: ItemKind::Report,
                    priority: Priority::Wake,
                    about: None,
                    status: Some(status.into()),
                    label: None,
                    summary: "done it".into(),
                    body: String::new(),
                    dedupe_key: None,
                },
                at,
            )
            .unwrap();
    }
}

// --- Edge mapping -----------------------------------------------------------

#[test]
fn a_worker_finishing_queues_a_wake_finished_notice_with_its_reply() {
    let mut fx = fixture();
    fx.drain.pastes.push((WORKER.into(), T0 + 9_500));
    fx.turn(T0 + 10_000);
    let diverted = fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("Fixed the login form."),
        T0 + 60_000,
    );
    assert!(diverted, "the user is not notified");
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    let notice = &queued[0];
    // The exact shape the Router's Worker cards read.
    assert_eq!(notice.sender, Sender::Host);
    assert_eq!(notice.kind, ItemKind::Lifecycle);
    assert_eq!(notice.priority, Priority::Wake);
    assert_eq!(notice.about.as_deref(), Some(WORKER));
    assert_eq!(notice.status.as_deref(), Some("finished"));
    assert_eq!(notice.label.as_deref(), Some("fix-login"));
    assert_eq!(notice.summary, "\"fix-login\" finished.");
    assert_eq!(notice.body, "Fixed the login form.");
}

#[test]
fn edges_of_sessions_that_are_not_a_running_routers_workers_go_to_the_user() {
    let mut fx = fixture();
    let user = row("user", Status::Idle);
    assert!(!fx.divert(&user, ActivityLogKind::Finished, Some("hi"), T0));
    // A marker naming some other Router.
    fx.host
        .with(|world| world.markers.insert(WORKER.into(), "old-router".into()));
    assert!(!fx.divert(&worker(Status::Idle), ActivityLogKind::Finished, None, T0));
    // No Router at all.
    fx.host.with(|world| {
        world.markers.insert(WORKER.into(), ROUTER.into());
        world.router = None;
    });
    assert!(!fx.divert(&worker(Status::Idle), ActivityLogKind::NeedsInput, None, T0));
    assert!(fx.queued().is_empty());
}

#[test]
fn a_stopped_routers_workers_notify_the_user_as_before() {
    let mut fx = fixture();
    fx.alerts
        .step(&[row(ROUTER, Status::Exited), worker(Status::Busy)], T0);
    assert!(!fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        None,
        T0 + 1_000
    ));
    assert!(fx.queued().is_empty());
}

#[test]
fn a_finish_after_a_report_this_turn_queues_nothing_more() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.report_from_worker("done", T0 + 50_000);
    assert!(fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("ok"),
        T0 + 60_000
    ));
    assert_eq!(fx.queued().len(), 1, "only the report");
}

#[test]
fn a_report_from_an_earlier_turn_or_a_progress_report_does_not_count() {
    let mut fx = fixture();
    fx.report_from_worker("done", T0 + 1_000);
    fx.turn(T0 + 10_000);
    fx.report_from_worker("progress", T0 + 20_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("ok"),
        T0 + 60_000,
    );
    assert_eq!(fx.statuses(), ["done", "progress", "finished"]);
}

#[test]
fn a_worker_waiting_on_a_prompt_queues_a_wake_needs_input_notice() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    let waiting = SessionRow {
        program_status: Some(ProgramStatusSummary {
            kind: Some(BlockedKind::Permission),
            msg: Some("Approve deploy?".into()),
            ..program(ProgramState::Blocked, None).unwrap()
        }),
        ..worker(Status::Attention)
    };
    assert!(fx.divert(&waiting, ActivityLogKind::NeedsInput, None, T0 + 20_000));
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    assert_eq!(queued[0].priority, Priority::Wake);
    assert_eq!(queued[0].status.as_deref(), Some("needs_input"));
    assert_eq!(
        queued[0].summary,
        "\"fix-login\" is waiting for input (permission prompt)."
    );
    assert_eq!(queued[0].body, "Approve deploy?");
}

#[test]
fn a_clean_exit_rides_along() {
    let mut fx = fixture();
    fx.step(&[worker(Status::Idle)], T0);
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(0),
                at: T0 + 5_000,
            },
        )
    });
    assert!(fx.divert(
        &worker(Status::Exited),
        ActivityLogKind::Exited,
        None,
        T0 + 6_000
    ));
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    assert_eq!(
        (
            queued[0].kind,
            queued[0].priority,
            queued[0].status.as_deref()
        ),
        (ItemKind::Lifecycle, Priority::RideAlong, Some("exited"))
    );
    assert_eq!(queued[0].summary, "\"fix-login\" exited with code 0.");
}

#[test]
fn exiting_while_busy_or_with_a_failing_code_wakes_the_router_once() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(137),
                at: T0 + 20_000,
            },
        )
    });
    fx.divert(
        &worker(Status::Exited),
        ActivityLogKind::Exited,
        None,
        T0 + 21_000,
    );
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    assert_eq!(
        (
            queued[0].kind,
            queued[0].priority,
            queued[0].status.as_deref()
        ),
        (
            ItemKind::Watchdog,
            Priority::Wake,
            Some("exited_unexpectedly")
        )
    );
    assert_eq!(
        queued[0].summary,
        "\"fix-login\" exited unexpectedly with code 137 while busy."
    );

    // An idle Worker exiting with a failing code is unexpected too.
    let mut fx = fixture();
    fx.step(&[worker(Status::Idle)], T0);
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(1),
                at: T0 + 2_000,
            },
        )
    });
    fx.divert(
        &worker(Status::Exited),
        ActivityLogKind::Exited,
        None,
        T0 + 3_000,
    );
    assert_eq!(fx.statuses(), ["exited_unexpectedly"]);
}

#[test]
fn started_is_quiet_unless_the_setting_asks_for_it() {
    let mut fx = fixture();
    assert!(fx.divert(
        &worker(Status::Starting),
        ActivityLogKind::Started,
        None,
        T0
    ));
    assert!(fx.queued().is_empty());
    fx.host.with(|world| world.config.notify_started = true);
    fx.divert(
        &worker(Status::Starting),
        ActivityLogKind::Started,
        None,
        T0 + 1_000,
    );
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    assert_eq!(
        (queued[0].priority, queued[0].status.as_deref()),
        (Priority::RideAlong, Some("started"))
    );
}

// --- Self-caused edges and user-typed turns ---------------------------------

#[test]
fn the_routers_own_stop_produces_no_notice() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.store.touch_router(WORKER, T0 + 60_000).unwrap();
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(0),
                at: T0 + 68_000,
            },
        )
    });
    assert!(fx.divert(
        &worker(Status::Exited),
        ActivityLogKind::Exited,
        None,
        T0 + 69_000
    ));
    assert!(fx.queued().is_empty());
}

#[test]
fn the_routers_interrupt_or_menu_produces_no_notice() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.store.touch_router(WORKER, T0 + 60_000).unwrap();
    // An interrupted turn: idle again with no reply.
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        None,
        T0 + 62_000,
    );
    // A menu the Router's keys opened.
    fx.store.touch_router(WORKER, T0 + 70_000).unwrap();
    fx.divert(
        &worker(Status::Attention),
        ActivityLogKind::NeedsInput,
        None,
        T0 + 71_000,
    );
    assert!(fx.queued().is_empty());
}

#[test]
fn what_the_worker_does_after_a_router_write_is_still_reported() {
    let mut fx = fixture();
    fx.step(&[worker(Status::Idle)], T0);
    fx.store.touch_router(WORKER, T0 + 1_000).unwrap();
    // The write started a turn that answered quickly...
    fx.step(&[worker(Status::Busy)], T0 + 2_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        None,
        T0 + 4_000,
    );
    // ...and a reply always counts, whenever the Router last wrote.
    fx.store.touch_router(WORKER, T0 + 5_000).unwrap();
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("4"),
        T0 + 6_000,
    );
    assert_eq!(fx.statuses(), ["finished", "finished"]);
    // A touch older than the window is not the cause.
    fx.store.touch_router(WORKER, T0 + 10_000).unwrap();
    fx.divert(
        &worker(Status::Attention),
        ActivityLogKind::NeedsInput,
        None,
        T0 + 16_000,
    );
    assert_eq!(fx.statuses(), ["finished", "finished", "needs_input"]);
}

#[test]
fn a_turn_the_user_typed_says_so() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("hi!"),
        T0 + 30_000,
    );
    assert_eq!(
        fx.queued()[0].summary,
        "\"fix-login\" finished after the user talked to it directly; its reply was for the \
         user, not a report to you."
    );
    assert_eq!(fx.queued()[0].status.as_deref(), Some("finished"));
}

#[test]
fn a_turn_started_by_a_host_paste_or_a_router_write_is_the_workers_own() {
    let mut fx = fixture();
    fx.drain.pastes.push((WORKER.into(), T0 + 8_000));
    fx.turn(T0 + 10_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("a"),
        T0 + 30_000,
    );
    fx.store.touch_router(WORKER, T0 + 37_000).unwrap();
    fx.turn(T0 + 40_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("b"),
        T0 + 50_000,
    );
    let summaries: Vec<String> = fx.queued().into_iter().map(|item| item.summary).collect();
    assert_eq!(
        summaries,
        ["\"fix-login\" finished.", "\"fix-login\" finished."]
    );
}

#[test]
fn a_turn_whose_start_was_not_watched_is_never_called_user_typed() {
    let mut fx = fixture();
    // First seen already busy (a Host restart mid-turn).
    fx.step(&[worker(Status::Busy)], T0 + 1_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("a"),
        T0 + 30_000,
    );
    assert_eq!(fx.queued()[0].summary, "\"fix-login\" finished.");
}

#[test]
fn a_prompt_submit_hook_dates_the_turn() {
    let mut fx = fixture();
    fx.step(&[worker(Status::Idle)], T0);
    fx.drain.pastes.push((WORKER.into(), T0 + 4_000));
    fx.alerts
        .observe_hook(WORKER, "UserPromptSubmit", T0 + 4_500);
    // The step that sees Busy comes later than the hook.
    fx.step(&[worker(Status::Busy)], T0 + 16_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("a"),
        T0 + 30_000,
    );
    assert_eq!(fx.queued()[0].summary, "\"fix-login\" finished.");
}

// --- Escalation -----------------------------------------------------------

fn waiting_from(fx: &mut Fixture, at: u64) {
    fx.step(&[worker(Status::Busy)], at - 1_000);
    fx.divert(
        &worker(Status::Attention),
        ActivityLogKind::NeedsInput,
        None,
        at,
    );
    fx.step(&[worker(Status::Attention)], at);
}

#[test]
fn a_worker_prompt_unanswered_for_five_minutes_notifies_the_user_once() {
    let mut fx = fixture();
    waiting_from(&mut fx, T0 + 10_000);
    assert!(fx
        .step(&[worker(Status::Attention)], T0 + 10_000 + 5 * MIN - 1)
        .is_empty());
    let notices = fx.step(&[worker(Status::Attention)], T0 + 10_000 + 5 * MIN);
    assert_eq!(
        notices,
        [Notice {
            session_id: WORKER.into(),
            body: "Waiting for your input for 5 min; the Super Agent has not answered.".into(),
            kind: NoticeKind::NeedsInput,
        }]
    );
    assert!(fx
        .step(&[worker(Status::Attention)], T0 + 20 * MIN)
        .is_empty());

    // Answered, then a new prompt: a new episode.
    fx.step(&[worker(Status::Busy)], T0 + 21 * MIN);
    waiting_from(&mut fx, T0 + 22 * MIN);
    assert_eq!(
        fx.step(&[worker(Status::Attention)], T0 + 27 * MIN).len(),
        1
    );
}

#[test]
fn a_prompt_the_user_was_already_told_about_never_escalates() {
    let mut fx = fixture();
    fx.host.with(|world| world.router = None);
    waiting_from(&mut fx, T0 + 10_000);
    assert!(fx
        .step(&[worker(Status::Attention)], T0 + 30 * MIN)
        .is_empty());
}

#[test]
fn escalation_can_be_turned_off() {
    let mut fx = fixture();
    fx.host.with(|world| world.config.escalate_ms = 0);
    waiting_from(&mut fx, T0 + 10_000);
    assert!(fx
        .step(&[worker(Status::Attention)], T0 + 60 * MIN)
        .is_empty());
}

// --- Watchdog -------------------------------------------------------------

fn stall_config(fx: &Fixture) {
    fx.host.with(|world| world.config.stall_ms = 5 * MIN);
}

#[test]
fn a_busy_worker_with_no_progress_is_reported_stalled_once() {
    let mut fx = fixture();
    stall_config(&fx);
    fx.turn(T0 + 10_000);
    fx.step(&[worker(Status::Busy)], T0 + 10_000 + 5 * MIN - 1);
    assert!(fx.queued().is_empty());
    fx.step(&[worker(Status::Busy)], T0 + 10_000 + 5 * MIN);
    fx.step(&[worker(Status::Busy)], T0 + 10_000 + 9 * MIN);
    let queued = fx.queued();
    assert_eq!(queued.len(), 1, "once per episode");
    assert_eq!(
        (
            queued[0].kind,
            queued[0].priority,
            queued[0].status.as_deref()
        ),
        (ItemKind::Watchdog, Priority::Wake, Some("stalled"))
    );
    assert_eq!(queued[0].about.as_deref(), Some(WORKER));
    assert_eq!(
        queued[0].summary,
        "\"fix-login\" is stalled: busy for 5 min, no progress for 5 min."
    );
}

#[test]
fn hook_events_program_reports_and_durable_stamps_are_progress() {
    let mut fx = fixture();
    stall_config(&fx);
    fx.turn(T0 + 10_000);
    fx.alerts.observe_hook(WORKER, "PreToolUse", T0 + 3 * MIN);
    fx.step(&[worker(Status::Busy)], T0 + 6 * MIN);
    assert!(fx.queued().is_empty(), "a tool hook 3 min ago");

    let reporting = SessionRow {
        program_status: Some(ProgramStatusSummary {
            changed_at: T0 + 7 * MIN,
            ..program(ProgramState::Working, None).unwrap()
        }),
        ..worker(Status::Busy)
    };
    fx.step(std::slice::from_ref(&reporting), T0 + 10 * MIN);
    assert!(fx.queued().is_empty(), "a program report 3 min ago");

    fx.host
        .with(|world| world.progress.insert(WORKER.into(), T0 + 9 * MIN));
    fx.step(std::slice::from_ref(&reporting), T0 + 13 * MIN);
    assert!(fx.queued().is_empty(), "a durable stamp 4 min ago");
    fx.step(std::slice::from_ref(&reporting), T0 + 14 * MIN);
    assert_eq!(fx.statuses(), ["stalled"]);
}

#[test]
fn a_restart_never_counts_time_from_before_the_supervisor_started() {
    let mut fx = fixture();
    stall_config(&fx);
    // Busy for an hour already, last progress long ago.
    fx.host
        .with(|world| world.progress.insert(WORKER.into(), T0 - 60 * MIN));
    let busy = SessionRow {
        program_status: Some(ProgramStatusSummary {
            changed_at: T0 - 60 * MIN,
            ..program(ProgramState::Working, None).unwrap()
        }),
        ..worker(Status::Busy)
    };
    fx.step(std::slice::from_ref(&busy), T0);
    fx.step(std::slice::from_ref(&busy), T0 + 5 * MIN - 1);
    assert!(fx.queued().is_empty());
    fx.step(std::slice::from_ref(&busy), T0 + 5 * MIN);
    assert_eq!(fx.statuses(), ["stalled"]);
}

#[test]
fn a_worker_left_waiting_is_reported_blocked() {
    let mut fx = fixture();
    waiting_from(&mut fx, T0 + 10_000);
    fx.step(&[worker(Status::Attention)], T0 + 10_000 + 10 * MIN);
    fx.step(&[worker(Status::Attention)], T0 + 10_000 + 11 * MIN);
    assert_eq!(fx.statuses(), ["needs_input", "blocked"]);
}

#[test]
fn a_turn_that_ends_without_finishing_went_quiet() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.step(&[worker(Status::Idle)], T0 + 20_000);
    fx.step(&[worker(Status::Idle)], T0 + 21_000);
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    assert_eq!(
        (queued[0].kind, queued[0].status.as_deref()),
        (ItemKind::Watchdog, Some("went_quiet"))
    );
}

#[test]
fn a_turn_that_finished_never_went_quiet() {
    let mut fx = fixture();
    fx.drain.pastes.push((WORKER.into(), T0 + 9_000));
    fx.turn(T0 + 10_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("ok"),
        T0 + 20_000,
    );
    fx.step(&[worker(Status::Idle)], T0 + 20_000);
    fx.step(&[worker(Status::Idle)], T0 + 21_000);
    assert_eq!(fx.statuses(), ["finished"]);
}

#[test]
fn a_finished_edge_one_rescan_late_still_counts() {
    let mut fx = fixture();
    fx.drain.pastes.push((WORKER.into(), T0 + 9_000));
    fx.turn(T0 + 10_000);
    fx.step(&[worker(Status::Idle)], T0 + 20_000);
    fx.divert(
        &worker(Status::Idle),
        ActivityLogKind::Finished,
        Some("ok"),
        T0 + 21_000,
    );
    fx.step(&[worker(Status::Idle)], T0 + 21_000);
    fx.step(&[worker(Status::Idle)], T0 + 22_000);
    assert_eq!(fx.statuses(), ["finished"]);
}

/// A Worker whose busy/idle comes from its screen (or from nothing): that
/// tier never produces a Finished edge.
fn screen_worker(status: Status, source: StatusSource) -> SessionRow {
    SessionRow {
        status_source: source,
        ..worker(status)
    }
}

/// One screen-detected turn: Busy at `start`, Idle 10 s later, then idle
/// rescans.
fn screen_turn(fx: &mut Fixture, start: u64, idle_source: StatusSource) {
    fx.step(&[screen_worker(Status::Idle, idle_source)], start - 1_000);
    fx.step(&[screen_worker(Status::Busy, StatusSource::Screen)], start);
    for at in [start + 10_000, start + 11_000, start + 12_000] {
        fx.step(&[screen_worker(Status::Idle, idle_source)], at);
    }
}

#[test]
fn a_screen_detected_turn_end_is_a_finished_notice_not_went_quiet() {
    let mut fx = fixture();
    fx.drain.pastes.push((WORKER.into(), T0 + 9_000));
    screen_turn(&mut fx, T0 + 10_000, StatusSource::Screen);
    let queued = fx.queued();
    assert_eq!(queued.len(), 1);
    let notice = &queued[0];
    // The shape the Router's Worker cards read as a Finished notice.
    assert_eq!(
        (notice.sender.clone(), notice.kind, notice.priority),
        (Sender::Host, ItemKind::Lifecycle, Priority::Wake)
    );
    assert_eq!(notice.about.as_deref(), Some(WORKER));
    assert_eq!(notice.status.as_deref(), Some("finished"));
    assert_eq!(
        notice.summary,
        "\"fix-login\" finished (screen-detected: no reply was captured; read its screen \
         for the result)."
    );
    assert!(notice.body.is_empty());
}

#[test]
fn a_screen_detected_finish_comes_once_per_busy_to_idle() {
    let mut fx = fixture();
    screen_turn(&mut fx, T0 + 10_000, StatusSource::None);
    screen_turn(&mut fx, T0 + 40_000, StatusSource::Screen);
    assert_eq!(fx.statuses(), ["finished", "finished"]);
}

#[test]
fn a_screen_detected_finish_after_a_report_this_turn_queues_nothing_more() {
    let mut fx = fixture();
    fx.report_from_worker("done", T0 + 15_000);
    screen_turn(&mut fx, T0 + 10_000, StatusSource::Screen);
    assert_eq!(fx.queued().len(), 1, "only the report");
}

#[test]
fn a_hook_turn_that_ends_without_finishing_still_went_quiet() {
    let mut fx = fixture();
    let hooks = |status| screen_worker(status, StatusSource::Hooks);
    fx.step(&[hooks(Status::Idle)], T0 + 9_000);
    fx.step(&[hooks(Status::Busy)], T0 + 10_000);
    fx.step(&[hooks(Status::Idle)], T0 + 20_000);
    fx.step(&[hooks(Status::Idle)], T0 + 21_000);
    assert_eq!(fx.statuses(), ["went_quiet"]);
}

#[test]
fn the_router_interrupting_its_worker_is_not_went_quiet() {
    let mut fx = fixture();
    fx.turn(T0 + 10_000);
    fx.store.touch_router(WORKER, T0 + 19_000).unwrap();
    fx.step(&[worker(Status::Idle)], T0 + 20_000);
    fx.step(&[worker(Status::Idle)], T0 + 21_000);
    assert!(fx.queued().is_empty());
}

#[test]
fn the_watchdog_watches_only_a_running_routers_workers() {
    let mut fx = fixture();
    stall_config(&fx);
    fx.host.with(|world| world.router = None);
    fx.turn(T0 + 10_000);
    fx.step(&[worker(Status::Busy)], T0 + 30 * MIN);
    let user = row("user", Status::Busy);
    fx.host.with(|world| world.router = Some(ROUTER.into()));
    fx.step(std::slice::from_ref(&user), T0 + 31 * MIN);
    fx.step(std::slice::from_ref(&user), T0 + 60 * MIN);
    assert!(fx.store.list(ROUTER).unwrap().pending.is_empty());
}

// --- Auto-stop ------------------------------------------------------------

#[test]
fn auto_stop_never_sees_the_router_its_running_workers_or_a_pending_inbox() {
    let mut fx = fixture();
    let stopped_worker = SessionRow {
        id: "w2".into(),
        ..worker(Status::Exited)
    };
    fx.host
        .with(|world| world.markers.insert("w2".into(), ROUTER.into()));
    let rows = vec![
        row(ROUTER, Status::Idle),
        worker(Status::Idle),
        stopped_worker,
        row("user", Status::Idle),
        row("queued", Status::Idle),
    ];
    fx.alerts.step(&rows, T0);
    fx.drain.pending.insert("queued".into());
    let kept = fx.alerts.auto_stop_rows(&rows, &fx.drain);
    let ids: Vec<&str> = kept.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(ids, ["w2", "user"]);
}

#[test]
fn a_stopped_routers_workers_may_be_auto_stopped() {
    let mut fx = fixture();
    let rows = vec![row(ROUTER, Status::Exited), worker(Status::Idle)];
    fx.alerts.step(&rows, T0);
    let kept = fx.alerts.auto_stop_rows(&rows, &fx.drain);
    let ids: Vec<&str> = kept.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(ids, [WORKER], "the Router itself never is");
}

#[test]
fn without_a_router_auto_stop_sees_every_row() {
    let mut fx = fixture();
    fx.host.with(|world| world.router = None);
    let rows = vec![row("user", Status::Idle), worker(Status::Idle)];
    fx.alerts.step(&rows, T0);
    assert!(matches!(
        fx.alerts.auto_stop_rows(&rows, &fx.drain),
        std::borrow::Cow::Borrowed(_)
    ));
}

// --- Restart reconciliation -------------------------------------------------

#[test]
fn on_start_what_workers_did_while_the_host_was_down_reaches_the_router() {
    let mut fx = fixture();
    fx.host.with(|world| {
        world.heartbeat = Some(T0 - 10 * MIN);
        world.markers.insert("w2".into(), ROUTER.into());
        world.markers.insert("w3".into(), ROUTER.into());
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(1),
                at: T0 - 5 * MIN,
            },
        );
        world.exits.insert(
            "w2".into(),
            Exit {
                code: Some(0),
                at: T0 - 20 * MIN,
            },
        );
    });
    let finished = SessionRow {
        id: "w3".into(),
        program_status: Some(ProgramStatusSummary {
            msg: Some("All tests pass".into()),
            ..program(ProgramState::Done, Some(T0 - 2 * MIN)).unwrap()
        }),
        ..worker(Status::Idle)
    };
    let gone_long_ago = SessionRow {
        id: "w2".into(),
        ..worker(Status::Exited)
    };
    fx.step(
        &[worker(Status::Exited), gone_long_ago, finished.clone()],
        T0,
    );
    let queued = fx.queued();
    let seen: Vec<(Option<&str>, Option<&str>)> = queued
        .iter()
        .map(|item| (item.about.as_deref(), item.status.as_deref()))
        .collect();
    assert_eq!(
        seen,
        [
            (Some(WORKER), Some("exited_unexpectedly")),
            (Some("w3"), Some("finished"))
        ]
    );
    assert_eq!(queued[1].body, "All tests pass");
    // Only on start.
    fx.step(&[worker(Status::Exited), finished], T0 + 1_000);
    assert_eq!(fx.queued().len(), 2);
}

#[test]
fn reconciliation_never_repeats_a_notice_the_router_already_has() {
    let mut fx = fixture();
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(1),
                at: T0 + 5_000,
            },
        )
    });
    fx.step(&[worker(Status::Busy)], T0);
    fx.divert(
        &worker(Status::Exited),
        ActivityLogKind::Exited,
        None,
        T0 + 6_000,
    );
    assert_eq!(fx.queued().len(), 1);

    // The Host restarts.
    let host = fx.host.clone();
    host.with(|world| world.heartbeat = Some(T0 + 1_000));
    let mut restarted = WorkerAlerts::starting_at(fx.store.clone(), host, T0 + 60_000);
    restarted.step(
        &[row(ROUTER, Status::Idle), worker(Status::Exited)],
        T0 + 60_000,
    );
    assert_eq!(fx.queued().len(), 1);
}

#[test]
fn reconciliation_skips_the_routers_own_stops_and_needs_a_heartbeat() {
    let mut fx = fixture();
    fx.host.with(|world| {
        world.heartbeat = Some(T0 - 10 * MIN);
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(0),
                at: T0 - 5 * MIN,
            },
        )
    });
    fx.store.touch_router(WORKER, T0 - 5 * MIN - 3_000).unwrap();
    fx.step(&[worker(Status::Exited)], T0);
    assert!(fx.queued().is_empty(), "the Router stopped it itself");

    let mut fx = fixture();
    fx.host.with(|world| {
        world.exits.insert(
            WORKER.into(),
            Exit {
                code: Some(1),
                at: T0 - 5 * MIN,
            },
        )
    });
    fx.step(&[worker(Status::Exited)], T0);
    assert!(
        fx.queued().is_empty(),
        "no earlier supervisor: nothing to catch up on"
    );
}

#[test]
fn a_heartbeat_is_kept_while_a_router_exists() {
    let mut fx = fixture();
    fx.step(&[], T0);
    fx.step(&[], T0 + 10_000);
    fx.step(&[], T0 + HEARTBEAT_MS);
    assert_eq!(
        fx.host.with(|world| world.heartbeats_written.clone()),
        [T0, T0 + HEARTBEAT_MS]
    );
    fx.host.with(|world| world.router = None);
    fx.step(&[], T0 + 5 * HEARTBEAT_MS);
    assert_eq!(fx.host.with(|world| world.heartbeats_written.len()), 2);
}
