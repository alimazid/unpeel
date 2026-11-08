//! Fork-only: the Inbox over MCP — `sessions inbox` (a session reads and
//! acks its own Inbox) and `report` queued instead of pasted while a Host
//! worker runs. The worker's supervisor pastes queued items later
//! (`unpeel-serve` `supervisor/inbox_drain.rs`).

use serde_json::{json, Value};

use super::workers::Home;
use crate::session_host::HostedSessionManifest;
use crate::session_inbox::{self, Hold, ItemKind, NewItem, Priority, Sender, Store};
use crate::supervision::{WorkerMarker, WorkerOrigin};

/// The reporting Session, as its report carries it.
pub(super) struct Caller<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub task: Option<&'a str>,
    /// The manifest's `session.spawned_by`: a Run's names its task.
    pub spawned_by: Option<&'a str>,
}

impl<'a> Caller<'a> {
    fn of(manifest: &'a HostedSessionManifest) -> Self {
        Self {
            id: &manifest.session.id,
            label: &manifest.session.label,
            task: manifest.session.task.as_deref(),
            spawned_by: manifest.session.spawned_by.as_deref(),
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
/// idle. A Worker's report to its own Router skips the gate (§18.1.7): the
/// app-wide Deny still holds when the supervisor drains it. `None` without
/// a Host: upstream pastes at once.
pub(super) fn route_report(
    args: &Value,
    caller: &HostedSessionManifest,
    target: &HostedSessionManifest,
    gate: &dyn Fn() -> Result<(), String>,
) -> Option<Result<String, String>> {
    if !crate::supervision::host_worker_running() {
        return None;
    }
    let caller = Caller::of(caller);
    let queued = super::workers::at_home_without_facts(|home| {
        report_through_inbox(home, args, &caller, &target.session.id, gate)
    });
    Some(queued.and_then(|result| announced(&result, "report")))
}

/// `send_text` from a Worker to its own Router while a Host worker runs:
/// rerouted into the Router's Inbox as a waking `message` item, without the
/// approval prompt (`submit` is ignored). `None` for every other pair.
pub(super) fn route_send_text(
    args: &Value,
    caller: Option<&HostedSessionManifest>,
    target_id: &str,
) -> Option<Result<String, String>> {
    let caller = Caller::of(caller?);
    if !crate::supervision::host_worker_running() {
        return None;
    }
    let queued = super::workers::at_home_without_facts(|home| {
        message_through_inbox(home, args, &caller, target_id)
    })?;
    Some(queued.and_then(|result| announced(&result, "message")))
}

/// The marker of `caller_id` when `target_id` is the Router it works for.
fn router_link(home: &Home, caller_id: &str, target_id: &str) -> Option<WorkerMarker> {
    home.is_router(target_id).then_some(())?;
    home.marker(caller_id)
        .filter(|marker| marker.router_id == target_id)
}

/// A Scheduled Task's Run Session reporting to the Router (ADR 0010):
/// nobody is there to approve a Run, and each Run is a new Session, so an
/// approved pair never carries over. Its task need not still exist. A Run
/// made the Router itself still meets the gate's own-Session refusal.
fn run_reports_to_router(home: &Home, caller: &Caller<'_>, target_id: &str) -> bool {
    caller.id != target_id
        && home.is_router(target_id)
        && crate::schedules::run_sessions::schedule_id(caller.spawned_by).is_some()
}

pub(super) fn report_through_inbox(
    home: &Home,
    args: &Value,
    caller: &Caller<'_>,
    target_id: &str,
    gate: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    let link = router_link(home, caller.id, target_id);
    if link.is_none() && !run_reports_to_router(home, caller, target_id) {
        gate()?;
    }
    let item = report_item(args, caller)?;
    let item = match link {
        Some(marker) if owes_hand_over_summary(home, &marker, caller.id, target_id) => NewItem {
            kind: ItemKind::Handover,
            priority: Priority::Wake,
            ..item
        },
        _ => item,
    };
    queue(home, target_id, item, "report")
}

/// A handed-over Worker that has not reported to its Router since the
/// Hand-over: its next report is the summary the Hand-over asked for.
fn owes_hand_over_summary(home: &Home, marker: &WorkerMarker, worker: &str, router: &str) -> bool {
    marker.origin == WorkerOrigin::HandedOver
        && !home
            .inbox
            .history(router)
            .unwrap_or_default()
            .iter()
            .any(|header| {
                header.sender == Sender::Session(worker.to_owned())
                    && matches!(header.kind, ItemKind::Report | ItemKind::Handover)
                    && header.at >= marker.since
            })
}

pub(super) fn message_through_inbox(
    home: &Home,
    args: &Value,
    caller: &Caller<'_>,
    target_id: &str,
) -> Option<Result<Value, String>> {
    router_link(home, caller.id, target_id)?;
    Some(message_item(args, caller).and_then(|item| queue(home, target_id, item, "message")))
}

/// A message's first line leads it (its summary); the rest is its body.
fn message_item(args: &Value, caller: &Caller<'_>) -> Result<NewItem, String> {
    let text = args
        .get("text")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .ok_or("Nothing to send: text is empty.")?;
    let (summary, body) = text.split_once('\n').unwrap_or((text, ""));
    Ok(NewItem {
        sender: Sender::Session(caller.id.to_owned()),
        kind: ItemKind::Message,
        priority: Priority::Wake,
        about: None,
        status: None,
        label: Some(caller.label.to_owned()),
        summary: summary.trim().to_owned(),
        body: body.trim().to_owned(),
        dedupe_key: None,
    })
}

/// Queue `item` for `target_id`: `{queued, session_id, item_id, pending,
/// delivery}`.
fn queue(home: &Home, target_id: &str, item: NewItem, what: &str) -> Result<Value, String> {
    let queued = home.inbox.enqueue(target_id, item, home.now_ms)?;
    let delivery = delivery(
        home.inbox.has_wake_pending(target_id),
        home.inbox.hold(target_id).as_ref(),
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
            "The {what} was cut to {} KiB; send the rest as another {what}.",
            session_inbox::MAX_STORED_ITEM_BYTES / 1024
        ));
    }
    Ok(result)
}

/// Pending items changed: other frontends re-read session markers.
fn announced(result: &Value, what: &str) -> Result<String, String> {
    crate::supervision::announce_markers();
    serde_json::to_string_pretty(result).map_err(|e| format!("Failed to encode {what}: {e}"))
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
    let now = crate::supervision::now_ms();
    let reply = inbox_reply(&Store::home(), &caller, args, now)?;
    if reply["acked"].as_u64().is_some_and(|acked| acked > 0) {
        crate::supervision::announce_markers();
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
            ignored). A report to the Super Agent from its Worker, or from a Scheduled Task's \
            Run, needs no approval.",
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
            spawned_by: None,
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

    use crate::supervision::WorkerOrigin;
    use crate::supervision_mcp::workers::tests::{TestHome, ROUTER};

    fn as_caller(id: &str) -> Caller<'_> {
        Caller {
            id,
            label: "w label",
            task: None,
            spawned_by: None,
        }
    }

