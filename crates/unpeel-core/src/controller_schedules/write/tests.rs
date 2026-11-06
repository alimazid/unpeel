use super::*;
use serde_json::json;
use std::sync::Mutex;

/// A private `app-state.json` and schedules root: never this machine's
/// `UNPEEL_HOME`.
struct Private {
    dir: std::path::PathBuf,
    workspace: Workspace,
}

impl Private {
    fn new(state: Value) -> Self {
        let dir = std::env::temp_dir().join(format!("unpeel-cwrite-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("app-state.json");
        std::fs::write(&path, serde_json::to_vec(&state).unwrap()).unwrap();
        let workspace = Workspace::at(&path, &dir.join("schedules"));
        Self { dir, workspace }
    }

    fn state(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.dir.join("app-state.json")).unwrap()).unwrap()
    }

    /// The tasks as `GET /mobile/schedules` lists them.
    fn listed(&self) -> Vec<Value> {
        super::super::list_at(&self.state(), &self.dir.join("schedules"))["schedules"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }
}

impl Drop for Private {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The worker, faked: a catalog, a Trigger check that refuses a past Once
/// and writes times without zero seconds, and a scripted Run now.
struct FakeHost {
    checks: Mutex<Vec<(ScheduleTrigger, bool)>>,
    run_now: Result<String, RunNowRefusal>,
}

impl FakeHost {
    fn new() -> Self {
        Self {
            checks: Mutex::new(Vec::new()),
            run_now: Ok("run_fake".into()),
        }
    }

    fn refusing_run_now(refusal: RunNowRefusal) -> Self {
        Self {
            run_now: Err(refusal),
            ..Self::new()
        }
    }

    fn checks(&self) -> Vec<(ScheduleTrigger, bool)> {
        self.checks.lock().unwrap().clone()
    }
}

impl ScheduleHost for FakeHost {
    fn catalog(&self) -> Option<(Vec<HostCreateProject>, Vec<HostCreatePreset>)> {
        let project = |id: &str, path: &str| HostCreateProject {
            id: id.into(),
            path: path.into(),
            is_folder: path.is_empty(),
            worktree_path: None,
            worktree_branch: None,
        };
        let preset = |id: &str, command: &str, project_id: Option<&str>| HostCreatePreset {
            id: id.into(),
            command: command.into(),
            enabled: true,
            project_id: project_id.map(str::to_owned),
        };
        Some((
            vec![project("p", "/work"), project("group", "")],
            vec![
                preset("ok", "true", None),
                preset("claude", "claude", None),
                HostCreatePreset {
                    enabled: false,
                    ..preset("off", "true", None)
                },
                preset("mine", "claude --resume", Some("p")),
            ],
        ))
    }

    fn check_trigger(
        &self,
        trigger: &ScheduleTrigger,
        comes_due: bool,
    ) -> Result<ScheduleTrigger, String> {
        self.checks
            .lock()
            .unwrap()
            .push((trigger.clone(), comes_due));
        match trigger {
            ScheduleTrigger::Once { at } if comes_due && at.as_str() < "2026" => {
                Err(format!("{at} is in the past"))
            }
            ScheduleTrigger::Daily { time } if time.matches(':').count() == 2 => {
                Ok(ScheduleTrigger::Daily {
                    time: time.strip_suffix(":00").unwrap_or(time).to_owned(),
                })
            }
            ScheduleTrigger::Unknown => Err("unknown Trigger kind".into()),
            other => Ok(other.clone()),
        }
    }

