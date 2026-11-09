use crate::app_paths::machine_home;
use crate::hook_assets::{read_mergeable_json_object, write_executable_script, write_file_atomic};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) const CLAUDE_HOOK_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../runtimes/claude-code/assets/hooks/lifecycle.sh"
));

pub(crate) const HOOK_EVENTS: &[&str] = &[
    // SessionStart latches provider metadata only (the script forwards it as
    // HookSeen): it fires at launch and on in-tool /resume, /clear, /compact
    // with the new session_id, so precise resume tracks the conversation the
    // user actually switched to.
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "StopFailure",
    "PermissionRequest",
    "SubagentStart",
    "SubagentStop",
];
/// Install the Claude integration: the lifecycle hook script registered in
/// `~/.claude/settings.json`, and the Unpeel MCP shim registered as a
/// user-scope MCP server in `~/.claude.json` (the file `claude mcp add
/// --scope user` writes). Both merges preserve every foreign entry and
/// rewrite only on change.
pub fn install() -> Result<(), String> {
    let script_path = claude_hook_script_path();
    write_executable_script(&script_path, &crate::hook_assets::reporter_script(CLAUDE_HOOK_SCRIPT), "Claude hook script")?;
    ensure_claude_settings_hook(&script_path)?;
    let shim = crate::integrations::install::write_mcp_shim()?;
    ensure_claude_user_mcp_server(&shim)
}

/// Claude's user-scope MCP registry: the top-level `mcpServers` object of
/// `~/.claude.json`, shared by every project.
pub(crate) fn claude_user_config_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".claude.json"))
}

pub(crate) fn claude_mcp_server_value(shim: &Path) -> Value {
    json!({
        "type": "stdio",
        "command": shim.to_string_lossy(),
        "args": [],
    })
}

/// Reconcile the `unpeel` entry in a `~/.claude.json`-shaped object. Prunes
/// the pre-unification names only when they are Unpeel-owned; returns
/// whether anything changed.
pub(crate) fn reconcile_claude_mcp_servers(config: &mut Value, shim: &Path) -> bool {
    let Some(root) = config.as_object_mut() else {
        return false;
    };
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| json!({}));
    if !servers.is_object() {
        return false;
    }
    let servers = servers.as_object_mut().unwrap();
    let desired = claude_mcp_server_value(shim);
    let mut changed = false;
    if servers.get("unpeel") != Some(&desired) {
        servers.insert("unpeel".into(), desired);
        changed = true;
    }
    for legacy in ["unpeel-mcp", "unpeel-sessions", "unpeel-browser"] {
        let owned = servers.get(legacy).is_some_and(|entry| {
            entry
                .get("command")
                .and_then(Value::as_str)
                .is_some_and(|command| {
                    crate::integrations::install::is_mcp_shim_command(command)
                        || command.ends_with("unpeel-host")
                })
        });
        if owned {
            servers.remove(legacy);
            changed = true;
        }
    }
    changed
}

pub(crate) fn ensure_claude_user_mcp_server(shim: &Path) -> Result<(), String> {
    let Some(config_path) = claude_user_config_path() else {
        return Ok(());
    };
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "Failed to create Claude config dir {}: {e}",
                parent.display()
            )
        })?;
    }
    // Lock beside Unpeel's own state rather than dropping a `.claude.lock`
    // into the home directory root.
    let lock_target = machine_home().join("integrations").join("claude-user-config.json");
    if let Some(parent) = lock_target.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("Failed to create {}: {e}", parent.display()))?;
    }
    let _lock = crate::app_state::lock_exclusive(&lock_target)?;
    let Some(mut config) = read_mergeable_json_object(&config_path, "Claude user config")? else {
        // ~/.claude.json holds far more than MCP servers; never clobber a
        // file that does not parse as an object.
        return Ok(());
    };
    if reconcile_claude_mcp_servers(&mut config, shim) {
        let json = serde_json::to_string_pretty(&config)
            .map_err(|e| format!("Failed to serialize Claude user config: {e}"))?;
        write_file_atomic(&config_path, &format!("{json}\n"), "Claude user config")?;
    }
    Ok(())
}

pub(crate) fn claude_hook_script_path() -> PathBuf {
    machine_home().join("hooks").join("claude-hooks.sh")
}
pub(crate) fn claude_settings_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".claude").join("settings.json"))
}
pub(crate) fn build_hook_entry(event: &str, command: &str) -> Value {
    let mut entry = json!({
        "hooks": [{
            "type": "command",
            "command": command,
            // The provider must await our bounded reporter: background
            // UserPromptSubmit/Stop processes can arrive in reverse order.
            "async": false,
            "timeout": 5
        }]
    });
    if event == "PermissionRequest" {
        entry["matcher"] = Value::String("*".into());
    }
    entry
}

/// Unpeel-managed `claude-hooks.sh` copies left behind by tests or deleted
/// workspaces. Grok also runs Claude settings hooks, so a stale `/tmp/...`
/// copy that still posts `session_start` as busy will spin every Grok
/// session even after the live script is fixed.
pub(crate) fn is_stale_unpeel_claude_hook(command: &str, current: &str) -> bool {
    let path = command.split_whitespace().next().unwrap_or(command);
    if path == current {
        return false;
    }
    if !path.ends_with("claude-hooks.sh") {
        return false;
    }
    path.starts_with("/tmp/") || path.starts_with("/var/folders/") || !Path::new(path).is_file()
}

