use super::*;
use serde_json::json;
use std::cell::RefCell;

const ROUTER: &str = "11111111-1111-4111-8111-111111111111";
const OTHER: &str = "22222222-2222-4222-8222-222222222222";

/// A workspace with two Projects, their presets, one task, and `ROUTER`
/// marked Super Agent.
fn state() -> Value {
    json!({
        "super_agent": { "session_id": ROUTER, "since": 1 },
        "projects": [
            { "id": "p", "name": "Home", "path": "/tmp/p" },
            { "id": "q", "name": "Work", "path": "/tmp/q" },
        ],
        "presets": [
            { "id": "global-claude", "label": "Claude", "command": "claude", "project_id": null, "enabled": true },
            { "id": "p-script", "label": "Backup", "command": "./backup.sh", "project_id": "p", "enabled": true },
            { "id": "q-script", "label": "Backup", "command": "./sync.sh", "project_id": "q", "enabled": true },
            { "id": "off", "label": "Off", "command": "true", "project_id": null, "enabled": false },
        ],
        "schedules": [
            { "id": "sch_daily", "name": "Briefing", "project_id": "q", "preset_id": "global-claude",
              "trigger": { "kind": "daily", "time": "09:00" }, "enabled": true },
        ],
    })
}

/// The Host side: every request it was sent, answering each with `reply`.
struct FakeHost {
    sent: RefCell<Vec<(String, Value)>>,
    reply: (u16, Value),
}

impl FakeHost {
    fn answering(status: u16, body: Value) -> Self {
        Self {
            sent: RefCell::new(Vec::new()),
            reply: (status, body),
        }
    }

    fn ok() -> Self {
        Self::answering(200, json!({ "schedule": { "id": "sch_new" } }))
    }

    fn call(&self, action: &str, arguments: Value, caller: Option<&str>) -> Result<Value, String> {
        let post = |path: &str, body: &Value| {
            self.sent.borrow_mut().push((path.to_owned(), body.clone()));
            Ok(self.reply.clone())
        };
        answer(action, &arguments, caller, &state(), &post)
    }

    fn only_request(&self) -> (String, Value) {
        let sent = self.sent.borrow();
        assert_eq!(sent.len(), 1, "{sent:?}");
        sent[0].clone()
    }

    fn nothing_sent(&self) -> bool {
        self.sent.borrow().is_empty()
    }
}

fn daily() -> Value {
    json!({ "kind": "daily", "time": "08:15" })
}

#[test]
fn only_the_super_agent_changes_tasks() {
    for action in WRITE_ACTIONS {
        for caller in [Some(OTHER), None] {
            let host = FakeHost::ok();
            let refused = host
                .call(action, json!({ "schedule_id": "sch_daily" }), caller)
                .expect_err("refused");
            assert!(
                refused.contains("Only the Super Agent"),
                "{action}: {refused}"
            );
            assert!(host.nothing_sent(), "{action} reached the Host");
        }
    }
}

#[test]
fn a_create_is_the_routes_body_with_the_preset_resolved() {
    let host = FakeHost::ok();
    let created = host
        .call(
            "create_schedule",
            json!({
                "name": "Morning briefing",
                "project_id": "q",
                "preset": "claude",
                "trigger": daily(),
                "instructions": "Summarise my inbox",
                "notify_when_done": false,
            }),
            Some(ROUTER),
        )
        .expect("created");
    assert_eq!(created, json!({ "schedule": { "id": "sch_new" } }));
    let (path, body) = host.only_request();
    assert_eq!(path, "/mobile/schedules");
    assert_eq!(
        body,
        json!({
            "name": "Morning briefing",
            "projectID": "q",
            "presetID": "global-claude",
            "trigger": daily(),
            "instructions": "Summarise my inbox",
            "notifyWhenDone": false,
        })
    );
}

#[test]
fn a_preset_label_resolves_in_the_tasks_project_first() {
    let host = FakeHost::ok();
    host.call(
        "create_schedule",
        json!({ "name": "Backup", "project_id": "p", "preset": "Backup", "trigger": daily() }),
        Some(ROUTER),
    )
    .expect("created");
    assert_eq!(host.only_request().1["presetID"], "p-script");
}

#[test]
fn a_trigger_may_come_as_json_text() {
    let host = FakeHost::ok();
    host.call(
        "create_schedule",
        json!({
            "name": "Hourly",
            "project_id": "p",
            "preset": "p-script",
            "trigger": "{\"kind\":\"hourly\",\"minute\":5}",
        }),
        Some(ROUTER),
    )
    .expect("created");
    assert_eq!(
        host.only_request().1["trigger"],
        json!({ "kind": "hourly", "minute": 5 })
    );
}