    fn prompted() -> Result<(), String> {
        Err("asked the user".into())
    }

    fn report_from(
        home: &TestHome,
        worker: &str,
        target: &str,
        status: &str,
    ) -> Result<Value, String> {
        report_as(home, &as_caller(worker), target, status)
    }

    fn report_as(
        home: &TestHome,
        caller: &Caller<'_>,
        target: &str,
        status: &str,
    ) -> Result<Value, String> {
        let args = json!({ "summary": format!("{} {status}", caller.id), "status": status });
        home.run(|ctx| report_through_inbox(ctx, &args, caller, target, &prompted))
    }

    /// A Session stamped `spawned_by`, as the Host's runner stamps a Run's.
    fn stamped<'a>(id: &'a str, spawned_by: &'a str) -> Caller<'a> {
        Caller {
            spawned_by: Some(spawned_by),
            ..as_caller(id)
        }
    }

    #[test]
    fn a_runs_report_to_the_router_skips_the_approval_prompt() {
        // No task `sch_1` in this home's app-state: a Run whose task was
        // deleted still reports.
        let home = TestHome::new().session("run-1", true);
        let run = stamped("run-1", "schedule:sch_1");
        let queued = report_as(&home, &run, ROUTER, "done").unwrap();
        assert_eq!(queued["queued"], true);
        assert_eq!(queued["delivery"], "when_idle");
        let pending = home.inbox.list(ROUTER).unwrap().pending;
        assert_eq!(pending.len(), 1);
        assert_eq!(
            (pending[0].kind, pending[0].priority),
            (ItemKind::Report, Priority::Wake)
        );
        assert_eq!(pending[0].sender, Sender::Session("run-1".into()));
    }

    #[test]
    fn only_a_run_stamp_skips_the_gate_and_only_to_the_router() {
        let home = TestHome::new().session("s-1", true);
        // Not a Run: an empty task id, a look-alike prefix, `unpeel new`'s
        // stamp, an MCP create's (the caller's id), none at all.
        for spawned_by in ["schedule:", "scheduleX:sch_1", "schedule", "cli", ROUTER] {
            let refused = report_as(&home, &stamped("s-1", spawned_by), ROUTER, "done");
            assert_eq!(refused.unwrap_err(), "asked the user", "{spawned_by}");
        }
        let refused = report_as(&home, &as_caller("s-1"), ROUTER, "done");
        assert_eq!(refused.unwrap_err(), "asked the user");
        // A Run writing to anyone but the Router.
        let run = stamped("s-1", "schedule:sch_1");
        let refused = report_as(&home, &run, "user-1", "done");
        assert_eq!(refused.unwrap_err(), "asked the user");
        // A Run Session made the Super Agent, reporting to itself: the
        // gate's own-Session refusal still applies.
        let itself = stamped(ROUTER, "schedule:sch_1");
        let refused = report_as(&home, &itself, ROUTER, "done");
        assert_eq!(refused.unwrap_err(), "asked the user");
        assert!(home.inbox.list(ROUTER).unwrap().pending.is_empty());
        assert!(home.inbox.list("user-1").unwrap().pending.is_empty());
    }

