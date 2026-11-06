use super::*;
use serde_json::json;
use std::collections::HashMap;
use std::fs;

const SAMPLES: &str = include_str!("../../../../protocol/schedules-samples-v1.json");

fn samples() -> Value {
    serde_json::from_str(SAMPLES).expect("valid schedules samples")
}

/// A private root seeded with the samples' per-task files: never this
/// machine's `UNPEEL_HOME`.
fn with_seeded_root<T>(body: impl FnOnce(&Value, &Path) -> T) -> T {
    let samples = samples();
    let root = std::env::temp_dir().join(format!("unpeel-csched-{}", uuid::Uuid::new_v4()));
    let seed = &samples["seed"];
    for (id, clock) in seed["clocks"].as_object().expect("clocks") {
        let dir = root.join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("clock.json"), serde_json::to_vec(clock).unwrap()).unwrap();
    }
    for (id, lines) in seed["runs"].as_object().expect("runs") {
        let dir = root.join(id);
        fs::create_dir_all(&dir).unwrap();
        let mut log = Vec::new();
        for line in lines.as_array().expect("run lines") {
            serde_json::to_writer(&mut log, line).unwrap();
            log.push(b'\n');
        }
        fs::write(dir.join("runs.jsonl"), log).unwrap();
    }
    let outcome = body(&seed["appState"], &root);
    let _ = fs::remove_dir_all(&root);
    outcome
}

fn query(value: &Value) -> HashMap<String, String> {
    value
        .as_object()
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), value.as_str().unwrap_or_default().to_owned()))
                .collect()
        })
        .unwrap_or_default()
}

fn without_revision(mut body: Value) -> Value {
    if let Some(object) = body.as_object_mut() {
        object.remove("revision");
    }
    body
}

#[test]
fn the_list_is_the_samples_answer() {
    let expected = samples()["responses"]["list"].clone();
    with_seeded_root(|state, root| {
        let body = list_at(state, root);
        let revision = body["revision"].as_str().unwrap_or_default().to_owned();
        assert_eq!(
            revision.len(),
            16,
            "an opaque 64-bit revision: {revision:?}"
        );
        assert_eq!(without_revision(body), without_revision(expected));
    });
}

#[test]
fn run_history_is_the_samples_answer_newest_first() {
    let samples = samples();
    with_seeded_root(|state, root| {
        for name in ["runs", "limitedRuns"] {
            let sample = &samples["responses"][name];
            let answer = runs_at(state, root, &query(&sample["query"]));
            assert_eq!(answer, Ok(sample["body"].clone()), "{name}");
        }
    });
}

#[test]
fn run_history_names_what_is_wrong_with_its_query() {
    with_seeded_root(|state, root| {
        let status = |pairs: &[(&str, &str)]| {
            let query = pairs
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect();
            runs_at(state, root, &query)
                .map(|_| 200)
                .unwrap_or_else(|f| f.status)
        };
        assert_eq!(status(&[]), 400, "no schedule id");
        assert_eq!(status(&[("scheduleID", "../escape")]), 400);
        assert_eq!(status(&[("scheduleID", "sch_gone")]), 404);
        assert_eq!(status(&[("scheduleID", "sch_daily"), ("limit", "0")]), 400);
        assert_eq!(
            status(&[("scheduleID", "sch_daily"), ("limit", "many")]),
            400
        );
        assert_eq!(status(&[("scheduleID", "sch_daily"), ("limit", "")]), 200);
        assert_eq!(status(&[("scheduleID", "sch_future")]), 200, "no Runs yet");
    });
}

#[test]
fn a_task_with_no_state_yet_lists_with_nothing_to_show() {
    let state = json!({ "schedules": [{ "id": "sch_new", "name": "New" }] });
    let root = std::env::temp_dir().join(format!("unpeel-csched-{}", uuid::Uuid::new_v4()));
    let body = list_at(&state, &root);
    assert_eq!(body["schedules"][0]["nextRun"], Value::Null);
    assert_eq!(body["schedules"][0]["lastRun"], Value::Null);
    assert_eq!(
        runs_at(&state, &root, &query(&json!({"scheduleID": "sch_new"}))),
        Ok(json!({ "scheduleID": "sch_new", "runs": [] }))
    );
}

#[test]
fn a_damaged_clock_costs_only_its_next_run() {
    with_seeded_root(|state, root| {
        fs::write(root.join("sch_daily").join("clock.json"), b"{not json").unwrap();
        let body = list_at(state, root);
        assert_eq!(body["schedules"][0]["nextRun"], Value::Null);
        assert_eq!(body["schedules"][0]["lastRun"]["runID"], "run_skipped");
        assert_eq!(body["schedules"].as_array().map(Vec::len), Some(6));
    });
}

