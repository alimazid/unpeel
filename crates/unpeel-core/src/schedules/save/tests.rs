use super::*;

fn project(id: &str, path: &str) -> HostCreateProject {
    HostCreateProject {
        id: id.into(),
        path: path.into(),
        is_folder: false,
        worktree_path: None,
        worktree_branch: None,
    }
}

fn preset(id: &str, command: &str, project_id: Option<&str>) -> HostCreatePreset {
    HostCreatePreset {
        id: id.into(),
        command: command.into(),
        enabled: true,
        project_id: project_id.map(str::to_owned),
    }
}

fn catalog() -> (Vec<HostCreateProject>, Vec<HostCreatePreset>) {
    (
        vec![
            project("p", "/work"),
            HostCreateProject {
                worktree_path: Some("/work-feature".into()),
                worktree_branch: Some("feature".into()),
                ..project("wt", "/work")
            },
            project("no-folder", " "),
        ],
        vec![
            preset("ok", "echo global", None),
            preset("ok", "echo mine", Some("p")),
            preset("claude", "claude", None),
            HostCreatePreset {
                enabled: false,
                ..preset("off", "claude", None)
            },
        ],
    )
}

fn refusal(project_id: &str, preset_id: &str, instructions: Option<&str>) -> Option<SaveRefusal> {
    let (projects, presets) = catalog();
    check_runnable(project_id, preset_id, instructions, &projects, &presets).err()
}

#[test]
fn a_run_starts_the_projects_own_preset_in_its_folder() {
    let (projects, presets) = catalog();
    let target = check_runnable("p", "ok", None, &projects, &presets).expect("runs");
    assert_eq!(target.preset.command, "echo mine");
    assert_eq!(target.cwd, "/work");
    let worktree = check_runnable("wt", "ok", None, &projects, &presets).expect("runs");
    assert_eq!(worktree.preset.command, "echo global");
    assert_eq!(worktree.cwd, "/work-feature");
}

#[test]
fn a_task_needs_a_project_with_a_folder_and_an_enabled_preset() {
    assert_eq!(refusal(" ", "ok", None), Some(SaveRefusal::NoProject));
    assert_eq!(
        refusal("gone", "ok", None),
        Some(SaveRefusal::ProjectMissing("gone".into()))
    );
    assert_eq!(
        refusal("no-folder", "ok", None),
        Some(SaveRefusal::ProjectHasNoFolder("no-folder".into()))
    );
    assert_eq!(refusal("p", "", None), Some(SaveRefusal::NoPreset));
    assert_eq!(
        refusal("p", "off", None),
        Some(SaveRefusal::PresetMissing("off".into()))
    );
}

#[test]
fn instructions_are_for_an_agent_preset_only_and_capped() {
    assert_eq!(refusal("p", "claude", Some("brief me")), None);
    assert_eq!(
        refusal("p", "ok", Some("brief me")),
        Some(SaveRefusal::NotAgentPreset("ok".into()))
    );
    assert_eq!(refusal("p", "ok", Some("  \n")), None, "blank is none");
    let huge = "x".repeat(MAX_INSTRUCTIONS_BYTES + 1);
    assert_eq!(
        refusal("p", "claude", Some(&huge)),
        Some(SaveRefusal::InstructionsTooLarge)
    );
    let (projects, presets) = catalog();
    let target = check_runnable("p", "claude", Some("brief me"), &projects, &presets).unwrap();
    assert_eq!(target.instructions, Some("brief me"));
}

