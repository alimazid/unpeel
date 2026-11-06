use super::*;
use crate::session_inbox::{ItemKind, NewItem, Priority, Sender};
use crate::supervision::WorkerOrigin;
use crate::supervision_mcp::workers::tests::{TestHome, NOW, ROUTER};
use serde_json::json;
use std::cell::RefCell;

fn task_for(worker: &str, summary: &str) -> NewItem {
    NewItem {
        sender: Sender::Session(ROUTER.into()),
        kind: ItemKind::Task,
        priority: Priority::Wake,
        about: None,
        status: None,
        label: None,
        summary: summary.into(),
        body: format!("{summary} for {worker}"),
        dedupe_key: None,
    }
}

/// Records which Sessions a stop/remove was asked for.
#[derive(Default)]
struct Calls(RefCell<Vec<String>>);

impl Calls {
    fn run(&self, id: &str) -> Result<(), String> {
        self.0.borrow_mut().push(id.to_string());
        Ok(())
    }

    fn taken(&self) -> Vec<String> {
        self.0.borrow().clone()
    }
}

fn stop(home: &TestHome, caller: &str, target: &str, calls: &Calls) -> Result<Value, String> {
    home.run(|ctx| {
        stop_at(ctx, caller, &json!({ "session_id": target }), &|id| {
            calls.run(id)
        })
    })
}

#[test]
fn stop_stops_the_routers_own_worker_and_returns_its_queue() {
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
    home.inbox
        .enqueue("w1", task_for("w1", "write tests"), 5)
        .unwrap();
    let calls = Calls::default();

    let stopped = stop(&home, ROUTER, "w1", &calls).unwrap();
    assert_eq!(calls.taken(), ["w1"]);
    assert_eq!(stopped["stopped"], true);
    assert_eq!(stopped["returned_items"], 1);
    // Nothing more is pasted into the Worker; the Router gets it back as a
    // ride-along item about the Worker (§17.9).
    assert!(home.inbox.list("w1").unwrap().pending.is_empty());
    let returned = home.inbox.list(ROUTER).unwrap().pending;
    assert_eq!(returned.len(), 1);
    assert_eq!(returned[0].summary, "write tests");
    assert_eq!(returned[0].priority, Priority::RideAlong);
    assert_eq!(returned[0].about.as_deref(), Some("w1"));
    // The stop is the Router's own doing (§17.7), and the marker stays: a
    // stopped Worker is still a Worker.
    assert_eq!(home.inbox.router_touched_at("w1"), Some(NOW));
    assert!(home.marker("w1").is_some());
}

#[test]
fn stopping_an_already_stopped_worker_still_returns_its_queue() {
    let home = TestHome::new().worker("w1", false, WorkerOrigin::HandedOver, 1);
    home.inbox.enqueue("w1", task_for("w1", "late"), 5).unwrap();
    let calls = Calls::default();
    let stopped = stop(&home, ROUTER, "w1", &calls).unwrap();
    assert!(calls.taken().is_empty(), "nothing left to stop");
    assert_eq!(stopped["was_running"], false);
    assert_eq!(stopped["returned_items"], 1);
}

#[test]
fn stop_is_the_routers_and_only_for_its_own_workers() {
    let home = TestHome::new()
        .worker("w1", true, WorkerOrigin::Created, 1)
        .session("other", true);
    home.mark("other", "router-2", WorkerOrigin::Created, 1);
    let calls = Calls::default();

    let error = stop(&home, "user-1", "w1", &calls).unwrap_err();
    assert!(error.contains("Super Agent"), "{error}");
    let error = stop(&home, ROUTER, "user-1", &calls).unwrap_err();
    assert!(error.contains("not one of your Workers"), "{error}");
    let error = stop(&home, ROUTER, "other", &calls).unwrap_err();
    assert!(error.contains("not one of your Workers"), "{error}");
    let error = stop(&home, ROUTER, ROUTER, &calls).unwrap_err();
    assert!(error.contains("yourself"), "{error}");
    assert!(stop(&home, ROUTER, "", &calls).is_err());
    assert!(calls.taken().is_empty());
}

fn close(
    home: &TestHome,
    caller: &str,
    target: &str,
    spawned_by: Option<&str>,
    role: Option<&str>,
    calls: &Calls,
) -> Option<Result<String, String>> {
    let closing = Closing {
        caller,
        target,
        spawned_by,
        role,
    };
    home.run(|ctx| close_at(ctx, &closing, &|id| calls.run(id)))
}

#[test]
fn a_router_closes_its_workers_by_marker() {
    let home = TestHome::new().worker("w1", false, WorkerOrigin::HandedOver, 1);
    home.inbox
        .enqueue("w1", task_for("w1", "queued"), 5)
        .unwrap();
    let calls = Calls::default();
    // Handed over: never spawned by the Router, still its Worker.
    let closed = close(&home, ROUTER, "w1", None, None, &calls)
        .unwrap()
        .unwrap();
    assert!(closed.contains("Removed session w1"), "{closed}");
    assert_eq!(calls.taken(), ["w1"]);
    assert_eq!(home.inbox.list(ROUTER).unwrap().pending.len(), 1);
    assert_eq!(home.inbox.router_touched_at("w1"), Some(NOW));
}

