//! Fork-only: unit tests for the Inbox drain, against a temp store and a fake Host.

use super::*;
use crate::sessions::{SessionRow, Status, StatusSource};
use crate::supervisor::inbox_rules::RIDE_ALONG_PROMOTE_MS;
use std::sync::Mutex;
use unpeel_core::session_inbox::{ItemKind, NewItem, Priority, Sender};

const T0: u64 = 1_800_000_000_000;
const MINUTE: u64 = 60_000;

#[derive(Default)]
struct World {
    terminal: TerminalFacts,
    cursor: Option<CursorLine>,
    pastes: Vec<(String, String)>,
    paste_error: Option<String>,
    /// What the guarded paste reports (`Submitted` when unset), and the
    /// `since` each paste was given.
    paste_result: Option<GuardedPaste>,
    paste_since: Vec<u64>,
    /// Whether each paste carried `unless_draft` (#69).
    paste_unless_draft: Vec<bool>,
    /// The PTY core holds a draft of the user's: it refuses a paste with
    /// `unless_draft`.
    core_draft: bool,
    deny: bool,
    config: unpeel_core::supervision::SupervisorConfig,
    ride_along_promote_ms: u64,
    live: HashSet<String>,
    /// State-bus announcements so far.
    announced: usize,
    /// App-state reads for the drain's settings.
    settings_reads: usize,
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
    fn paste(
        &self,
        session_id: &str,
        text: &str,
        since: u64,
        unless_draft: bool,
    ) -> Result<GuardedPaste, String> {
        self.with(|world| {
            world.paste_since.push(since);
            world.paste_unless_draft.push(unless_draft);
            if let Some(error) = world.paste_error.clone() {
                return Err(error);
            }
            let result = if unless_draft && world.core_draft {
                GuardedPaste::NotPasted(Refusal::Draft)
            } else {
                world.paste_result.unwrap_or(GuardedPaste::Submitted)
            };
            if !matches!(result, GuardedPaste::NotPasted(_)) {
                world.pastes.push((session_id.into(), text.into()));
            }
            Ok(result)
        })
    }
    fn live_session_ids(&self) -> HashSet<String> {
        self.with(|world| world.live.clone())
    }
    fn settings(&self) -> Settings {
        self.with(|world| {
            world.settings_reads += 1;
            Settings {
                config: world.config,
                policy_deny: world.deny,
                ride_along_promote_ms: world.ride_along_promote_ms,
            }
        })
    }
    fn announce(&self) {
        self.with(|world| world.announced += 1);
    }
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
            last_input_at: None,
            draft_guard: true,
        };
        world.cursor = Some(prompt(""));
        world.live = HashSet::from(["router".to_string()]);
        world.ride_along_promote_ms = RIDE_ALONG_PROMOTE_MS;
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