#[test]
fn every_refusal_has_a_stable_code_and_a_sentence() {
    let cases = [
        (SaveRefusal::NoProject, "project_missing"),
        (SaveRefusal::ProjectMissing("p".into()), "project_missing"),
        (
            SaveRefusal::ProjectHasNoFolder("p".into()),
            "project_missing",
        ),
        (SaveRefusal::NoPreset, "preset_missing"),
        (SaveRefusal::PresetMissing("x".into()), "preset_missing"),
        (SaveRefusal::NotAgentPreset("x".into()), "not_agent_preset"),
        (SaveRefusal::InstructionsTooLarge, "instructions_too_large"),
        (SaveRefusal::InvalidTrigger("bad".into()), "invalid_trigger"),
        (SaveRefusal::TriggerInPast("then".into()), "trigger_in_past"),
        (SaveRefusal::ResumeInPast("then".into()), "trigger_in_past"),
        (SaveRefusal::CatalogUnavailable, "host_unavailable"),
    ];
    for (refusal, code) in cases {
        assert_eq!(refusal.code(), code, "{refusal:?}");
        assert!(!refusal.to_string().is_empty());
    }
    assert_eq!(
        SaveRefusal::InstructionsTooLarge.to_string(),
        "the instructions are longer than 256 KiB"
    );
    assert_eq!(
        SaveRefusal::from(TriggerRefusal::InPast(
            "2026-01-01T09:00 is in the past".into()
        )),
        SaveRefusal::TriggerInPast("2026-01-01T09:00 is in the past".into())
    );
}

#[test]
fn the_limit_reads_from_the_cap() {
    assert_eq!(instructions_limit(), "256 KiB");
}

#[test]
fn a_new_entry_is_the_one_stored_shape() {
    let trigger = ScheduleTrigger::Daily {
        time: "09:00".into(),
    };
    let task = NewTask {
        name: "Morning",
        project_id: "p",
        preset_id: "claude",
        trigger: &trigger,
        instructions: Some("brief me"),
        enabled: false,
        notify_when_done: true,
    };
    let entry = new_entry(&task, 42);
    let id = entry["id"].as_str().unwrap().to_owned();
    assert!(
        id.starts_with("sch_") && super::super::is_valid_id(&id),
        "{id}"
    );
    assert_eq!(
        entry,
        json!({
            "id": id,
            "name": "Morning",
            "project_id": "p",
            "preset_id": "claude",
            "trigger": {"kind": "daily", "time": "09:00"},
            "enabled": false,
            "notify_when_done": true,
            "created_at_ms": 42,
            "instructions": "brief me",
        })
    );
    let bare = new_entry(
        &NewTask {
            instructions: Some(" "),
            ..task
        },
        42,
    );
    assert!(bare.get("instructions").is_none());
    assert_ne!(bare["id"], entry["id"], "a fresh id each time");
}

#[test]
fn the_schedules_list_is_made_but_never_overwritten() {
    let mut state = Map::new();
    schedules_list_mut(&mut state)
        .expect("made")
        .push(json!({"id": "sch_1", "x": 1}));
    assert_eq!(state["schedules"], json!([{"id": "sch_1", "x": 1}]));
    let list = schedules_list_mut(&mut state).unwrap();
    assert_eq!(
        entry_mut(list, "sch_1").map(|entry| entry["x"].clone()),
        Some(json!(1))
    );
    assert!(entry_mut(list, "sch_2").is_none());
    let mut broken = Map::from_iter([("schedules".to_owned(), json!({"not": "a list"}))]);
    assert!(schedules_list_mut(&mut broken).is_err());
}

/// A Host whose clock reads any Once before 2026 as past, and records each
/// Trigger it is asked to check.
#[derive(Default)]
struct FakeHost {
    checks: std::sync::Mutex<Vec<(ScheduleTrigger, bool)>>,
}

impl FakeHost {
    fn checks(&self) -> Vec<(ScheduleTrigger, bool)> {
        self.checks.lock().unwrap().clone()
    }
}

impl SaveHost for FakeHost {
    fn check_trigger(
        &self,
        trigger: &ScheduleTrigger,
        comes_due: bool,
    ) -> Result<ScheduleTrigger, TriggerRefusal> {
        self.checks
            .lock()
            .unwrap()
            .push((trigger.clone(), comes_due));
        match trigger {
            ScheduleTrigger::Once { at } if comes_due && at.as_str() < "2026" => {
                Err(TriggerRefusal::InPast(format!("{at} is in the past")))
            }
            ScheduleTrigger::Unknown => Err(TriggerRefusal::Invalid("unknown Trigger kind".into())),
            other => Ok(other.clone()),
        }
    }

