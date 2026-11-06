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
                .unwrap_or_else(|f| f.0)
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
        assert_eq!(body["schedules"].as_array().map(Vec::len), Some(3));
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
    assert!(route(&post).is_none(), "writes are not this module's yet");
}