    fn run_now(&self, _schedule_id: &str) -> Result<String, RunNowRefusal> {
        self.run_now.clone()
    }
}

fn post(path: &str, body: Value) -> ControllerRequest {
    ControllerRequest {
        id: None,
        method: "POST".into(),
        path: path.into(),
        query: Default::default(),
        body,
        content_type: Some("application/json".into()),
        body_base64: None,
        principal: ControllerPrincipal::PairedDevice {
            device_id: "phone".into(),
            name: "Phone".into(),
            principal_id: None,
        },
    }
}

const NOW_MS: u64 = 1_794_000_000_000;

fn answer_with(
    request: &ControllerRequest,
    host: Option<&dyn ScheduleHost>,
    private: &Private,
) -> (u16, Value) {
    answer(request, host, &private.workspace, NOW_MS).expect("a write route")
}

fn daily_body() -> Value {
    json!({
        "name": "  Morning briefing  ",
        "projectID": "p",
        "presetID": "ok",
        "trigger": {"kind": "daily", "time": "09:43:00"},
    })
}

// ── create ──

#[test]
fn a_created_task_is_saved_with_its_defaults_and_listed() {
    let private = Private::new(json!({}));
    let host = FakeHost::new();
    let (status, body) = answer_with(&post(CREATE_PATH, daily_body()), Some(&host), &private);
    assert_eq!(status, 200, "{body}");
    let listed = private.listed();
    assert_eq!(listed.len(), 1);
    let task = &listed[0];
    assert_eq!(body["schedule"], *task, "the answer is the listed row");
    assert!(task["id"].as_str().is_some_and(|id| id.starts_with("sch_")));
    assert_eq!(task["name"], "Morning briefing");
    assert_eq!(task["projectID"], "p");
    assert_eq!(task["presetID"], "ok");
    assert_eq!(
        task["trigger"],
        json!({"kind": "daily", "time": "09:43"}),
        "stored as the Host's check writes it"
    );
    assert_eq!(task["enabled"], true);
    assert_eq!(task["notifyWhenDone"], true);
    assert_eq!(task["createdAtMs"], NOW_MS);
    assert!(task.get("instructions").is_none());
    assert_eq!(
        host.checks(),
        vec![(
            ScheduleTrigger::Daily {
                time: "09:43:00".into()
            },
            true
        )]
    );
}

#[test]
fn a_task_on_an_agent_preset_keeps_its_instructions_and_its_settings() {
    let private = Private::new(json!({"schedules": [], "a_future_key": 1}));
    let mut body = daily_body();
    body["presetID"] = json!("claude");
    body["instructions"] = json!("brief me");
    body["enabled"] = json!(false);
    body["notifyWhenDone"] = json!(false);
    let host = FakeHost::new();
    let (status, answer) = answer_with(&post(CREATE_PATH, body), Some(&host), &private);
    assert_eq!(status, 200, "{answer}");
    let task = &private.listed()[0];
    assert_eq!(task["instructions"], "brief me");
    assert_eq!(
        (&task["enabled"], &task["notifyWhenDone"]),
        (&json!(false), &json!(false))
    );
    assert_eq!(
        private.state()["a_future_key"],
        1,
        "other keys pass through"
    );
    assert!(!host.checks()[0].1, "a paused task need not come due");
}

#[test]
fn a_project_scoped_preset_resolves_in_its_project() {
    let private = Private::new(json!({}));
    let mut body = daily_body();
    body["presetID"] = json!("mine");
    body["instructions"] = json!("resume and report");
    let (status, answer) = answer_with(&post(CREATE_PATH, body), Some(&FakeHost::new()), &private);
    assert_eq!(status, 200, "{answer}");
}

#[test]
fn a_create_the_host_would_not_run_is_refused_and_nothing_is_saved() {
    let cases: Vec<(&str, Value, &str)> = vec![
        ("no name", json!({"name": " "}), "name"),
        ("control characters", json!({"name": "a\u{7}b"}), "control"),
        ("no Project", json!({"projectID": null}), "Project"),
        ("unknown Project", json!({"projectID": "gone"}), "Project"),
        ("a group", json!({"projectID": "group"}), "folder"),
        ("unknown preset", json!({"presetID": "gone"}), "preset"),
        ("disabled preset", json!({"presetID": "off"}), "preset"),
        (
            "another Project's preset",
            json!({"projectID": "p", "presetID": "nope"}),
            "preset",
        ),
        ("no Trigger", json!({"trigger": null}), "Trigger"),
        (
            "a Trigger that is not one",
            json!({"trigger": "daily"}),
            "Trigger",
        ),
        (
            "unknown kind",
            json!({"trigger": {"kind": "fortnightly"}}),
            "unknown Trigger",
        ),
        (
            "past Once",
            json!({"trigger": {"kind": "once", "at": "2000-01-01T00:00"}}),
            "in the past",
        ),
        (
            "instructions on a script",
            json!({"instructions": "hello"}),
            "Agent Preset",
        ),
        ("enabled not a bool", json!({"enabled": "yes"}), "enabled"),
        (
            "notify not a bool",
            json!({"notifyWhenDone": 1}),
            "notifyWhenDone",
        ),
        (
            "instructions not text",
            json!({"presetID": "claude", "instructions": 5}),
            "instructions",
        ),
    ];
    let host = FakeHost::new();
    for (what, change, says) in cases {
        let private = Private::new(json!({}));
        let mut body = daily_body();
        for (key, value) in change.as_object().unwrap() {
            body[key] = value.clone();
        }
        let (status, answer) = answer_with(&post(CREATE_PATH, body), Some(&host), &private);
        assert_eq!(status, 400, "{what}: {answer}");
        let message = answer["error"].as_str().unwrap_or_default();
        assert!(message.contains(says), "{what}: {message:?} names {says:?}");
        assert!(
            message.chars().count() <= 240,
            "{what}: fits a Controller's message"
        );
        assert!(private.listed().is_empty(), "{what}: nothing saved");
    }
}

#[test]
fn instructions_past_the_create_cap_are_refused() {
    let private = Private::new(json!({}));
    let mut body = daily_body();
    body["presetID"] = json!("claude");
    body["instructions"] = json!("x".repeat(crate::initial_text::MAX_INITIAL_TEXT_BYTES + 1));
    let (status, answer) = answer_with(&post(CREATE_PATH, body), Some(&FakeHost::new()), &private);
    assert_eq!(status, 400);
    assert!(answer["error"]
        .as_str()
        .unwrap_or_default()
        .contains("256 KiB"));
}

#[test]
fn blank_instructions_are_none() {
    let private = Private::new(json!({}));
    let mut body = daily_body();
    body["instructions"] = json!("  \n");
    let (status, _) = answer_with(&post(CREATE_PATH, body), Some(&FakeHost::new()), &private);
    assert_eq!(status, 200, "a script preset with no real instructions");
    assert!(private.listed()[0].get("instructions").is_none());
}

#[test]
fn without_the_host_service_nothing_is_written() {
    let private = Private::new(json!({}));
    let (status, answer) = answer_with(&post(CREATE_PATH, daily_body()), None, &private);
    assert_eq!(status, 503, "{answer}");
    assert!(private.listed().is_empty());
}

#[test]
fn a_body_that_is_not_an_object_is_refused() {
    let private = Private::new(json!({}));
    for path in [CREATE_PATH, EDIT_PATH, DELETE_PATH, RUN_PATH] {
        let (status, _) = answer_with(&post(path, json!(["no"])), Some(&FakeHost::new()), &private);
        assert_eq!(status, 400, "{path}");
    }
}

#[test]
fn reads_and_other_paths_are_not_write_routes() {
    let private = Private::new(json!({}));
    let mut get = post(CREATE_PATH, json!({}));
    get.method = "GET".into();
    assert!(answer(&get, None, &private.workspace, NOW_MS).is_none());
    assert!(answer(
        &post("/mobile/schedules/other", json!({})),
        None,
        &private.workspace,
        NOW_MS
    )
    .is_none());
}

// ── edit, pause, resume ──

fn stored() -> Value {
    json!({"schedules": [{
        "id": "sch_1",
        "name": "Morning",
        "project_id": "p",
        "preset_id": "claude",
        "instructions": "brief me",
        "trigger": {"kind": "daily", "time": "09:00"},
        "enabled": true,
        "notify_when_done": true,
        "created_at_ms": 7,
        "a_future_field": [1, 2]
    }]})
}

fn edit(private: &Private, host: &FakeHost, change: Value) -> (u16, Value) {
    let mut body = json!({"scheduleID": "sch_1"});
    for (key, value) in change.as_object().unwrap() {
        body[key] = value.clone();
    }
    answer_with(&post(EDIT_PATH, body), Some(host), private)
}

fn stored_entry(private: &Private) -> Value {
    private.state()["schedules"][0].clone()
}

#[test]
fn an_edit_changes_what_it_names_and_keeps_the_rest() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    let (status, body) = edit(
        &private,
        &host,
        json!({"name": "Evening", "notifyWhenDone": false}),
    );
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["schedule"], private.listed()[0]);
    let entry = stored_entry(&private);
    assert_eq!(entry["name"], "Evening");
    assert_eq!(entry["notify_when_done"], false);
    assert_eq!(entry["instructions"], "brief me");
    assert_eq!(
        entry["a_future_field"],
        json!([1, 2]),
        "unknown fields pass through"
    );
    assert!(
        entry.get("clock_reset_at_ms").is_none(),
        "the clock is kept"
    );
    assert!(
        host.checks().is_empty(),
        "an unchanged Trigger is not checked"
    );
}