#[test]
fn a_user_restarted_worker_is_the_users_even_though_the_router_spawned_it() {
    // Resume carried `spawned_by` over and dropped the marker.
    let home = TestHome::new().session("restarted", true);
    let calls = Calls::default();
    let error = close(&home, ROUTER, "restarted", Some(ROUTER), None, &calls)
        .expect("the Router's close is decided here")
        .unwrap_err();
    assert!(error.contains("not one of your Workers"), "{error}");
    assert!(calls.taken().is_empty());
}

#[test]
fn a_router_still_closes_the_app_panels_it_opened() {
    let home = TestHome::new().session("panel", true);
    let calls = Calls::default();
    let closed = close(
        &home,
        ROUTER,
        "panel",
        Some(ROUTER),
        Some("app-panel"),
        &calls,
    );
    assert!(closed.unwrap().is_ok());
    assert_eq!(calls.taken(), ["panel"]);
    let calls = Calls::default();
    let refused = close(
        &home,
        ROUTER,
        "panel",
        Some("user-1"),
        Some("app-panel"),
        &calls,
    );
    assert!(refused.unwrap().is_err());
}

#[test]
fn a_plain_create_and_remove_callers_close_stays_upstreams() {
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
    let calls = Calls::default();
    assert_eq!(
        close(&home, "user-1", "w1", Some("user-1"), None, &calls),
        None
    );
    assert!(calls.taken().is_empty());
}

#[test]
fn every_router_write_to_its_worker_is_stamped() {
    let home = TestHome::new()
        .worker("w1", true, WorkerOrigin::Created, 1)
        .session("plain", true);
    // `true`: a stamp was written, so the real-home wrapper announces it.
    assert!(home.run(|ctx| note_write_at(ctx, ROUTER, "w1")));
    assert_eq!(home.inbox.router_touched_at("w1"), Some(NOW));
    // Only the Router's writes to its own Workers.
    assert!(!home.run(|ctx| note_write_at(ctx, ROUTER, "plain")));
    assert!(!home.run(|ctx| note_write_at(ctx, "user-1", "plain")));
    assert_eq!(home.inbox.router_touched_at("plain"), None);
}

#[test]
fn a_workers_send_keys_into_its_router_still_asks() {
    // Only report and send_text go through the Inbox; send_keys has no fork
    // route, so the Worker's own grant decides, and being a Worker grants
    // nothing: under Ask, the ordinary approval prompt.
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
    let grants = crate::supervision::grant_override(&home.state, Default::default());
    assert!(!grants.contains_key("w1"));
    assert!(!crate::state::McpGrant::default()
        .role
        .writes_without_asking());
    assert!(grants[ROUTER].role.writes_without_asking());
}

#[test]
fn only_the_routers_waits_are_capped() {
    assert_eq!(capped_wait(true, 120_000), ROUTER_WAIT_CAP_MS);
    assert_eq!(capped_wait(true, 2_000), 2_000);
    assert_eq!(capped_wait(false, 120_000), 120_000);
}

#[test]
fn a_capped_wait_that_times_out_says_why() {
    let timed_out = || Err::<String, String>("Timed out after 5000ms".into());
    let wait = json!({ "action": "wait_for_text", "timeout_ms": 60_000 });
    let error = explain_wait_for(true, "sessions", &wait, timed_out()).unwrap_err();
    assert!(error.starts_with("Timed out after 5000ms"), "{error}");
    assert!(error.contains("end your turn"), "{error}");
    // No timeout given: upstream's 30 s default was capped too.
    for (tool, action) in [("sessions", "wait_for_status"), ("agents", "wait")] {
        let args = json!({ "action": action });
        let error = explain_wait_for(true, tool, &args, timed_out()).unwrap_err();
        assert!(error.contains("end your turn"), "{tool} {action}: {error}");
    }
    let legacy = explain_wait_for(true, "wait_for_status", &json!({}), timed_out());
    assert!(legacy.unwrap_err().contains("end your turn"));

    // Untouched: anyone else, a wait under the cap, a success, other tools.
    let plain = |router, tool, args: &Value, result| explain_wait_for(router, tool, args, result);
    assert_eq!(plain(false, "sessions", &wait, timed_out()), timed_out());
    let short = json!({ "action": "wait_for_text", "timeout_ms": 3_000 });
    assert_eq!(plain(true, "sessions", &short, timed_out()), timed_out());
    assert_eq!(
        plain(true, "sessions", &wait, Ok("found".into())),
        Ok("found".into())
    );
    let read = json!({ "action": "read_screen" });
    assert_eq!(plain(true, "sessions", &read, timed_out()), timed_out());
}
