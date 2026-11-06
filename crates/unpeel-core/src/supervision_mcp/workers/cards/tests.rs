use super::*;
use crate::session_inbox::{ItemKind, NewItem, Priority, Sender};
use crate::supervision::WorkerOrigin;
use crate::supervision_mcp::workers::tests::{TestHome, ROUTER};
use serde_json::json;

fn item(sender: Sender, kind: ItemKind, status: Option<&str>, summary: &str) -> NewItem {
    NewItem {
        sender,
        kind,
        priority: Priority::Wake,
        about: None,
        status: status.map(str::to_owned),
        label: None,
        summary: summary.into(),
        body: String::new(),
        dedupe_key: None,
    }
}

fn from(worker: &str) -> Sender {
    Sender::Session(worker.into())
}

fn extras(home: &TestHome, caller: &str) -> Option<Value> {
    home.run(|ctx| current_extras_at(ctx, caller))
}

#[test]
fn the_router_sees_one_card_per_worker_oldest_first() {
    let home = TestHome::new()
        .worker("w2", false, WorkerOrigin::HandedOver, 20)
        .worker("w1", true, WorkerOrigin::Created, 10);
    let extras = extras(&home, ROUTER).unwrap();
    assert_eq!(extras["super_agent"], true);
    assert_eq!(
        extras["workers"],
        json!([
            {
                "id": "w1", "label": "w1 label", "project_id": "q", "group_id": "q",
                "activity_status": "working", "last_report_status": null, "preview": null,
            },
            {
                "id": "w2", "label": "w2 label", "project_id": "q", "group_id": "q",
                "activity_status": "exited", "last_report_status": null, "preview": null,
            },
        ])
    );
}

#[test]
fn a_card_shows_the_last_report_status_and_what_the_worker_said_last() {
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 10);
    let report = item(
        from("w1"),
        ItemKind::Report,
        Some("blocked"),
        "Need a DB password",
    );
    home.inbox.enqueue(ROUTER, report, 100).unwrap();
    let done = item(from("w1"), ItemKind::Report, Some("done"), "Login fixed");
    let delivered = home.inbox.enqueue(ROUTER, done, 200).unwrap();
    home.inbox
        .ack_through(ROUTER, &delivered.item_id, 250)
        .unwrap();
    // Someone else's report is not this Worker's.
    let other = item(from("w9"), ItemKind::Report, Some("update"), "elsewhere");
    home.inbox.enqueue(ROUTER, other, 300).unwrap();
    let message = item(
        from("w1"),
        ItemKind::Message,
        None,
        "Merged, anything else?",
    );
    home.inbox.enqueue(ROUTER, message, 400).unwrap();

    let card = &extras(&home, ROUTER).unwrap()["workers"][0];
    assert_eq!(
        card["last_report_status"], "done",
        "delivered history counts"
    );
    assert_eq!(card["preview"], "Merged, anything else?");
}

#[test]
fn a_finished_notice_previews_the_workers_reply() {
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 10);
    let report = item(
        from("w1"),
        ItemKind::Report,
        Some("update"),
        "Started on it",
    );
    home.inbox.enqueue(ROUTER, report, 100).unwrap();
    let finished = NewItem {
        about: Some("w1".into()),
        body: format!("All done: {}", "word ".repeat(80)),
        ..item(
            Sender::Host,
            ItemKind::Lifecycle,
            Some(FINISHED_STATUS),
            "w1 finished",
        )
    };
    home.inbox.enqueue(ROUTER, finished, 200).unwrap();

    let card = &extras(&home, ROUTER).unwrap()["workers"][0];
    assert_eq!(card["last_report_status"], "update");
    let preview = card["preview"].as_str().unwrap();
    assert!(preview.starts_with("All done: word word"), "{preview}");
    assert_eq!(preview.chars().count(), MAX_PREVIEW_CHARS);
    assert!(!preview.contains('\n'));
}

#[test]
fn every_caller_sees_its_pending_inbox_and_a_worker_its_router() {
    let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 10);
    assert_eq!(
        extras(&home, "w1"),
        Some(json!({ "router_id": ROUTER, "inbox": { "pending": 0 } }))
    );
    // Any caller, Worker or not (§9): delivered items no longer count.
    let first = item(from("w1"), ItemKind::Message, None, "one");
    let delivered = home.inbox.enqueue("user-1", first, 100).unwrap();
    home.inbox
        .ack_through("user-1", &delivered.item_id, 150)
        .unwrap();
    for summary in ["two", "three"] {
        let message = item(from("w1"), ItemKind::Message, None, summary);
        home.inbox.enqueue("user-1", message, 200).unwrap();
    }
    assert_eq!(
        extras(&home, "user-1"),
        Some(json!({ "inbox": { "pending": 2 } }))
    );
    assert_eq!(extras(&home, ROUTER).unwrap()["inbox"]["pending"], 0);
}