    #[test]
    fn a_runs_report_wakes_by_the_workers_rules_and_is_never_a_hand_over() {
        let home = TestHome::new().session("run-1", true);
        let run = stamped("run-1", "schedule:sch_1");
        let queued = report_as(&home, &run, ROUTER, "update").unwrap();
        assert_eq!(queued["delivery"], "held:ride_along");
        report_as(&home, &run, ROUTER, "blocked").unwrap();
        let pending = home.inbox.list(ROUTER).unwrap().pending;
        let kinds: Vec<(ItemKind, Priority)> = pending
            .iter()
            .map(|item| (item.kind, item.priority))
            .collect();
        assert_eq!(
            kinds,
            [
                (ItemKind::Report, Priority::RideAlong),
                (ItemKind::Report, Priority::Wake),
            ]
        );
    }

    #[test]
    fn a_workers_report_to_its_router_skips_the_approval_prompt() {
        let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
        let queued = report_from(&home, "w1", ROUTER, "done").unwrap();
        assert_eq!(queued["queued"], true);
        assert_eq!(queued["delivery"], "when_idle");
        let pending = home.inbox.list(ROUTER).unwrap().pending;
        assert_eq!(pending[0].kind, ItemKind::Report);
        assert_eq!(pending[0].sender, Sender::Session("w1".into()));
    }

    #[test]
    fn every_other_report_still_passes_the_write_gate() {
        let home = TestHome::new()
            .worker("w1", true, WorkerOrigin::Created, 1)
            .session("w-other", true);
        home.mark("w-other", "router-2", WorkerOrigin::Created, 1);
        // The user's session, a Worker writing elsewhere, another Router's
        // Worker, the Router writing down to its Worker.
        for (caller, target) in [
            ("user-1", ROUTER),
            ("w1", "user-1"),
            ("w-other", ROUTER),
            (ROUTER, "w1"),
        ] {
            let refused = report_from(&home, caller, target, "done").unwrap_err();
            assert_eq!(refused, "asked the user", "{caller} -> {target}");
        }
        assert!(home.inbox.list(ROUTER).unwrap().pending.is_empty());
    }

    #[test]
    fn a_handed_over_workers_first_report_is_its_hand_over_summary() {
        let home = TestHome::new()
            .worker("w1", true, WorkerOrigin::HandedOver, 500)
            .worker("w2", true, WorkerOrigin::Created, 500);
        // A report from before this Hand-over (an earlier stint) doesn't count.
        let old = report_item(
            &json!({ "summary": "old", "status": "done" }),
            &as_caller("w1"),
        );
        home.inbox.enqueue(ROUTER, old.unwrap(), 100).unwrap();

        report_from(&home, "w1", ROUTER, "progress").unwrap();
        report_from(&home, "w1", ROUTER, "done").unwrap();
        report_from(&home, "w2", ROUTER, "done").unwrap();
        let pending = home.inbox.list(ROUTER).unwrap().pending;
        let kinds: Vec<(&str, ItemKind, Priority)> = pending
            .iter()
            .map(|item| (item.summary.as_str(), item.kind, item.priority))
            .collect();
        assert_eq!(
            kinds,
            [
                ("old", ItemKind::Report, Priority::Wake),
                // Even a progress status: the summary wakes the Router.
                ("w1 progress", ItemKind::Handover, Priority::Wake),
                ("w1 done", ItemKind::Report, Priority::Wake),
                ("w2 done", ItemKind::Report, Priority::Wake),
            ]
        );
    }

    #[test]
    fn a_workers_send_text_to_its_router_becomes_a_waking_message() {
        let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
        let args = json!({ "text": "  Which database?\nPostgres or SQLite.  ", "submit": false });
        let queued = home
            .run(|ctx| message_through_inbox(ctx, &args, &as_caller("w1"), ROUTER))
            .expect("rerouted")
            .unwrap();
        assert_eq!(queued["queued"], true);
        let pending = home.inbox.list(ROUTER).unwrap().pending;
        let item = home.inbox.item(ROUTER, &pending[0].id).unwrap().unwrap();
        assert_eq!(
            (item.kind, item.priority),
            (ItemKind::Message, Priority::Wake)
        );
        assert_eq!(item.sender, Sender::Session("w1".into()));
        assert_eq!(item.summary, "Which database?");
        assert_eq!(item.body, "Postgres or SQLite.");

        let empty = json!({ "text": "  " });
        let refused = home.run(|ctx| message_through_inbox(ctx, &empty, &as_caller("w1"), ROUTER));
        assert!(refused.unwrap().is_err());
    }

    #[test]
    fn any_other_send_text_keeps_upstreams_path() {
        let home = TestHome::new().worker("w1", true, WorkerOrigin::Created, 1);
        let args = json!({ "text": "hi" });
        for (caller, target) in [("w1", "user-1"), ("user-1", ROUTER), (ROUTER, "w1")] {
            let routed =
                home.run(|ctx| message_through_inbox(ctx, &args, &as_caller(caller), target));
            assert!(routed.is_none(), "{caller} -> {target}");
        }
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