pub(crate) fn prune_stale_unpeel_claude_hooks(array: &mut Vec<Value>, current: &str) -> bool {
    let mut changed = false;
    array.retain_mut(|entry| {
        let Some(hooks) = entry
            .get_mut("hooks")
            .and_then(|value| value.as_array_mut())
        else {
            return true;
        };
        let before = hooks.len();
        hooks.retain(|hook| {
            hook.get("command")
                .and_then(|value| value.as_str())
                .is_none_or(|command| !is_stale_unpeel_claude_hook(command, current))
        });
        if hooks.len() != before {
            changed = true;
        }
        !hooks.is_empty()
    });
    changed
}

pub(crate) fn ensure_claude_settings_hook(script_path: &Path) -> Result<(), String> {
    let Some(settings_path) = claude_settings_path() else {
        return Ok(());
    };
    if let Some(parent) = settings_path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "Failed to create Claude settings dir {}: {e}",
                parent.display()
            )
        })?;
    }

    let _settings_lock = crate::app_state::lock_exclusive(&settings_path)?;
    let Some(mut settings) = read_mergeable_json_object(&settings_path, "Claude settings")? else {
        // Existing settings.json is not a valid JSON object; skip rather than
        // clobber the user's real settings with an Unpeel-only file.
        return Ok(());
    };

    let changed = reconcile_claude_hooks(&mut settings, &script_path.to_string_lossy());

    if changed {
        let json = serde_json::to_string_pretty(&settings)
            .map_err(|e| format!("Failed to serialize Claude settings: {e}"))?;
        write_file_atomic(&settings_path, &format!("{json}\n"), "Claude settings")?;
    }

    Ok(())
}

fn reconcile_claude_hooks(settings: &mut Value, command: &str) -> bool {
    let hooks = settings
        .as_object_mut()
        .unwrap()
        .entry("hooks")
        .or_insert_with(|| json!({}));
    if !hooks.is_object() {
        *hooks = json!({});
    }
    let hooks_obj = hooks.as_object_mut().unwrap();

    let mut changed = false;
    for event in HOOK_EVENTS {
        let entries = hooks_obj
            .entry((*event).to_string())
            .or_insert_with(|| json!([]));
        if !entries.is_array() {
            *entries = json!([]);
        }
        let array = entries.as_array_mut().unwrap();
        if prune_stale_unpeel_claude_hooks(array, command) {
            changed = true;
        }
        let mut already_installed = false;
        for entry in array.iter_mut() {
            if let Some(hooks) = entry.get_mut("hooks").and_then(Value::as_array_mut) {
                for hook in hooks {
                    if hook.get("command").and_then(Value::as_str) == Some(command) {
                        already_installed = true;
                        if hook.get("async").and_then(Value::as_bool) != Some(false) {
                            hook["async"] = json!(false);
                            changed = true;
                        }
                    }
                }
            }
        }
        if !already_installed {
            array.push(build_hook_entry(event, command));
            changed = true;
        }
    }

    changed
}

#[cfg(test)]
mod hook_reconciliation_tests {
    use super::*;

    #[test]
    fn user_scope_mcp_registration_merges_and_prunes_owned_entries_only() {
        let shim = Path::new("/home/me/.unpeel/bin/unpeel-mcp");
        let mut config = json!({
            "numStartups": 12,
            "mcpServers": {
                "unpeel-sessions": {"type": "stdio", "command": "/old/unpeel-host", "args": ["__mcp__"]},
                "unpeel-browser": {"type": "stdio", "command": "/user/custom-browser", "args": []},
                "github": {"type": "http", "url": "https://example.test"}
            }
        });
        assert!(reconcile_claude_mcp_servers(&mut config, shim));
        assert_eq!(config["numStartups"], 12);
        assert_eq!(config["mcpServers"]["unpeel"]["command"], json!(shim.to_string_lossy()));
        assert!(config["mcpServers"].get("unpeel-sessions").is_none());
        assert_eq!(config["mcpServers"]["unpeel-browser"]["command"], "/user/custom-browser");
        assert_eq!(config["mcpServers"]["github"]["type"], "http");
        assert!(!reconcile_claude_mcp_servers(&mut config, shim));
        let mut scalar = json!({"mcpServers": "bogus"});
        assert!(!reconcile_claude_mcp_servers(&mut scalar, shim));
    }

    #[test]
    fn migrates_owned_async_hooks_without_changing_foreign_hooks() {
        let command = "/owned/claude-hooks.sh";
        let foreign = json!({"type": "command", "command": "/user/audit.sh", "async": true});
        let mut settings = json!({
            "theme": "dark",
            "hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": command, "async": true, "timeout": 5},
                foreign.clone()
            ]}]}
        });
        assert!(reconcile_claude_hooks(&mut settings, command));
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][0]["async"], false);
        assert_eq!(settings["hooks"]["Stop"][0]["hooks"][1], foreign);
        assert_eq!(settings["theme"], "dark");
        assert!(!reconcile_claude_hooks(&mut settings, command));
    }
}