#[test]
fn a_new_trigger_is_checked_stored_as_checked_and_restarts_the_clock() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    let (status, body) = edit(
        &private,
        &host,
        json!({"trigger": {"kind": "daily", "time": "10:30:00"}}),
    );
    assert_eq!(status, 200, "{body}");
    let entry = stored_entry(&private);
    assert_eq!(entry["trigger"], json!({"kind": "daily", "time": "10:30"}));
    assert_eq!(entry["clock_reset_at_ms"], NOW_MS);
    assert_eq!(host.checks().len(), 1);
    assert!(
        host.checks()[0].1,
        "an enabled task's Trigger must come due"
    );

    let (status, body) = edit(
        &private,
        &host,
        json!({"trigger": {"kind": "once", "at": "2000-01-01T00:00"}}),
    );
    assert_eq!(status, 400, "{body}");
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("in the past"));
    assert_eq!(
        stored_entry(&private)["trigger"]["time"],
        "10:30",
        "nothing saved"
    );
}

#[test]
fn the_same_trigger_sent_back_is_not_checked_again() {
    let mut state = stored();
    state["schedules"][0]["trigger"] = json!({"kind": "cron", "expr": "0 9 * * 1-5"});
    let private = Private::new(state);
    let host = FakeHost::new();
    let (status, _) = edit(
        &private,
        &host,
        json!({"name": "Renamed", "trigger": {"kind": "cron", "expr": "0 9 * * 1-5"}}),
    );
    assert_eq!(status, 200);
    assert!(host.checks().is_empty());
    assert!(stored_entry(&private).get("clock_reset_at_ms").is_none());
}

