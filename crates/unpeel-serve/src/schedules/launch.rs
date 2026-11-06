//! Where a task's Run starts: its Project's directory and its preset's
//! command as typed, resolved against the Host's create catalog by the save
//! rules every writer checks (`unpeel_core::schedules::save`), so a Run
//! refuses exactly what a save would. A reason comes back when it cannot
//! start.

use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::schedules::save;
use unpeel_core::schedules::Schedule;

use super::step::{LaunchPlan, RunKind};

pub fn resolve(
    schedule: &Schedule,
    projects: &[HostCreateProject],
    presets: &[HostCreatePreset],
) -> Result<LaunchPlan, String> {
    let target = save::check_runnable(
        &schedule.project_id,
        &schedule.preset_id,
        schedule.instructions.as_deref(),
        projects,
        presets,
    )
    .map_err(|refusal| refusal.to_string())?;
    Ok(LaunchPlan {
        project_id: target.project.id.clone(),
        preset_id: target.preset.id.clone(),
        command: target.preset.command.clone(),
        cwd: target.cwd.to_owned(),
        worktree_path: target.project.worktree_path.clone(),
        worktree_branch: target.project.worktree_branch.clone(),
        kind: if unpeel_core::agent_readiness::is_agent_command(&target.preset.command) {
            RunKind::Agent {
                instructions: target.instructions.map(str::to_owned),
            }
        } else {
            RunKind::Script
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use unpeel_core::schedules::ScheduleTrigger;

    fn schedule(project_id: &str, preset_id: &str) -> Schedule {
        Schedule {
            id: "sch_1".into(),
            name: "Morning".into(),
            project_id: project_id.into(),
            preset_id: preset_id.into(),
            instructions: None,
            trigger: ScheduleTrigger::Unknown,
            enabled: true,
            notify_when_done: true,
            created_at_ms: 0,
            clock_reset_at_ms: None,
        }
    }

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

    #[test]
    fn a_run_starts_the_presets_command_in_the_projects_folder() {
        let plan = resolve(
            &schedule("p", "ok"),
            &[project("p", "/work")],
            &[
                preset("ok", "echo global", None),
                preset("ok", "echo mine", Some("p")),
            ],
        )
        .expect("launchable");
        assert_eq!(plan.command, "echo mine", "the Project's own preset wins");
        assert_eq!(plan.cwd, "/work");
        assert_eq!(plan.preset_id, "ok");
    }

    #[test]
    fn a_worktree_project_runs_in_its_worktree() {
        let mut worktree = project("w", "/repo-feature");
        worktree.worktree_path = Some("/repo-feature".into());
        worktree.worktree_branch = Some("feature".into());
        let plan = resolve(
            &schedule("w", "ok"),
            &[worktree],
            &[preset("ok", "true", None)],
        )
        .expect("launchable");
        assert_eq!(plan.cwd, "/repo-feature");
        assert_eq!(plan.worktree_branch.as_deref(), Some("feature"));
    }

    #[test]
    fn a_missing_project_or_preset_is_the_reason_it_cannot_start() {
        let presets = [preset("ok", "true", None)];
        let gone = resolve(&schedule("gone", "ok"), &[project("p", "/work")], &presets);
        assert_eq!(gone, Err("the Project gone does not exist on this Host".into()));

        let folder = resolve(&schedule("f", "ok"), &[project("f", " ")], &presets);
        assert!(folder.unwrap_err().contains("no folder"));

        let deleted = resolve(
            &schedule("p", "deleted"),
            &[project("p", "/work")],
            &presets,
        );
        assert_eq!(
            deleted,
            Err("the preset deleted does not exist in that Project or is turned off".into())
        );

        let mut disabled = preset("ok", "true", None);
        disabled.enabled = false;
        assert!(resolve(&schedule("p", "ok"), &[project("p", "/work")], &[disabled]).is_err());

        let elsewhere = preset("ok", "true", Some("other"));
        assert!(resolve(&schedule("p", "ok"), &[project("p", "/work")], &[elsewhere]).is_err());
    }

    fn with_instructions(preset_id: &str, instructions: &str) -> Schedule {
        Schedule {
            instructions: Some(instructions.into()),
            ..schedule("p", preset_id)
        }
    }

    #[test]
    fn an_agent_presets_run_carries_its_instructions() {
        let presets = [
            preset("claude", "claude --model opus", None),
            preset("ok", "true", None),
        ];
        let projects = [project("p", "/work")];
        let plan = resolve(
            &with_instructions("claude", "brief me"),
            &projects,
            &presets,
        )
        .expect("launchable");
        assert_eq!(plan.kind.instructions(), Some("brief me"));
        assert_eq!(plan.command, "claude --model opus", "launched as typed");
        assert!(plan.kind.is_agent());

        // Blank instructions are none: the Run is done once the agent is ready.
        let blank = resolve(&with_instructions("claude", "  \n"), &projects, &presets).unwrap();
        assert_eq!(blank.kind, RunKind::Agent { instructions: None });
        let script = resolve(&schedule("p", "ok"), &projects, &presets).unwrap();
        assert_eq!(script.kind, RunKind::Script);
    }

    #[test]
    fn instructions_the_preset_cannot_take_are_the_reason_it_cannot_start() {
        let presets = [preset("ok", "true", None), preset("claude", "claude", None)];
        let projects = [project("p", "/work")];
        let script = resolve(&with_instructions("ok", "brief me"), &projects, &presets);
        assert!(
            script.as_ref().unwrap_err().contains("not an Agent Preset"),
            "{script:?}"
        );
        let huge = "x".repeat(unpeel_core::initial_text::MAX_INITIAL_TEXT_BYTES + 1);
        let too_long = resolve(&with_instructions("claude", &huge), &projects, &presets);
        assert!(too_long.unwrap_err().contains("256 KiB"));
    }
}