    fn catalog(&self) -> Option<(Vec<HostCreateProject>, Vec<HostCreatePreset>)> {
        Some(catalog())
    }
}

fn past_once() -> Value {
    json!({"kind": "once", "at": "2001-01-01T09:00"})
}

#[test]
fn an_edit_that_gives_no_trigger_or_the_stored_one_checks_nothing() {
    let host = FakeHost::default();
    let stored = past_once();
    assert_eq!(
        check_edited_trigger(&host, None, Some(&stored), true),
        Ok(None)
    );
    assert_eq!(
        check_edited_trigger(&host, Some(&past_once()), Some(&stored), true),
        Ok(None),
        "a finished Once sent back unchanged, even on an enabled task"
    );
    let newer = json!({"kind": "fortnightly", "on": "tuesday"});
    assert_eq!(
        check_edited_trigger(&host, Some(&newer), Some(&newer), true),
        Ok(None),
        "compared in the stored form, so a kind this build cannot read is kept"
    );
    assert!(host.checks().is_empty(), "{:?}", host.checks());
}

#[test]
fn a_different_trigger_must_come_due_only_while_the_task_will_be_enabled() {
    let host = FakeHost::default();
    let stored = json!({"kind": "daily", "time": "09:00"});
    assert_eq!(
        check_edited_trigger(&host, Some(&past_once()), Some(&stored), true),
        Err(SaveRefusal::TriggerInPast(
            "2001-01-01T09:00 is in the past".into()
        ))
    );
    let once = ScheduleTrigger::Once {
        at: "2001-01-01T09:00".into(),
    };
    assert_eq!(
        check_edited_trigger(&host, Some(&past_once()), Some(&stored), false),
        Ok(Some(once.clone())),
        "a paused task saves a past Once as is"
    );
    assert_eq!(host.checks(), vec![(once.clone(), true), (once, false)]);
    let other = json!({"kind": "fortnightly"});
    assert_eq!(
        check_edited_trigger(&host, Some(&other), Some(&stored), false),
        Err(SaveRefusal::InvalidTrigger("unknown Trigger kind".into())),
        "an unreadable Trigger is never saved"
    );
}

#[test]
fn resuming_a_once_whose_time_passed_asks_for_a_new_time() {
    let host = FakeHost::default();
    let refusal = check_resume(
        &host,
        &ScheduleTrigger::Once {
            at: "2001-01-01T09:00".into(),
        },
    )
    .expect_err("refused");
    assert_eq!(
        refusal,
        SaveRefusal::ResumeInPast("2001-01-01T09:00 is in the past".into())
    );
    assert_eq!(refusal.code(), "trigger_in_past");
    assert_eq!(
        refusal.to_string(),
        "2001-01-01T09:00 is in the past; give it a new time"
    );
    assert_eq!(
        check_resume(&host, &ScheduleTrigger::Unknown),
        Err(SaveRefusal::InvalidTrigger("unknown Trigger kind".into()))
    );
    let daily = ScheduleTrigger::Daily {
        time: "09:00".into(),
    };
    assert_eq!(check_resume(&host, &daily), Ok(()));
    assert!(
        host.checks().iter().all(|(_, comes_due)| *comes_due),
        "a resumed task must come due"
    );
}

#[test]
fn a_project_with_no_folder_is_refused_for_every_preset() {
    let host = FakeHost::default();
    for (preset, instructions) in [("ok", None), ("claude", Some("brief me"))] {
        let refusal = check_task_runs(&host, "no-folder", preset, instructions)
            .expect_err("no folder for a Run to start in");
        assert_eq!(refusal, SaveRefusal::ProjectHasNoFolder("no-folder".into()));
        assert_eq!(refusal.code(), "project_missing", "{preset}");
    }
}
