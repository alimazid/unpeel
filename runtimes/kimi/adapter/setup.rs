use crate::app_paths::machine_home;
use crate::hook_assets::{write_executable_script, write_file_atomic};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) const KIMI_HOOK_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../runtimes/kimi/assets/hooks/lifecycle.sh"
));

/// Install the Kimi integration: the lifecycle hook block in Kimi's config
/// (both generations) and the Unpeel MCP shim as a persistent entry in Kimi
/// Code's `mcp.json`. Legacy Kimi, which only took per-launch MCP flags,
/// keeps hooks and detection but no MCP.
pub fn install() -> Result<(), String> {
    let script_path = kimi_hook_script_path();
    write_executable_script(&script_path, &crate::hook_assets::reporter_script(KIMI_HOOK_SCRIPT), "Kimi hook script")?;
    ensure_kimi_config_hooks()?;
    write_kimi_code_mcp_config()
}
pub(crate) fn kimi_share_dir() -> Option<PathBuf> {
    std::env::var_os("KIMI_SHARE_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|home| home.join(".kimi")))
}

pub(crate) fn kimi_hook_script_path() -> PathBuf {
    machine_home().join("hooks").join("kimi-hook.sh")
}

pub(crate) fn kimi_config_path() -> Option<PathBuf> {
    Some(kimi_share_dir()?.join("config.toml"))
}

pub(crate) fn kimi_code_home_dir() -> Option<PathBuf> {
    let path = std::env::var_os("KIMI_CODE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".kimi-code"));
    if path.is_absolute() {
        Some(path)
    } else {
        Some(std::env::current_dir().ok()?.join(path))
    }
}

pub(crate) fn kimi_code_config_path() -> Option<PathBuf> {
    Some(kimi_code_home_dir()?.join("config.toml"))
}

pub(crate) fn kimi_code_mcp_config_path() -> Option<PathBuf> {
    Some(kimi_code_home_dir()?.join("mcp.json"))
}

pub fn kimi_global_mcp_config_path() -> Option<PathBuf> {
    Some(kimi_share_dir()?.join("mcp.json"))
}
pub(crate) const KIMI_MANAGED_HOOKS_START: &str = "# BEGIN UNPEEL MANAGED KIMI HOOKS";
pub(crate) const KIMI_MANAGED_HOOKS_END: &str = "# END UNPEEL MANAGED KIMI HOOKS";

pub(crate) fn kimi_hook_command(event: &str) -> String {
    format!("\"${{UNPEEL_HOME:-$HOME/.unpeel}}/hooks/kimi-hook.sh\" {event}")
}

pub(crate) fn toml_basic_string(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
    )
}

pub(crate) fn kimi_managed_hooks_block(kimi_code: bool) -> String {
    let mut definitions = vec![
        ("SessionStart", None, "HookSeen"),
        ("UserPromptSubmit", None, "UserPromptSubmit"),
        ("Stop", None, "Stop"),
        ("StopFailure", None, "StopFailure"),
        ("SessionEnd", None, "SessionEnd"),
        ("Notification", Some("permission_prompt"), "Attention"),
        (
            "PreToolUse",
            Some("ask_user_question|AskUserQuestion"),
            "Attention",
        ),
    ];
    if kimi_code {
        // These observation hooks are native to standalone Kimi Code. Keep
        // them out of the legacy Python CLI config, whose event enum predates
        // both names and may reject unknown values.
        definitions.push(("Interrupt", None, "StopCancelled"));
        definitions.push(("PermissionRequest", None, "Attention"));
    }
    let mut block = String::new();
    block.push_str(KIMI_MANAGED_HOOKS_START);
    block.push('\n');
    for (event, matcher, action) in definitions {
        block.push_str("\n[[hooks]]\n");
        block.push_str(&format!("event = {}\n", toml_basic_string(event)));
        if let Some(matcher) = matcher {
            block.push_str(&format!("matcher = {}\n", toml_basic_string(matcher)));
        }
        block.push_str(&format!(
            "command = {}\n",
            toml_basic_string(&kimi_hook_command(action))
        ));
        block.push_str("timeout = 5\n");
    }
    block.push('\n');
    block.push_str(KIMI_MANAGED_HOOKS_END);
    block
}

pub(crate) fn strip_kimi_marker_block(raw: &str) -> String {
    let mut updated = String::new();
    let mut skipping = false;
    for line in raw.split_inclusive('\n') {
        match line.trim() {
            KIMI_MANAGED_HOOKS_START => skipping = true,
            KIMI_MANAGED_HOOKS_END => skipping = false,
            _ if !skipping => updated.push_str(line),
            _ => {}
        }
    }
    updated
}

pub(crate) fn strip_kimi_hook_tables(raw: &str) -> String {
    fn flush(out: &mut String, segment: &mut String, is_hook: bool) {
        if !(is_hook && segment.contains("hooks/kimi-hook.sh")) {
            out.push_str(segment);
        }
        segment.clear();
    }

    let mut updated = String::new();
    let mut segment = String::new();
    let mut segment_is_hook = false;
    for line in raw.split_inclusive('\n') {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && !segment.is_empty() {
            flush(&mut updated, &mut segment, segment_is_hook);
        }
        if trimmed.starts_with('[') {
            segment_is_hook = trimmed == "[[hooks]]";
        }
        segment.push_str(line);
    }
    flush(&mut updated, &mut segment, segment_is_hook);
    updated
}

pub(crate) fn reconcile_kimi_config(raw: &str, kimi_code: bool) -> Result<String, String> {
    if !raw.trim().is_empty() {
        toml::from_str::<toml::Value>(raw)
            .map_err(|e| format!("Existing Kimi config.toml is invalid: {e}"))?;
    }
    let without_markers = strip_kimi_marker_block(raw);
    let without_old_hooks = strip_kimi_hook_tables(&without_markers);
    let mut updated = without_old_hooks.trim_end().to_string();
    if !updated.is_empty() {
        updated.push_str("\n\n");
    }
    updated.push_str(&kimi_managed_hooks_block(kimi_code));
    updated.push('\n');
    toml::from_str::<toml::Value>(&updated)
        .map_err(|e| format!("Generated Kimi config.toml is invalid: {e}"))?;
    Ok(updated)
}

pub(crate) fn ensure_kimi_config_hooks_at(
    config_path: &Path,
    kimi_code: bool,
) -> Result<(), String> {
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create Kimi config dir {}: {e}", parent.display()))?;
    }
    let _settings_lock = crate::app_state::lock_exclusive(config_path)?;
    let raw = if config_path.exists() {
        fs::read_to_string(config_path)
            .map_err(|e| format!("Failed to read Kimi config.toml: {e}"))?
    } else {
        String::new()
    };
    let Ok(updated) = reconcile_kimi_config(&raw, kimi_code) else {
        // Never replace a malformed user config with an Unpeel-only file.
        return Ok(());
    };
    if updated != raw {
        write_file_atomic(config_path, &updated, "Kimi config.toml")?;
    }
    Ok(())
}

