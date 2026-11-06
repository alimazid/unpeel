//! Fork-only: the Inbox over MCP — `sessions inbox` (a session reads and
//! acks its own Inbox) and `report` queued instead of pasted while a Host
//! worker runs. The worker's supervisor pastes queued items later
//! (`unpeel-serve` `supervisor/inbox_drain.rs`).

use serde_json::{json, Value};

use crate::session_host::HostedSessionManifest;
use crate::session_inbox::{self, Hold, ItemKind, NewItem, Priority, Sender, Store};

/// The reporting Session, as its report carries it.
pub(super) struct Caller<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub task: Option<&'a str>,
}

impl<'a> Caller<'a> {
    fn of(manifest: &'a HostedSessionManifest) -> Self {
        Self {
            id: &manifest.session.id,
            label: &manifest.session.label,
            task: manifest.session.task.as_deref(),
        }
    }
}

/// Upstream's statuses plus `progress`, the ride-along word.
const REPORT_STATUSES: &[&str] = &["update", "progress", "done", "blocked"];
/// A result or a block wakes the target; anything else rides along.
const WAKE_STATUSES: &[&str] = &["done", "blocked"];
/// The list sections of a report body, in upstream's order.
const LIST_SECTIONS: &[(&str, &str)] = &[
    ("proof", "Proof"),
    ("changed_paths", "Changed paths"),
    ("artifacts", "Artifacts"),
    ("blockers", "Blockers"),
    ("questions", "Questions"),
    ("next_steps", "Next steps"),
];
/// Hold reasons that clear by themselves once the target is idle: a report
/// held only by these goes out "when idle".
const WAITS_FOR_IDLE: &[&str] = &[
    "busy",
    "starting",
    "attention",
    "quiet",
    "debounce",
    "snapshot",
    "retry",
    "in_flight",
    "unconfirmed",
    "ride_along",
];

/// A report as an Inbox item. The sender is always the calling Session: an
/// MCP call can never speak as the Host. The summary leads the paste; the
/// body carries the rest, in upstream's section order.
pub(super) fn report_item(args: &Value, caller: &Caller<'_>) -> Result<NewItem, String> {
    let summary = args
        .get("summary")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|summary| !summary.is_empty())
        .ok_or("Missing required string argument 'summary'")?;
    let status = match args.get("status").and_then(Value::as_str).map(str::trim) {
        None | Some("") => "update",
        Some(status) if REPORT_STATUSES.contains(&status) => status,
        Some(_) => {
            return Err(format!(
                "report status must be one of: {}",
                REPORT_STATUSES.join(", ")
            ))
        }
    };
    let mut sections: Vec<String> = caller
        .task
        .map(|task| format!("Task: {task}"))
        .into_iter()
        .collect();
    if let Some(details) = args
        .get("details")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|details| !details.is_empty())
    {
        sections.push(format!("Details:\n{details}"));
    }
    let mut asks_questions = false;
    for (key, title) in LIST_SECTIONS {
        let items = string_list(args, key)?;
        asks_questions |= *key == "questions" && !items.is_empty();
        if !items.is_empty() {
            let lines: Vec<String> = items.iter().map(|item| format!("- {item}")).collect();
            sections.push(format!("{title}:\n{}", lines.join("\n")));
        }
    }
    let wakes = WAKE_STATUSES.contains(&status) || asks_questions;
    Ok(NewItem {
        sender: Sender::Session(caller.id.to_owned()),
        kind: ItemKind::Report,
        priority: if wakes {
            Priority::Wake
        } else {
            Priority::RideAlong
        },
        about: None,
        status: Some(status.to_owned()),
        label: Some(caller.label.to_owned()),
        summary: summary.to_owned(),
        body: sections.join("\n\n"),
        dedupe_key: None,
    })
}

/// An optional array of strings, blanks dropped (as upstream's report).
fn string_list(args: &Value, key: &str) -> Result<Vec<String>, String> {
    let Some(value) = args.get(key) else {
        return Ok(Vec::new());
    };
    let items = value
        .as_array()
        .ok_or_else(|| format!("'{key}' must be an array of strings"))?;
    items
        .iter()
        .map(|item| {
            item.as_str()
                .map(|text| text.trim().to_owned())
                .ok_or_else(|| format!("'{key}' entries must be strings"))
        })
        .filter(|item| item.as_ref().map_or(true, |text| !text.is_empty()))
        .collect()
}