#[test]
fn the_revision_moves_with_every_change_a_controller_can_see() {
    with_seeded_root(|state, root| {
        let first = revision_at(state, root);
        assert_eq!(
            first,
            revision_at(state, root),
            "stable while nothing changes"
        );
        assert_eq!(
            first,
            list_at(state, root)["revision"],
            "the list carries it"
        );

        let mut renamed = state.clone();
        renamed["schedules"][0]["name"] = json!("Evening briefing");
        assert_ne!(first, revision_at(&renamed, root), "a definition edit");

        let unrelated = json!({ "schedules": state["schedules"].clone(), "presets": [] });
        assert_eq!(
            first,
            revision_at(&unrelated, root),
            "the rest of app-state"
        );

        // A Run line that is not the latest still changes the history.
        let log = root.join("sch_daily").join("runs.jsonl");
        let mut raw = fs::read(&log).unwrap();
        raw.extend_from_slice(br#"{"run_id":"run_now","status":"failed","reason":"superseded"}"#);
        raw.push(b'\n');
        fs::write(&log, raw).unwrap();
        let after_run = revision_at(state, root);
        assert_ne!(first, after_run, "an older Run's new line");

        fs::write(
            root.join("sch_daily").join("clock.json"),
            br#"{"next_occurrence":"2026-11-08T09:43","next_occurrence_ms":1794148980000}"#,
        )
        .unwrap();
        assert_ne!(after_run, revision_at(state, root), "a new next run");
    });
}

#[test]
fn every_principal_may_read_and_the_router_answers_both_routes() {
    let principal = ControllerPrincipal::PairedDevice {
        device_id: "phone".into(),
        name: "Phone".into(),
        principal_id: None,
    };
    assert!(principal_can_read_schedules(&principal));
    let request = |path: &str, query: &[(&str, &str)]| ControllerRequest {
        id: None,
        method: "GET".into(),
        path: path.into(),
        query: query
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect(),
        body: Value::Null,
        content_type: None,
        body_base64: None,
        principal: principal.clone(),
    };
    let missing = route(&request("/mobile/schedules/runs", &[])).expect("routed");
    assert_eq!(missing.status, 400);
    assert_eq!(missing.body["error"], "valid scheduleID required");
    assert!(route(&request("/mobile/schedulesx", &[])).is_none());
    let mut post = request("/mobile/schedules", &[]);
    post.method = "POST".into();
    let write = route(&post).expect("writes are routed here too");
    assert_eq!(write.status, 400, "a create needs an object body");
}

#[test]
fn every_preset_row_says_whether_it_is_an_agent_preset() {
    let mut presets = vec![
        json!({"id": "claude", "command": "claude --dangerously-skip-permissions"}),
        json!({"id": "codex", "command": "/opt/bin/codex"}),
        json!({"id": "script", "command": "./backup.sh"}),
        json!({"id": "no-signal", "command": "pi"}),
        json!({"id": "blank", "command": ""}),
        json!({"id": "no-command"}),
    ];
    mark_agent_presets(&mut presets);
    let flags: Vec<_> = presets
        .iter()
        .map(|row| (row["id"].as_str().unwrap(), row["agentPreset"].as_bool()))
        .collect();
    assert_eq!(
        flags,
        vec![
            ("claude", Some(true)),
            ("codex", Some(true)),
            ("script", Some(false)),
            ("no-signal", Some(false)),
            ("blank", Some(false)),
            ("no-command", Some(false)),
        ]
    );
}

/// The Host says which presets turn off their agent's approval prompts,
/// from each runtime's own declared flags: a Controller only warns.
#[test]
fn every_preset_row_says_whether_it_bypasses_approvals() {
    let mut presets = vec![
        json!({"id": "claude", "command": "claude --dangerously-skip-permissions"}),
        json!({"id": "claude-mode", "command": "claude --permission-mode bypassPermissions"}),
        json!({"id": "claude-eq", "command": "claude --permission-mode=bypassPermissions"}),
        json!({"id": "claude-plan", "command": "claude --permission-mode plan"}),
        json!({"id": "codex", "command": "/opt/bin/codex --dangerously-bypass-approvals-and-sandbox"}),
        json!({"id": "gemini-y", "command": "gemini -y"}),
        json!({"id": "cursor", "command": "cursor-agent --force"}),
        // A flag another runtime reads that way means nothing here.
        json!({"id": "claude-force", "command": "claude --force"}),
        json!({"id": "plain", "command": "claude"}),
        json!({"id": "script", "command": "./deploy.sh --yolo"}),
        json!({"id": "flag-as-head", "command": "--yolo"}),
        json!({"id": "no-command"}),
    ];
    mark_agent_presets(&mut presets);
    let flags: Vec<_> = presets
        .iter()
        .map(|row| {
            (
                row["id"].as_str().unwrap(),
                row["bypassesApprovals"].as_bool(),
            )
        })
        .collect();
    assert_eq!(
        flags,
        vec![
            ("claude", Some(true)),
            ("claude-mode", Some(true)),
            ("claude-eq", Some(true)),
            ("claude-plan", Some(false)),
            ("codex", Some(true)),
            ("gemini-y", Some(true)),
            ("cursor", Some(true)),
            ("claude-force", Some(false)),
            ("plain", Some(false)),
            ("script", Some(false)),
            ("flag-as-head", Some(false)),
            ("no-command", Some(false)),
        ]
    );
}