pub(crate) fn ensure_kimi_config_hooks() -> Result<(), String> {
    let legacy = kimi_config_path();
    let code = kimi_code_config_path();
    if legacy == code {
        if let Some(path) = code {
            ensure_kimi_config_hooks_at(&path, true)?;
        }
        return Ok(());
    }
    if let Some(path) = legacy {
        ensure_kimi_config_hooks_at(&path, false)?;
    }
    if let Some(path) = code {
        ensure_kimi_config_hooks_at(&path, true)?;
    }
    Ok(())
}

pub(crate) fn kimi_code_managed_mcp_entry(shim: &Path) -> Value {
    json!({
        "command": shim.to_string_lossy(),
        "args": [],
    })
}

/// An entry is Unpeel-owned when it starts the shim, or (older builds) the
/// Host binary through the gate with this `kind`.
pub(crate) fn kimi_code_entry_is_managed(value: &Value, kind: &str) -> bool {
    let shim = value
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(crate::integrations::install::is_mcp_shim_command);
    shim || value
        .get("args")
        .and_then(Value::as_array)
        .is_some_and(|args| {
            args.first().and_then(Value::as_str) == Some(crate::mcp_gate::MCP_GATE_ARG)
                && args.get(1).and_then(Value::as_str) == Some(kind)
        })
}

pub(crate) fn upsert_kimi_code_managed_mcp(
    servers: &mut serde_json::Map<String, Value>,
    preferred_name: &str,
    kind: &str,
    entry: Value,
) {
    let fallback_name = format!("{preferred_name}-unpeel");
    let name = match servers.get(preferred_name) {
        None => preferred_name,
        Some(existing) if kimi_code_entry_is_managed(existing, kind) => preferred_name,
        Some(_) => fallback_name.as_str(),
    };
    if servers
        .get(name)
        .is_none_or(|existing| kimi_code_entry_is_managed(existing, kind))
    {
        servers.insert(name.to_string(), entry);
    }
}

/// Kimi Code only reads persistent MCP configuration. Install one `unpeel`
/// entry that starts the shim; its gate exposes the real tools only inside a
/// granted hosted Session. Outside Unpeel (and in ungranted sessions) the
/// server stays connected with an empty tool list.
pub(crate) fn write_kimi_code_mcp_config() -> Result<(), String> {
    let Some(path) = kimi_code_mcp_config_path() else {
        return Ok(());
    };
    let mut config = if path.is_file() {
        let raw = fs::read_to_string(&path)
            .map_err(|error| format!("Failed to read Kimi Code MCP config: {error}"))?;
        if raw.trim().is_empty() {
            json!({})
        } else {
            let Ok(value) = serde_json::from_str::<Value>(&raw) else {
                // Never replace malformed user configuration.
                return Ok(());
            };
            value
        }
    } else {
        json!({})
    };
    let Some(root) = config.as_object_mut() else {
        return Ok(());
    };
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| Value::Object(serde_json::Map::new()));
    let Some(servers) = servers.as_object_mut() else {
        return Ok(());
    };

    let shim = crate::integrations::install::write_mcp_shim()?;
    upsert_kimi_code_managed_mcp(
        servers,
        "unpeel",
        crate::mcp_gate::UNIFIED_KIND,
        kimi_code_managed_mcp_entry(&shim),
    );
    // The `unpeel` entry supersedes the older names: `unpeel-mcp` (pre-rename
    // unified entry) and the per-domain gate entries. Remove ours (identified
    // by the gate argv) and leave user-authored entries alone.
    for (name, kind) in [
        ("unpeel-mcp", crate::mcp_gate::UNIFIED_KIND),
        ("unpeel-sessions", crate::mcp_gate::SESSIONS_KIND),
        ("unpeel-browser", crate::mcp_gate::BROWSER_KIND),
    ] {
        for candidate in [name.to_string(), format!("{name}-unpeel")] {
            if servers
                .get(&candidate)
                .is_some_and(|entry| kimi_code_entry_is_managed(entry, kind))
            {
                servers.remove(&candidate);
            }
        }
    }

    let serialized = serde_json::to_string_pretty(&config)
        .map_err(|error| format!("Failed to serialize Kimi Code MCP config: {error}"))?;
    write_file_atomic(&path, &format!("{serialized}\n"), "Kimi Code MCP config")
}