fn progress(fx: &Fixture, summary: &str, at: u64) {
    fx.store
        .enqueue("router", item(summary, "progress", Priority::RideAlong), at)
        .unwrap();
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
        spawned_by: None,
        is_worker: false,
        is_router: false,
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

    fn announced(&self) -> usize {
        self.io.with(|world| world.announced)
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
fn a_ride_along_item_alone_waits_and_goes_with_the_next_wake_item() {
    let mut fx = fixture();
    progress(&fx, "halfway", T0 - 60_000);
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
fn a_ride_along_item_waits_fourteen_minutes_and_starts_a_delivery_at_fifteen() {
    let mut fx = fixture();
    progress(&fx, "halfway", T0);
    let idle = router(Status::Idle);
    fx.step(&idle, T0 + 14 * MINUTE);
    assert!(fx.pastes().is_empty());
    assert_eq!(fx.hold().as_deref(), Some("ride_along"));

    progress(&fx, "nearly there", T0 + 14 * MINUTE);
    fx.step_and_settle(&idle, T0 + 15 * MINUTE);
    let pastes = fx.pastes();
    assert_eq!(pastes.len(), 1, "{pastes:?}");
    assert!(pastes[0].contains("halfway") && pastes[0].contains("nearly there"));
}

#[test]
fn a_restarted_drain_counts_a_ride_along_item_from_its_stored_queue_time() {
    let mut fx = fixture();
    progress(&fx, "halfway", T0);
    let idle = router(Status::Idle);
    fx.step(&idle, T0 + 14 * MINUTE);
    assert_eq!(fx.hold().as_deref(), Some("ride_along"));

    // A Host restart: a new drain over the same Inbox.
    fx.drain = Drain::new(fx.store.clone(), fx.io.clone());
    fx.step_and_settle(&idle, T0 + 15 * MINUTE);
    assert_eq!(fx.pastes().len(), 1, "the clock did not start over");
}

#[test]
fn a_promoted_item_waits_on_a_busy_target_a_menu_and_a_draft_like_a_wake_item() {
    let mut fx = fixture();
    progress(&fx, "halfway", T0);
    let due = T0 + 15 * MINUTE;
    fx.step(&router(Status::Busy), due);
    assert_eq!(fx.hold().as_deref(), Some("busy"));

    let idle = router(Status::Idle);
    fx.io.with(|world| world.terminal.menu_prompt = true);
    fx.step(&idle, due + 1_000);
    assert_eq!(fx.hold().as_deref(), Some("attention"));

    fx.io.with(|world| world.terminal.menu_prompt = false);
    typed(&fx, prompt("next"), due + 9_000);
    fx.step(&idle, due + 10_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert!(fx.pastes().is_empty());

    typed(&fx, prompt(""), due + 11_000);
    fx.step_and_settle(&idle, due + 20_000);
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn only_a_test_host_shortens_the_ride_along_promotion() {
    assert_eq!(ride_along_promote_from(None, None), RIDE_ALONG_PROMOTE_MS);
    assert_eq!(
        ride_along_promote_from(None, Some("5000")),
        RIDE_ALONG_PROMOTE_MS
    );
    assert_eq!(
        ride_along_promote_from(Some("0"), Some("5000")),
        RIDE_ALONG_PROMOTE_MS
    );
    assert_eq!(ride_along_promote_from(Some("1"), Some(" 5000 ")), 5_000);
    assert_eq!(
        ride_along_promote_from(Some("1"), Some("soon")),
        RIDE_ALONG_PROMOTE_MS
    );
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

/// A two-row screen whose second row is the input line `text`, the cursor
/// at `col`, and `suggestion` the faint byte range the Host reported there.
fn input_screen(
    text: &str,
    col: u16,
    suggestion: Option<(u32, u32)>,
) -> unpeel_core::terminal_viewport::TerminalViewportSnapshot {
    let mut snapshot = serde_json::json!({
        "cols": 80, "rows": 2, "outputOffset": 0, "truncated": false,
        "cursorRow": 1, "cursorCol": col, "scrollbackRows": 0,
        "viewportStartRow": 0, "scrollOffsetRows": 0,
        "viewportRows": [{ "text": "", "styles": [] }, { "text": text, "styles": [] }],
    });
    if let Some((start, end)) = suggestion {
        snapshot["suggestedInput"] =
            serde_json::json!({ "row": 1, "byteStart": start, "byteEnd": end });
    }
    serde_json::from_value(snapshot).unwrap()
}

#[test]
fn the_input_line_leaves_out_suggested_input() {
    let empty = cursor_line(&input_screen("> ", 2, None));
    assert_eq!(
        empty,
        CursorLine {
            text: ">".into(),
            col: 2
        }
    );
    let suggested = cursor_line(&input_screen("> leave the epic", 2, Some((2, 16))));
    assert_eq!(suggested, empty, "a suggestion is not typed input");
    let typed = cursor_line(&input_screen("> leave", 7, None));
    assert_ne!(typed, empty);
}

#[test]
fn a_suggestion_appearing_on_the_input_line_does_not_hold_the_paste() {
    let mut fx = fixture();
    fx.io
        .with(|world| world.cursor = Some(cursor_line(&input_screen("> ", 2, None))));
    report(&fx, "result", T0 - 10_000);
    let idle = router(Status::Idle);
    fx.step(&router(Status::Busy), T0);
    // The baseline is the empty prompt; then Claude Code paints its
    // suggested reply there, faint, with the cursor still at its start.
    report(&fx, "more", T0 + 50);
    fx.step(&idle, T0 + 100);
    assert_eq!(fx.hold().as_deref(), Some("debounce"));
    fx.io.with(|world| {
        world.cursor = Some(cursor_line(&input_screen(
            "> leave the epic",
            2,
            Some((2, 16)),
        )));
    });
    fx.step_and_settle(&idle, T0 + 3_000);
    assert_eq!(fx.pastes().len(), 1, "a suggestion is not a draft");
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

/// The Router's last turn ended ten minutes ago, then the user started
/// typing: the draft is already on the line when an item comes due.
fn typing_after_a_long_idle(fx: &mut Fixture, last_input_at: Option<u64>) {
    fx.step(&router(Status::Busy), T0 - 600_000);
    fx.step(&router(Status::Idle), T0 - 590_000);
    fx.io.with(|world| {
        world.cursor = Some(prompt("can yo"));
        world.terminal.screen_changed_at = Some(T0 - 5_000);
        world.terminal.last_input_at = last_input_at;
        world.core_draft = true;
    });
    report(fx, "result", T0 - 4_000);
}

#[test]
fn a_draft_already_on_the_line_when_an_item_comes_due_is_never_pasted_over() {
    let mut fx = fixture();
    typing_after_a_long_idle(&mut fx, Some(T0 - 5_000));
    // Quiet for 5 s and the item 4 s old: only the draft guard can hold it.
    // No empty prompt is known yet, so the PTY core refuses the paste.
    fx.step_and_settle(&router(Status::Idle), T0);
    fx.step(&router(Status::Idle), T0 + 1_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert!(fx.pastes().is_empty(), "never paste over a draft");
}

#[test]
fn an_older_core_holds_typing_with_no_known_empty_prompt_as_a_draft() {
    let mut fx = fixture();
    typing_after_a_long_idle(&mut fx, Some(T0 - 5_000));
    fx.io.with(|world| world.terminal.draft_guard = false);
    fx.step(&router(Status::Idle), T0);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert!(
        fx.io.with(|world| world.paste_since.is_empty()),
        "nothing asked"
    );
}

/// A Worker started with its first task opens on a startup menu, and a
/// person answers it at T0 + 5 s: their key is typing, and the drain has
/// not seen the Worker's empty prompt yet (#69).
fn a_person_answers_a_startup_menu(fx: &mut Fixture) -> SessionRow {
    report(fx, "first task", T0 - 10_000);
    fx.step(&router(Status::Starting), T0);
    fx.step(&router(Status::Attention), T0 + 1_000);
    fx.io
        .with(|world| world.terminal.last_input_at = Some(T0 + 5_000));
    let idle = router(Status::Idle);
    fx.step(&idle, T0 + 6_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"), "a key 1 s ago");
    idle
}

#[test]
fn a_core_with_the_draft_guard_decides_after_a_person_answers_a_startup_menu() {
    let mut fx = fixture();
    let idle = a_person_answers_a_startup_menu(&mut fx);
    fx.step_and_settle(&idle, T0 + 8_000);
    assert_eq!(fx.pastes().len(), 1, "the menu's key started no draft");
    assert_eq!(fx.io.with(|world| world.paste_unless_draft.clone()), [true]);
}

#[test]
fn an_older_core_keeps_the_task_held_after_a_person_answers_a_startup_menu() {
    let mut fx = fixture();
    fx.io.with(|world| world.terminal.draft_guard = false);
    let idle = a_person_answers_a_startup_menu(&mut fx);
    fx.step(&idle, T0 + 8_000);
    fx.step(&idle, T0 + 60_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert!(
        fx.io.with(|world| world.paste_since.is_empty()),
        "nothing asked"
    );
}

#[test]
fn a_draft_the_core_refuses_is_asked_about_again_once_the_user_types() {
    let mut fx = fixture();
    let idle = a_person_answers_a_startup_menu(&mut fx);
    fx.io.with(|world| world.core_draft = true);
    fx.step_and_settle(&idle, T0 + 8_000);
    let announced = fx.announced();
    for at in [T0 + 9_000, T0 + 10_000, T0 + 60_000] {
        fx.step(&idle, at);
        assert_eq!(fx.hold().as_deref(), Some("draft"));
    }
    assert_eq!(fx.io.with(|world| world.paste_since.len()), 1, "asked once");
    assert_eq!(fx.announced(), announced + 1, "only the draft hold");
    assert!(fx.pastes().is_empty());

    // The user erases the draft: once typing has been quiet, the core is
    // asked again and takes the paste.
    fx.io.with(|world| {
        world.core_draft = false;
        world.terminal.last_input_at = Some(T0 + 61_000);
    });
    fx.step(&idle, T0 + 63_999);
    assert_eq!(fx.hold().as_deref(), Some("draft"), "still typing");
    fx.step_and_settle(&idle, T0 + 64_000);
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn a_router_write_after_a_core_refusal_asks_the_core_once_more() {
    let mut fx = fixture();
    let idle = a_person_answers_a_startup_menu(&mut fx);
    let asked = |fx: &Fixture| fx.io.with(|world| world.paste_since.len());
    fx.store.touch_router("router", T0 + 7_000).unwrap();
    fx.io.with(|world| world.core_draft = true);
    fx.step_and_settle(&idle, T0 + 8_000);
    fx.step(&idle, T0 + 9_000);
    assert_eq!(asked(&fx), 1, "a write before the refusal does not count");

    // `send_text` or `send_keys` from the Router: the core still has the
    // draft, so it refuses once more and the hold stays, without a loop.
    fx.store.touch_router("router", T0 + 20_000).unwrap();
    fx.step_and_settle(&idle, T0 + 21_000);
    for at in [T0 + 22_000, T0 + 30_000] {
        fx.step(&idle, at);
        assert_eq!(fx.hold().as_deref(), Some("draft"));
    }
    assert_eq!(asked(&fx), 2);

    // The draft ended with no key (a program cleared its line): the next
    // Router write lets the paste through.
    fx.io.with(|world| world.core_draft = false);
    fx.store.touch_router("router", T0 + 40_000).unwrap();
    fx.step_and_settle(&idle, T0 + 41_000);
    assert_eq!(asked(&fx), 3);
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn a_draft_held_by_the_core_tells_the_user_once_it_has_held_long_enough() {
    let mut fx = fixture();
    let idle = a_person_answers_a_startup_menu(&mut fx);
    fx.io.with(|world| world.core_draft = true);
    fx.step_and_settle(&idle, T0 + 8_000);
    // Held since the step that saw the menu's key.
    assert!(fx.step(&idle, T0 + 6_000 + DRAFT_NOTIFY_MS - 1).is_empty());
    assert_eq!(fx.step(&idle, T0 + 6_000 + DRAFT_NOTIFY_MS).len(), 1);
    assert!(fx
        .step(&idle, T0 + 6_000 + DRAFT_NOTIFY_MS + 1_000)
        .is_empty());
}

#[test]
fn a_session_host_that_does_not_stamp_input_keeps_todays_lazy_baseline() {
    let mut fx = fixture();
    typing_after_a_long_idle(&mut fx, None);
    fx.step_and_settle(&router(Status::Idle), T0);
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn a_session_first_seen_after_the_user_typed_is_not_held_for_it() {
    // A Host restart: the drain never saw the Router's turn, and the
    // user's last key came before it started watching.
    let mut fx = fixture();
    fx.io
        .with(|world| world.terminal.last_input_at = Some(T0 - 30_000));
    report(&fx, "result", T0 - 10_000);
    fx.step_and_settle(&router(Status::Idle), T0);
    assert_eq!(fx.pastes().len(), 1);
}

/// One clean delivery at T0: the drain learns the Router's empty prompt,
/// and the Router's turn on the paste begins at T0 + 1 s.
fn deliver_once(fx: &mut Fixture) {
    report(fx, "first", T0 - 10_000);
    fx.step_and_settle(&router(Status::Idle), T0);
    fx.step(&router(Status::Busy), T0 + 1_000);
    assert_eq!(fx.pending(), 0);
}

fn typed(fx: &Fixture, line: CursorLine, at: u64) {
    fx.io.with(|world| {
        world.cursor = Some(line);
        world.terminal.last_input_at = Some(at);
    });
}

#[test]
fn a_draft_typed_while_the_target_works_is_held_when_it_goes_idle() {
    let mut fx = fixture();
    deliver_once(&mut fx);
    typed(&fx, prompt("next"), T0 + 2_000);
    report(&fx, "result", T0 + 3_000);
    fx.step(&router(Status::Idle), T0 + 10_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn a_draft_typed_then_cleared_is_delivered_once_typing_has_been_quiet() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    deliver_once(&mut fx);
    fx.step(&idle, T0 + 5_000);
    typed(&fx, prompt("abc"), T0 + 6_000);
    report(&fx, "result", T0 + 6_500);
    fx.step(&idle, T0 + 10_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));

    typed(&fx, prompt(""), T0 + 11_000);
    fx.step(&idle, T0 + 13_999);
    assert_eq!(fx.hold().as_deref(), Some("draft"), "still typing");
    fx.step_and_settle(&idle, T0 + 14_000);
    assert_eq!(fx.pastes().len(), 2);
}

#[test]
fn keys_that_answer_a_menu_do_not_hold_the_inbox() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    deliver_once(&mut fx);
    report(&fx, "result", T0 + 2_000);
    fx.step(&router(Status::Attention), T0 + 3_000);
    // The user picks an option; the input line stays the empty prompt.
    fx.io
        .with(|world| world.terminal.last_input_at = Some(T0 + 4_000));
    fx.step(&router(Status::Busy), T0 + 5_000);
    fx.step(&idle, T0 + 6_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"), "a key 2 s ago");
    fx.step_and_settle(&idle, T0 + 7_000);
    assert_eq!(fx.pastes().len(), 2);
}

#[test]
fn a_menu_over_an_idle_prompt_does_not_turn_a_draft_into_the_baseline() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    deliver_once(&mut fx);
    fx.step(&idle, T0 + 5_000);
    typed(&fx, prompt("can yo"), T0 + 6_000);
    report(&fx, "result", T0 + 7_000);
    // A menu comes and goes over the idle prompt, with no key pressed.
    fx.step(&router(Status::Attention), T0 + 8_000);
    fx.step(&idle, T0 + 20_000);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn the_known_empty_prompt_leaves_out_the_suggestion_drawn_on_it() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    let suggesting = |text: &str| cursor_line(&input_screen(text, 2, Some((2, text.len() as u32))));
    fx.io
        .with(|world| world.cursor = Some(suggesting("> leave the epic")));
    deliver_once(&mut fx);
    // The user types and deletes; Claude Code now suggests something else.
    fx.step(&idle, T0 + 5_000);
    typed(&fx, suggesting("> run the tests"), T0 + 6_000);
    report(&fx, "second", T0 + 6_500);
    fx.step_and_settle(&idle, T0 + 10_000);
    assert_eq!(fx.pastes().len(), 2, "a different suggestion");

    // Then again, with no suggestion on the cleared line at all.
    fx.step(&router(Status::Busy), T0 + 11_000);
    typed(&fx, cursor_line(&input_screen("> ", 2, None)), T0 + 12_000);
    report(&fx, "third", T0 + 12_500);
    fx.step_and_settle(&idle, T0 + 16_000);
    assert_eq!(fx.pastes().len(), 3, "no suggestion");
}

#[test]
fn keys_from_the_moment_the_drain_looked_stop_the_paste() {
    let mut fx = fixture();
    report(&fx, "result", T0 - 10_000);
    fx.step_and_settle(&router(Status::Idle), T0);
    assert_eq!(fx.io.with(|world| world.paste_since.clone()), [T0]);
}

#[test]
fn a_key_during_the_paste_leaves_it_on_the_line_for_the_users_enter() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    report(&fx, "result", T0 - 10_000);
    fx.io
        .with(|world| world.paste_result = Some(GuardedPaste::NotSubmitted));
    fx.step_and_settle(&idle, T0);
    fx.step(&idle, T0 + 500);
    assert_eq!(fx.hold().as_deref(), Some("unconfirmed"));
    assert_eq!(fx.pending(), 1);
    // The user's own Enter sends it along with what they typed.
    fx.drain
        .observe_hook("router", "UserPromptSubmit", T0 + 4_000);
    fx.step(&idle, T0 + 4_500);
    assert_eq!(fx.pending(), 0);
    assert_eq!(fx.pastes().len(), 1);
}

#[test]
fn a_key_just_before_the_paste_writes_nothing_and_releases_the_batch() {
    let mut fx = fixture();
    let idle = router(Status::Idle);
    report(&fx, "result", T0 - 10_000);
    fx.io.with(|world| {
        world.paste_result = Some(GuardedPaste::NotPasted(
            unpeel_core::session_input::Refusal::Typing,
        ))
    });
    fx.step_and_settle(&idle, T0);
    fx.step(&idle, T0 + 500);
    assert_eq!(fx.hold().as_deref(), Some("draft"));
    assert!(fx.pastes().is_empty());

    // The next turn pastes a fresh batch, not a redelivery.
    fx.io.with(|world| world.paste_result = None);
    fx.step(&router(Status::Busy), T0 + 10_000);
    fx.step_and_settle(&idle, T0 + 20_000);
    let pastes = fx.pastes();
    assert_eq!(pastes.len(), 1);
    assert!(!pastes[0].contains("(redelivery)"));
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
    let before = fx.announced();
    fx.drain.step(&[], T0 + 11 * 60_000);
    assert_eq!(fx.store.inbox_ids(), Vec::<String>::new());
    assert_eq!(fx.announced(), before + 1, "a removed Inbox is announced");
}

#[test]
fn a_hold_is_announced_when_it_changes_and_not_when_it_repeats() {
    let mut fx = fixture();
    report(&fx, "result", T0 - 10_000);
    fx.step(&router(Status::Busy), T0);
    assert_eq!(fx.hold().as_deref(), Some("busy"));
    assert_eq!(fx.announced(), 1, "hold.json is shared state");
    fx.step(&router(Status::Busy), T0 + 1_000);
    assert_eq!(fx.announced(), 1, "an unchanged hold is not written again");
}

#[test]
fn a_step_reads_its_settings_once_and_only_with_items_pending() {
    let mut fx = fixture();
    fx.step(&router(Status::Busy), T0);
    assert_eq!(fx.io.with(|world| world.settings_reads), 0);
    report(&fx, "one", T0);
    fx.store
        .enqueue("other", item("two", "done", Priority::Wake), T0)
        .unwrap();
    fx.step(&router(Status::Busy), T0 + 1_000);
    assert_eq!(fx.io.with(|world| world.settings_reads), 1);
}