/// When a queued report goes out: `when_idle`, or `held:<reason>` while the
/// supervisor holds the target's Inbox for something that does not clear
/// by itself (or nothing pending wakes the target yet).
pub(super) fn delivery(wake_pending: bool, hold: Option<&Hold>) -> String {
    if !wake_pending {
        return "held:ride_along".into();
    }
    match hold.map(|hold| hold.reason.as_str()) {
        Some(reason) if !WAITS_FOR_IDLE.contains(&reason) => format!("held:{reason}"),
        _ => "when_idle".into(),
    }
}

/// `report` while a Host worker runs: past the write gate it is queued in
/// the target's Inbox, and the supervisor pastes it when the target is
/// idle. `None` without a Host: upstream pastes at once.
pub(super) fn route_report(
    args: &Value,
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
    gate: &dyn Fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    if !crate::supervision::host_worker_running() {
        return None;
    }
    Some(gate().and_then(|()| queue_report(args, caller, target)))
}

fn queue_report(
    args: &Value,
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
) -> Result<String, String> {
    let item = report_item(args, &Caller::of(caller))?;
    let target_id = target.session.id.as_str();
    let queued = session_inbox::enqueue(target_id, item)?;
    let delivery = delivery(
        session_inbox::has_wake_pending(target_id),
        session_inbox::hold(target_id).as_ref(),
    );
    let mut result = json!({
        "queued": true,
        "session_id": target_id,
        "item_id": queued.item_id,
        "pending": queued.pending,
        "delivery": delivery,
    });
    if queued.truncated {
        result["truncated"] = Value::Bool(true);
        result["note"] = Value::String(format!(
            "The report was cut to {} KiB; send the rest as another report.",
            session_inbox::MAX_STORED_ITEM_BYTES / 1024
        ));
    }
    serde_json::to_string_pretty(&result).map_err(|e| format!("Failed to encode report: {e}"))
}

/// Upstream's immediate paste result, for when no Host worker runs.
pub(super) fn immediate_report_result(message: String) -> String {
    let result = json!({
        "queued": false,
        "delivery": "immediate_legacy",
        "result": message,
    });
    serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string())
}

/// `sessions inbox`: the calling Session's own Inbox.
pub(super) fn inbox_action(args: &Value) -> Result<String, String> {
    let caller = crate::mcp_host::self_session_id()
        .ok_or("sessions inbox needs to know the calling session; run it inside a session.")?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64);
    let reply = inbox_reply(&Store::home(), &caller, args, now)?;
    if reply["acked"].as_u64().is_some_and(|acked| acked > 0) {
        crate::state_bus::announce(crate::state_bus::Change::SessionMarkers, None);
    }
    serde_json::to_string_pretty(&reply).map_err(|e| format!("Failed to encode inbox: {e}"))
}

/// The `sessions inbox` reply for `caller`, against `store`.
pub(super) fn inbox_reply(
    store: &Store,
    caller: &str,
    args: &Value,
    now: u64,
) -> Result<Value, String> {
    if let Some(other) = args
        .get("session_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty() && *id != caller)
    {
        return Err(format!(
            "sessions inbox reads only your own Inbox; '{other}' is another session."
        ));
    }
    let item_id = optional_id(args, "item_id")?;
    let ack_through = optional_id(args, "ack_through")?;
    match (item_id, ack_through) {
        (Some(_), Some(_)) => Err("Pass one of item_id or ack_through, not both.".into()),
        (Some(item_id), None) => store
            .item(caller, item_id)?
            .map(|item| json!({ "item": item }))
            .ok_or_else(|| {
                format!("No item '{item_id}' in your Inbox (delivered items are kept for 24 h).")
            }),
        (None, Some(item_id)) => {
            let acked = store.ack_through(caller, item_id, now)?;
            Ok(json!({ "acked": acked, "pending": store.pending_stats(caller).items }))
        }
        (None, None) => {
            let listing = store.list(caller)?;
            Ok(json!({
                "session_id": caller,
                "hold": store.hold(caller).map(|hold| hold.reason),
                "pending": listing.pending,
                "delivered": listing.delivered,
            }))
        }
    }
}

fn optional_id<'a>(args: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(id)) if !id.trim().is_empty() => Ok(Some(id.trim())),
        Some(_) => Err(format!("'{key}' must be an item id string")),
    }
}

/// The advertised `sessions` properties: names only, every byte counts
/// (`advertised_schema_stays_within_the_context_budget`); `help_doc`
/// explains them.
pub(super) fn schema_properties() -> Vec<(&'static str, Value)> {
    vec![
        ("item_id", json!({ "type": "string" })),
        ("ack_through", json!({ "type": "string" })),
    ]
}

