use crate::app_paths::machine_home;
use crate::hook_assets::{read_mergeable_json_object, write_executable_script, write_file_atomic};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) const CLINE_HOOK_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../runtimes/cline/assets/hooks/lifecycle.sh"
));

pub(crate) const CLINE_HOOK_EVENTS: &[&str] = &[
    "TaskStart",
    "TaskResume",
    "TaskCancel",
    "TaskComplete",
    "TaskError",
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "SessionShutdown",
];
/// Install the Cline integration: one managed shim per global hook event
/// under `~/.cline/hooks/`, and the Unpeel MCP shim merged into Cline's own
/// user MCP settings. Cline's shared hub daemon inherits whichever session
/// started it; the hook and gate both resolve the calling Session from the
/// hosted environment (or process ancestry), so concurrent sessions stay
/// distinct without per-session hubs.
pub fn install() -> Result<(), String> {
    let script_path = cline_hook_script_path();
    write_executable_script(&script_path, &crate::hook_assets::reporter_script(CLINE_HOOK_SCRIPT), "Cline hook script")?;

    let hooks_dir = cline_home_dir().join("hooks");
    fs::create_dir_all(&hooks_dir).map_err(|e| {
        format!(
            "Failed to create Cline hooks dir {}: {e}",
            hooks_dir.display()
        )
    })?;
    let quoted_script = crate::integrations::shared::shell_quote(&script_path.to_string_lossy());
    for event in CLINE_HOOK_EVENTS {
        let contents = format!(
            "#!/bin/bash\n# Managed by Unpeel. Local edits are replaced.\nexec {quoted_script} {event}\n"
        );
        write_cline_event_hook(&hooks_dir, event, &contents)?;
    }
    let shim = crate::integrations::install::write_mcp_shim()?;
    ensure_cline_user_mcp_server(&shim)
}

/// Cline's user MCP settings file (`CLINE_MCP_SETTINGS_PATH`, else
/// `<CLINE_DATA_DIR>/settings/cline_mcp_settings.json`, else
/// `~/.cline/data/settings/cline_mcp_settings.json`).
pub fn cline_user_mcp_config_path() -> PathBuf {
    if let Some(path) =
        std::env::var_os("CLINE_MCP_SETTINGS_PATH").filter(|value| !value.is_empty())
    {
        return resolve_path(PathBuf::from(path));
    }
    if let Some(path) = std::env::var_os("CLINE_DATA_DIR").filter(|value| !value.is_empty()) {
        return resolve_path(PathBuf::from(path))
            .join("settings")
            .join("cline_mcp_settings.json");
    }
    cline_home_dir()
        .join("data")
        .join("settings")
        .join("cline_mcp_settings.json")
}

fn resolve_path(path: PathBuf) -> PathBuf {
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

pub(crate) fn cline_mcp_server_value(shim: &Path) -> Value {
    json!({
        "transport": {
            "type": "stdio",
            "command": shim.to_string_lossy(),
            "args": [],
        }
    })
}

pub(crate) fn ensure_cline_user_mcp_server(shim: &Path) -> Result<(), String> {
    let path = cline_user_mcp_config_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "Failed to create Cline settings dir {}: {e}",
                parent.display()
            )
        })?;
    }
    let _lock = crate::app_state::lock_exclusive(&path)?;
    let Some(mut config) = read_mergeable_json_object(&path, "Cline MCP settings")? else {
        return Ok(());
    };
    let root = config.as_object_mut().unwrap();
    let servers = root.entry("mcpServers").or_insert_with(|| json!({}));
    if !servers.is_object() {
        return Ok(());
    }
    let servers = servers.as_object_mut().unwrap();
    let desired = cline_mcp_server_value(shim);
    if servers.get("unpeel") == Some(&desired) {
        return Ok(());
    }
    servers.insert("unpeel".into(), desired);
    let serialized = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Failed to serialize Cline MCP settings: {e}"))?;
    write_file_atomic(&path, &format!("{serialized}\n"), "Cline MCP settings")
}

pub(crate) fn write_cline_event_hook(
    hooks_dir: &Path,
    event: &str,
    contents: &str,
) -> Result<(), String> {
    const MANAGED_MARKER: &str = "# Managed by Unpeel.";
    // Cline recognizes every one of these as the same event basename and runs
    // multiple matching files. Prefer `.bash`, but never overwrite a user's
    // hook: reuse our existing slot or take the next unoccupied extension.
    let candidates = [
        hooks_dir.join(format!("{event}.bash")),
        hooks_dir.join(format!("{event}.zsh")),
        hooks_dir.join(format!("{event}.sh")),
        hooks_dir.join(event),
    ];

    let managed = candidates.iter().find(|path| {
        fs::read_to_string(path)
            .map(|value| value.contains(MANAGED_MARKER))
            .unwrap_or(false)
    });
    let target = managed
        .cloned()
        .or_else(|| candidates.iter().find(|path| !path.exists()).cloned())
        .ok_or_else(|| {
            format!(
                "Cline already has user-owned hooks in every supported slot for {event}; \
                 Unpeel left them untouched."
            )
        })?;
    write_executable_script(&target, contents, "Cline lifecycle hook")
}
pub(crate) fn cline_hook_script_path() -> PathBuf {
    machine_home().join("hooks").join("cline-hook.sh")
}

pub fn cline_home_dir() -> PathBuf {
    let path = std::env::var_os("CLINE_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".cline")
        });
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}