#[test]
fn pausing_keeps_the_clock_and_resuming_restarts_it_once_the_trigger_comes_due() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    assert_eq!(edit(&private, &host, json!({"enabled": false})).0, 200);
    assert_eq!(stored_entry(&private)["enabled"], false);
    assert!(stored_entry(&private).get("clock_reset_at_ms").is_none());
    assert!(host.checks().is_empty(), "pausing checks nothing");
    assert_eq!(private.listed()[0]["nextRun"], Value::Null);

    assert_eq!(edit(&private, &host, json!({"enabled": true})).0, 200);
    assert_eq!(stored_entry(&private)["enabled"], true);
    assert_eq!(stored_entry(&private)["clock_reset_at_ms"], NOW_MS);
    assert_eq!(
        host.checks(),
        vec![(
            ScheduleTrigger::Daily {
                time: "09:00".into()
            },
            true
        )],
        "resuming checks the Trigger still comes due"
    );
}

#[test]
fn a_paused_once_whose_time_passed_renames_but_does_not_resume() {
    let mut state = stored();
    state["schedules"][0]["trigger"] = json!({"kind": "once", "at": "2000-01-01T00:00"});
    state["schedules"][0]["enabled"] = json!(false);
    let private = Private::new(state);
    let host = FakeHost::new();
    assert_eq!(edit(&private, &host, json!({"name": "Old"})).0, 200);
    let (status, body) = edit(&private, &host, json!({"enabled": true}));
    assert_eq!(status, 400, "{body}");
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("in the past"));
    assert_eq!(stored_entry(&private)["enabled"], false);
    assert_eq!(stored_entry(&private)["name"], "Old");
}

#[test]
fn instructions_are_set_removed_and_checked_against_the_preset_the_task_will_have() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    assert_eq!(
        edit(&private, &host, json!({"instructions": "new words"})).0,
        200
    );
    assert_eq!(stored_entry(&private)["instructions"], "new words");

    let (status, body) = edit(&private, &host, json!({"presetID": "ok"}));
    assert_eq!(
        status, 400,
        "a script preset cannot keep the instructions: {body}"
    );
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("Agent Preset"));

    let (status, body) = edit(
        &private,
        &host,
        json!({"presetID": "ok", "instructions": ""}),
    );
    assert_eq!(status, 200, "{body}");
    let entry = stored_entry(&private);
    assert_eq!(entry["preset_id"], "ok");
    assert!(entry.get("instructions").is_none());

    assert_eq!(
        edit(&private, &host, json!({"instructions": "on a script"})).0,
        400
    );
    assert_eq!(edit(&private, &host, json!({"instructions": null})).0, 200);
}

