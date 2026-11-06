//! The CLI's half of the save rules (`unpeel_core::schedules::save`), which
//! it runs with no Host: a Trigger is checked on this machine's clock by
//! the same function the Host's workspace worker uses, and Projects and
//! presets resolve against what the CLI reads from `app-state.json` and the
//! app's overlay, the same sources it selects them from.

use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::schedules::save::{SaveHost, TriggerRefusal};
use unpeel_core::schedules::ScheduleTrigger;
use unpeel_serve::schedules::{clock, trigger};

pub(super) struct CliHost;

impl SaveHost for CliHost {
    fn check_trigger(
        &self,
        trigger: &ScheduleTrigger,
        comes_due: bool,
    ) -> Result<ScheduleTrigger, TriggerRefusal> {
        trigger::for_save(trigger, comes_due, clock::now().datetime())
    }

    fn catalog(&self) -> Option<(Vec<HostCreateProject>, Vec<HostCreatePreset>)> {
        Some(catalog())
    }
}

/// The Projects (each with its folder) and presets this workspace defines,
/// in `app-state.json` and the app's own overlay.
fn catalog() -> (Vec<HostCreateProject>, Vec<HostCreatePreset>) {
    let state = unpeel_serve::sessions::load_app_state();
    let overlay = unpeel_serve::overlay::load();
    let mut projects: Vec<HostCreateProject> = state
        .iter()
        .flat_map(|state| &state.projects)
        .map(|project| create_project(&project.id, &project.path, project.worktree_branch.clone()))
        .collect();
    let mut presets: Vec<HostCreatePreset> = state
        .iter()
        .flat_map(|state| &state.presets)
        .map(|preset| HostCreatePreset {
            id: preset.id.clone(),
            command: preset.command.clone(),
            enabled: preset.enabled,
            project_id: preset.project_id.clone(),
        })
        .collect();
    if let Some(overlay) = &overlay {
        projects.extend(overlay.projects.iter().map(|(id, _)| {
            let path = overlay.project_paths.get(id).map_or("", String::as_str);
            let branch = overlay
                .child_parents
                .get(id)
                .and_then(|(_, branch)| branch.clone());
            create_project(id, path, branch)
        }));
        // The ids `resolve_preset` gives the app's own presets.
        presets.extend(overlay.presets.iter().map(|(label, command)| HostCreatePreset {
            id: format!("overlay-{label}"),
            command: command.clone(),
            enabled: true,
            project_id: None,
        }));
    }
    (projects, presets)
}

/// A worktree Project's own path is its checkout, as the Host publishes it.
fn create_project(id: &str, path: &str, worktree_branch: Option<String>) -> HostCreateProject {
    HostCreateProject {
        id: id.to_owned(),
        path: path.to_owned(),
        is_folder: false,
        worktree_path: worktree_branch.as_ref().map(|_| path.to_owned()),
        worktree_branch,
    }
}