#[test]
fn a_create_says_what_is_missing_before_it_reaches_the_host() {
    let complete =
        json!({ "name": "N", "project_id": "p", "preset": "p-script", "trigger": daily() });
    let without = |key: &str| {
        let mut arguments = complete.clone();
        arguments.as_object_mut().unwrap().remove(key);
        arguments
    };
    let cases = [
        (without("project_id"), "project_id"),
        (without("preset"), "preset"),
        (without("trigger"), "trigger"),
        (
            json!({ "name": "N", "project_id": "p", "preset": "Off", "trigger": daily() }),
            "Off",
        ),
        (
            json!({ "name": "N", "project_id": "p", "preset": "p-script", "trigger": "daily" }),
            "trigger",
        ),
        (
            json!({ "name": "N", "project_id": "p", "preset": "p-script", "trigger": daily(), "enabled": "no" }),
            "enabled",
        ),
    ];
    for (arguments, named) in cases {
        let host = FakeHost::ok();
        let refused = host
            .call("create_schedule", arguments.clone(), Some(ROUTER))
            .expect_err("refused");
        assert!(refused.contains(named), "{arguments}: {refused}");
        assert!(host.nothing_sent(), "{arguments}");
    }
}

#[test]
fn an_unknown_preset_lists_the_projects_presets() {
    let host = FakeHost::ok();
    let refused = host
        .call(
            "create_schedule",
            json!({ "name": "N", "project_id": "p", "preset": "nope", "trigger": daily() }),
            Some(ROUTER),
        )
        .expect_err("refused");
    assert!(
        refused.contains("Backup") && refused.contains("Claude"),
        "{refused}"
    );
}

#[test]
fn an_edit_sends_only_what_changes() {
    let host = FakeHost::ok();
    host.call(
        "edit_schedule",
        json!({ "schedule_id": "sch_daily", "name": "Evening", "trigger": daily(), "instructions": "" }),
        Some(ROUTER),
    )
    .expect("edited");
    let (path, body) = host.only_request();
    assert_eq!(path, "/mobile/schedules/edit");
    assert_eq!(
        body,
        json!({ "scheduleID": "sch_daily", "name": "Evening", "trigger": daily(), "instructions": null })
    );
}

#[test]
fn pausing_and_resuming_are_edits_of_enabled() {
    for enabled in [false, true] {
        let host = FakeHost::ok();
        host.call(
            "edit_schedule",
            json!({ "schedule_id": "sch_daily", "enabled": enabled }),
            Some(ROUTER),
        )
        .expect("edited");
        assert_eq!(
            host.only_request().1,
            json!({ "scheduleID": "sch_daily", "enabled": enabled })
        );
    }
}

#[test]
fn an_edited_preset_resolves_in_the_project_the_task_will_have() {
    let host = FakeHost::ok();
    // The task is in q; its preset label resolves there unless it moves.
    host.call(
        "edit_schedule",
        json!({ "schedule_id": "sch_daily", "preset": "Backup" }),
        Some(ROUTER),
    )
    .expect("edited");
    assert_eq!(host.only_request().1["presetID"], "q-script");
    let host = FakeHost::ok();
    host.call(
        "edit_schedule",
        json!({ "schedule_id": "sch_daily", "project_id": "p", "preset": "Backup" }),
        Some(ROUTER),
    )
    .expect("edited");
    let body = host.only_request().1;
    assert_eq!(
        (&body["projectID"], &body["presetID"]),
        (&json!("p"), &json!("p-script"))
    );
}

#[test]
fn an_edit_with_nothing_to_change_is_refused() {
    let host = FakeHost::ok();
    let refused = host
        .call(
            "edit_schedule",
            json!({ "schedule_id": "sch_daily" }),
            Some(ROUTER),
        )
        .expect_err("refused");
    assert!(refused.contains("nothing to change"), "{refused}");
    assert!(host.nothing_sent());
}

#[test]
fn delete_and_run_name_the_task() {
    for (action, route) in [
        ("delete_schedule", "/mobile/schedules/delete"),
        ("run_schedule", "/mobile/schedules/run"),
    ] {
        let host = FakeHost::answering(200, json!({ "scheduleID": "sch_daily" }));
        host.call(
            action,
            json!({ "schedule_id": " sch_daily " }),
            Some(ROUTER),
        )
        .expect("answered");
        assert_eq!(
            host.only_request(),
            (route.to_owned(), json!({ "scheduleID": "sch_daily" }))
        );
        let host = FakeHost::ok();
        let refused = host
            .call(action, json!({}), Some(ROUTER))
            .expect_err("refused");
        assert!(refused.contains("schedule_id"), "{refused}");
        assert!(host.nothing_sent());
    }
}

#[test]
fn a_host_refusal_keeps_its_message_and_code() {
    let host = FakeHost::answering(
        409,
        json!({ "error": "a Run of Briefing is in progress", "code": "run_in_progress" }),
    );
    let refused = host
        .call(
            "run_schedule",
            json!({ "schedule_id": "sch_daily" }),
            Some(ROUTER),
        )
        .expect_err("refused");
    assert!(
        refused.contains("a Run of Briefing is in progress") && refused.contains("run_in_progress"),
        "{refused}"
    );
}

#[test]
fn a_transport_failure_is_the_error() {
    let post = |_: &str, _: &Value| Err::<(u16, Value), String>("no Host".into());
    let refused = answer(
        "run_schedule",
        &json!({ "schedule_id": "sch_daily" }),
        Some(ROUTER),
        &state(),
        &post,
    )
    .expect_err("refused");
    assert_eq!(refused, "no Host");
}