#[test]
fn an_edit_is_checked_like_a_create() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    let (status, body) = edit(&private, &host, json!({"projectID": "gone"}));
    assert_eq!(status, 400, "{body}");
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("Project"));
    assert_eq!(edit(&private, &host, json!({"name": " "})).0, 400);
    assert_eq!(edit(&private, &host, json!({"enabled": "no"})).0, 400);
    assert_eq!(stored_entry(&private), stored()["schedules"][0]);
}

#[test]
fn an_edit_names_a_task_that_exists() {
    let private = Private::new(stored());
    let host = FakeHost::new();
    let status = |body: Value, host: Option<&dyn ScheduleHost>| {
        answer_with(&post(EDIT_PATH, body), host, &private).0
    };
    assert_eq!(status(json!({"name": "x"}), Some(&host)), 400);
    assert_eq!(status(json!({"scheduleID": "../x"}), Some(&host)), 400);
    assert_eq!(
        status(json!({"scheduleID": "sch_gone", "name": "x"}), Some(&host)),
        404
    );
    assert_eq!(
        status(json!({"scheduleID": "sch_gone"}), None),
        404,
        "an unknown task is unknown on any Host"
    );
}

// ── delete ──

#[test]
fn delete_removes_the_task_and_its_history_and_keeps_the_others() {
    let mut state = stored();
    state["schedules"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id": "sch_2", "name": "Other"}));
    let private = Private::new(state);
    let history = private.dir.join("schedules").join("sch_1");
    std::fs::create_dir_all(&history).unwrap();
    std::fs::write(
        history.join("runs.jsonl"),
        b"{\"run_id\":\"run_a\",\"status\":\"done\"}\n",
    )
    .unwrap();

    let (status, body) = answer_with(
        &post(DELETE_PATH, json!({"scheduleID": "sch_1"})),
        None,
        &private,
    );
    assert_eq!(status, 200, "{body}");
    assert_eq!(body, json!({"scheduleID": "sch_1", "deleted": true}));
    let ids: Vec<_> = private.listed().iter().map(|t| t["id"].clone()).collect();
    assert_eq!(ids, vec![json!("sch_2")]);
    assert!(!history.exists(), "its clock and Run log go with it");

    let again = answer_with(
        &post(DELETE_PATH, json!({"scheduleID": "sch_1"})),
        None,
        &private,
    );
    assert_eq!(again.0, 404);
    let missing = answer_with(&post(DELETE_PATH, json!({})), None, &private);
    assert_eq!(missing.0, 400);
}

// ── Run now ──

#[test]
fn run_now_answers_the_new_run_or_why_not() {
    let private = Private::new(stored());
    let run = |host: Option<&dyn ScheduleHost>, id: &str| {
        answer_with(&post(RUN_PATH, json!({"scheduleID": id})), host, &private)
    };
    assert_eq!(
        run(Some(&FakeHost::new()), "sch_1"),
        (200, json!({"scheduleID": "sch_1", "runID": "run_fake"}))
    );
    let busy = FakeHost::refusing_run_now(RunNowRefusal::InProgress(
        "a Run of Morning is still in progress".into(),
    ));
    assert_eq!(
        run(Some(&busy), "sch_1"),
        (
            409,
            json!({"error": "a Run of Morning is still in progress"})
        )
    );
    let away = FakeHost::refusing_run_now(RunNowRefusal::Unavailable("not running".into()));
    assert_eq!(run(Some(&away), "sch_1").0, 503);
    let slow = FakeHost::refusing_run_now(RunNowRefusal::NoAnswer("timed out".into()));
    assert_eq!(run(Some(&slow), "sch_1").0, 504, "it may still start");
    assert_eq!(run(None, "sch_1").0, 503, "Run now needs the worker");
    assert_eq!(run(None, "sch_gone").0, 404);
    assert_eq!(run(None, "").0, 400);
}