/// `sessions help` for `inbox`.
pub(super) fn help_doc() -> Vec<(String, Value)> {
    vec![(
        "inbox".to_string(),
        json!({
            "description": "Your own Inbox. Reports and messages sent to you queue here while \
            you are busy and arrive as one paste when you are idle. With no parameters: pending \
            item headers, the last 20 delivered, and why delivery is held right now (hold, e.g. \
            busy or no_agent_authority). While a Host runs, report queues into the target's \
            Inbox instead of typing, and its result says queued, item_id, pending and delivery \
            (when_idle or held:<reason>); status done or blocked, or questions, wakes the \
            target, while update and progress ride along with the next batch (submit is \
            ignored).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "item_id": { "type": "string", "description": "Read one item in full, pending or recently delivered (the target of a paste's 'full text' pointer)." },
                    "ack_through": { "type": "string", "description": "Pull mode: mark every pending item up to and including this one consumed, so it is never pasted." },
                },
                "additionalProperties": false,
            },
        }),
    )]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_inbox::{Hold, ItemKind, Priority, Sender, Store};
    use serde_json::json;

    fn caller() -> Caller<'static> {
        Caller {
            id: "w1",
            label: "fix-login",
            task: None,
        }
    }

    #[test]
    fn a_report_becomes_an_item_from_its_caller() {
        let item = report_item(
            &json!({
                "summary": "  Login fixed  ",
                "status": "done",
                "details": "Root cause: a stale cookie.",
                "proof": ["cargo test", " "],
                "next_steps": ["deploy"],
            }),
            &caller(),
        )
        .unwrap();
        assert_eq!(item.sender, Sender::Session("w1".into()));
        assert_eq!(item.kind, ItemKind::Report);
        assert_eq!(item.status.as_deref(), Some("done"));
        assert_eq!(item.label.as_deref(), Some("fix-login"));
        assert_eq!(item.summary, "Login fixed");
        assert_eq!(
            item.body,
            "Details:\nRoot cause: a stale cookie.\n\nProof:\n- cargo test\n\nNext steps:\n- deploy"
        );
        assert_eq!(item.dedupe_key, None);
    }

    #[test]
    fn results_and_questions_wake_the_target_and_progress_rides_along() {
        let priority = |args: Value| report_item(&args, &caller()).unwrap().priority;
        assert_eq!(
            priority(json!({ "summary": "s", "status": "done" })),
            Priority::Wake
        );
        assert_eq!(
            priority(json!({ "summary": "s", "status": "blocked" })),
            Priority::Wake
        );
        assert_eq!(
            priority(json!({ "summary": "s", "status": "progress" })),
            Priority::RideAlong
        );
        assert_eq!(priority(json!({ "summary": "s" })), Priority::RideAlong);
        assert_eq!(
            priority(json!({ "summary": "s", "status": "update", "questions": ["which db?"] })),
            Priority::Wake
        );
    }

    #[test]
    fn a_report_needs_a_summary_and_a_known_status() {
        let error = report_item(&json!({ "status": "done" }), &caller()).unwrap_err();
        assert!(error.contains("summary"), "{error}");
        let error =
            report_item(&json!({ "summary": "s", "status": "shipped" }), &caller()).unwrap_err();
        assert!(error.contains("update, progress, done, blocked"), "{error}");
        let error = report_item(&json!({ "summary": "s", "proof": "one" }), &caller()).unwrap_err();
        assert!(error.contains("'proof'"), "{error}");
    }

    #[test]
    fn a_task_label_is_kept_with_the_report() {
        let item = report_item(
            &json!({ "summary": "s" }),
            &Caller {
                task: Some("login bug"),
                ..caller()
            },
        )
        .unwrap();
        assert_eq!(item.body, "Task: login bug");
    }

    fn hold(reason: &str) -> Option<Hold> {
        Some(Hold {
            reason: reason.into(),
            since: 1,
        })
    }

    #[test]
    fn the_delivery_word_says_when_a_queued_report_goes_out() {
        assert_eq!(delivery(true, None), "when_idle");
        assert_eq!(delivery(true, hold("busy").as_ref()), "when_idle");
        assert_eq!(delivery(true, hold("debounce").as_ref()), "when_idle");
        // A stale ride-along hold from before this wake item.
        assert_eq!(delivery(true, hold("ride_along").as_ref()), "when_idle");
        assert_eq!(
            delivery(true, hold("no_agent_authority").as_ref()),
            "held:no_agent_authority"
        );
        assert_eq!(
            delivery(true, hold("policy_deny").as_ref()),
            "held:policy_deny"
        );
        // Nothing pending wakes the target: it waits for the next wake batch.
        assert_eq!(delivery(false, hold("busy").as_ref()), "held:ride_along");
    }

    fn store() -> (tempfile::TempDir, Store) {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::at(tmp.path().join("session-inboxes"));
        (tmp, store)
    }

    fn queue(store: &Store, target: &str, summary: &str, at: u64) -> String {
        let item =
            report_item(&json!({ "summary": summary, "status": "done" }), &caller()).unwrap();
        store.enqueue(target, item, at).unwrap().item_id
    }

    #[test]
    fn inbox_lists_pending_items_recent_deliveries_and_the_hold() {
        let (_tmp, store) = store();
        let empty = inbox_reply(&store, "me", &json!({}), 1).unwrap();
        assert_eq!(empty["pending"], json!([]));
        assert_eq!(empty["delivered"], json!([]));
        assert_eq!(empty["hold"], Value::Null);

        let first = queue(&store, "me", "first", 10);
        queue(&store, "me", "second", 20);
        store.ack_through("me", &first, 30).unwrap();
        store
            .set_hold("me", hold("no_agent_authority").as_ref())
            .unwrap();
        let listed = inbox_reply(&store, "me", &json!({}), 40).unwrap();
        assert_eq!(listed["session_id"], "me");
        assert_eq!(listed["hold"], "no_agent_authority");
        assert_eq!(listed["pending"][0]["summary"], "second");
        assert_eq!(listed["pending"][0]["sender"], json!({ "session": "w1" }));
        assert_eq!(listed["pending"].as_array().unwrap().len(), 1);
        assert_eq!(listed["delivered"][0]["id"], first.as_str());
        // Headers only: bodies are read one item at a time.
        assert!(listed["pending"][0].get("body").is_none());
    }

    #[test]
    fn inbox_item_id_reads_the_full_item_pending_or_delivered() {
        let (_tmp, store) = store();
        let id = queue(&store, "me", "result", 10);
        let item = inbox_reply(&store, "me", &json!({ "item_id": id }), 11).unwrap();
        assert_eq!(item["item"]["summary"], "result");
        assert_eq!(item["item"]["status"], "done");
        assert!(item["item"].get("body").is_some());

        store.ack_through("me", &id, 12).unwrap();
        let delivered = inbox_reply(&store, "me", &json!({ "item_id": id }), 13).unwrap();
        assert!(delivered["item"]["delivered_at"].is_u64());

        let error = inbox_reply(&store, "me", &json!({ "item_id": "nope" }), 14).unwrap_err();
        assert!(error.contains("nope"), "{error}");
    }

    #[test]
    fn inbox_ack_through_consumes_items_in_pull_mode() {
        let (_tmp, store) = store();
        let first = queue(&store, "me", "first", 10);
        let second = queue(&store, "me", "second", 20);
        queue(&store, "me", "third", 30);
        let acked = inbox_reply(&store, "me", &json!({ "ack_through": second }), 40).unwrap();
        assert_eq!(acked["acked"], 2);
        assert_eq!(acked["pending"], 1);
        // Already consumed: nothing more to do.
        let again = inbox_reply(&store, "me", &json!({ "ack_through": first }), 41).unwrap();
        assert_eq!(again["acked"], 0);
        assert!(inbox_reply(&store, "me", &json!({ "ack_through": "nope" }), 42).is_err());
    }

    #[test]
    fn inbox_reads_only_the_callers_own_inbox_and_one_thing_at_a_time() {
        let (_tmp, store) = store();
        let id = queue(&store, "other", "private", 10);
        let error = inbox_reply(&store, "me", &json!({ "session_id": "other" }), 11).unwrap_err();
        assert!(error.contains("own Inbox"), "{error}");
        // Naming yourself is fine.
        assert!(inbox_reply(&store, "me", &json!({ "session_id": "me" }), 11).is_ok());
        // Another session's item id is just not in yours.
        assert!(inbox_reply(&store, "me", &json!({ "item_id": id }), 12).is_err());
        let error = inbox_reply(
            &store,
            "me",
            &json!({ "item_id": id, "ack_through": id }),
            13,
        )
        .unwrap_err();
        assert!(error.contains("one of"), "{error}");
    }

    #[test]
    fn the_inbox_parameters_are_advertised_tersely() {
        let names: Vec<&str> = schema_properties().iter().map(|(name, _)| *name).collect();
        assert_eq!(names, ["item_id", "ack_through"]);
        let (action, doc) = &help_doc()[0];
        assert_eq!(action, "inbox");
        let params = doc["inputSchema"]["properties"].as_object().unwrap();
        assert!(params.contains_key("item_id") && params.contains_key("ack_through"));
    }
}
