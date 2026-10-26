use crate::app_paths::machine_home;
use crate::hook_assets::{write_executable_script, write_file_atomic};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub(crate) const CODEWHALE_HOOK_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../runtimes/codewhale/assets/hooks/lifecycle.sh"
));

/// Codewhale observer events and the reporter argument each one carries.
/// Steering events (`message_submit`, `tool_call_before`, `shell_env`) are
/// deliberately absent: they run in the foreground of every submit or tool
/// call, and a reporter there could only add latency.
pub(crate) const CODEWHALE_HOOK_EVENTS: &[(&str, &str)] = &[
    ("session_start", "HookSeen"),
    ("session_busy", "Busy"),
    ("waiting_for_user", "Attention"),
    ("turn_end", "TurnEnd"),
    ("session_idle", "Idle"),
    ("session_end", "Idle"),
];

pub(crate) const CODEWHALE_MANAGED_HOOKS_START: &str = "# BEGIN UNPEEL MANAGED CODEWHALE HOOKS";
pub(crate) const CODEWHALE_MANAGED_HOOKS_END: &str = "# END UNPEEL MANAGED CODEWHALE HOOKS";
const CODEWHALE_HOOK_SCRIPT_NAME: &str = "codewhale-hook.sh";

/// Install the Codewhale integration: the lifecycle reporter as managed
/// `[[hooks.hooks]]` entries in the config.toml Codewhale reads, and the
/// Unpeel MCP shim in the mcp.json it reads.
pub fn install() -> Result<(), String> {
    let script_path = codewhale_hook_script_path();
    write_executable_script(&script_path, CODEWHALE_HOOK_SCRIPT, "Codewhale hook script")?;
    let config_path =
        codewhale_config_path().ok_or("Could not resolve Codewhale's config.toml location")?;
    ensure_codewhale_hooks_at(&config_path, &script_path)?;
    let mcp_path = codewhale_mcp_config_path(&config_path)
        .ok_or("Could not resolve Codewhale's mcp.json location")?;
    let shim = crate::integrations::install::write_mcp_shim()?;
    write_codewhale_mcp_config_at(&mcp_path, &shim)
}

pub(crate) fn codewhale_hook_script_path() -> PathBuf {
    machine_home()
        .join("hooks")
        .join(CODEWHALE_HOOK_SCRIPT_NAME)
}

/// Where Codewhale keeps its state. `CODEWHALE_HOME` replaces the base
/// directory outright; otherwise `~/.codewhale` is current and the
/// pre-rename `~/.deepseek` remains a read fallback.
pub(crate) struct CodewhaleDirs {
    pub(crate) home: PathBuf,
    pub(crate) legacy: Option<PathBuf>,
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub(crate) fn codewhale_dirs() -> Option<CodewhaleDirs> {
    if let Some(home) = env_path("CODEWHALE_HOME") {
        return Some(CodewhaleDirs { home, legacy: None });
    }
    let user_home = dirs::home_dir()?;
    Some(CodewhaleDirs {
        home: user_home.join(".codewhale"),
        legacy: Some(user_home.join(".deepseek")),
    })
}

/// The state file Codewhale itself reads: the current one when it exists,
/// else a legacy `~/.deepseek` file, else the current path to create.
/// Writing a fresh current file beside a legacy one would hide the user's
/// legacy configuration (provider keys included) from Codewhale.
pub(crate) fn resolve_state_file(dirs: &CodewhaleDirs, name: &str) -> PathBuf {
    let current = dirs.home.join(name);
    if current.exists() {
        return current;
    }
    match &dirs.legacy {
        Some(legacy) if legacy.join(name).is_file() => legacy.join(name),
        _ => current,
    }
}

pub(crate) fn codewhale_config_path() -> Option<PathBuf> {
    env_path("CODEWHALE_CONFIG_PATH")
        .or_else(|| env_path("DEEPSEEK_CONFIG_PATH"))
        .or_else(|| codewhale_dirs().map(|dirs| resolve_state_file(&dirs, "config.toml")))
}

/// `DEEPSEEK_MCP_CONFIG` wins over the config's `mcp_config_path`, which wins
/// over the default location — the order Codewhale applies them.
pub(crate) fn codewhale_mcp_config_path(config_path: &Path) -> Option<PathBuf> {
    env_path("DEEPSEEK_MCP_CONFIG")
        .or_else(|| configured_mcp_config_path(config_path))
        .or_else(|| codewhale_dirs().map(|dirs| resolve_state_file(&dirs, "mcp.json")))
}

fn configured_mcp_config_path(config_path: &Path) -> Option<PathBuf> {
    let raw = fs::read_to_string(config_path).ok()?;
    let value = toml::from_str::<toml::Value>(&raw).ok()?;
    let configured = value.get("mcp_config_path")?.as_str()?.trim();
    if let Some(rest) = configured.strip_prefix("~/") {
        return Some(dirs::home_dir()?.join(rest));
    }
    let path = PathBuf::from(configured);
    path.is_absolute().then_some(path)
}

/// Codewhale serializes its own state-file edits on `<file>.lock`; holding
/// the same flock keeps a concurrent `codewhale mcp add` from interleaving.
/// The lock is released when the returned handle drops.
fn lock_state_file(path: &Path) -> Result<fs::File, String> {
    use std::os::fd::AsRawFd;
    let mut lock_name = path.as_os_str().to_owned();
    lock_name.push(".lock");
    let lock_path = PathBuf::from(lock_name);
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .map_err(|e| format!("open {}: {e}", lock_path.display()))?;
    // SAFETY: flock on a descriptor this function owns for the call's duration.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(format!(
            "lock {}: {}",
            lock_path.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok(file)
}

fn shell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
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

/// `sh -c` command for one event. A removed script (a deleted side-by-side
/// `UNPEEL_HOME`) exits 0 instead of failing every hook with status 127.
pub(crate) fn codewhale_hook_command(script_path: &Path, argument: &str) -> String {
    let script = shell_single_quoted(&script_path.to_string_lossy());
    format!("[ ! -x {script} ] || {script} {argument}")
}

pub(crate) fn codewhale_managed_hooks_block(script_path: &Path) -> String {
    let mut block = String::new();
    block.push_str(CODEWHALE_MANAGED_HOOKS_START);
    block.push('\n');
    for (event, argument) in CODEWHALE_HOOK_EVENTS {
        block.push_str("\n[[hooks.hooks]]\n");
        block.push_str(&format!(
            "name = {}\n",
            toml_basic_string(&format!("unpeel-{event}"))
        ));
        block.push_str(&format!("event = {}\n", toml_basic_string(event)));
        block.push_str(&format!(
            "command = {}\n",
            toml_basic_string(&codewhale_hook_command(script_path, argument))
        ));
        block.push_str("timeout_secs = 5\n");
    }
    block.push('\n');
    block.push_str(CODEWHALE_MANAGED_HOOKS_END);
    block
}

fn strip_marker_block(raw: &str) -> String {
    let mut updated = String::new();
    let mut skipping = false;
    for line in raw.split_inclusive('\n') {
        match line.trim() {
            CODEWHALE_MANAGED_HOOKS_START => skipping = true,
            CODEWHALE_MANAGED_HOOKS_END => skipping = false,
            _ if !skipping => updated.push_str(line),
            _ => {}
        }
    }
    updated
}

/// Drop `[[hooks.hooks]]` tables that start the Unpeel reporter but sit
/// outside the markers (a tool that rewrote the file may have dropped them).
fn strip_managed_hook_tables(raw: &str) -> String {
    fn flush(out: &mut String, segment: &mut String, is_hook: bool) {
        if !(is_hook && segment.contains(&format!("hooks/{CODEWHALE_HOOK_SCRIPT_NAME}"))) {
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
            segment_is_hook = trimmed == "[[hooks.hooks]]";
        }
        segment.push_str(line);
    }
    flush(&mut updated, &mut segment, segment_is_hook);
    updated
}

/// Replace Unpeel's hook entries in `raw` and return the new file. Errors —
/// never a rewrite — when the existing file is not valid TOML or its own
/// `hooks` shape cannot take appended `[[hooks.hooks]]` tables.
pub(crate) fn reconcile_codewhale_config(raw: &str, script_path: &Path) -> Result<String, String> {
    if !raw.trim().is_empty() {
        toml::from_str::<toml::Value>(raw)
            .map_err(|e| format!("Existing Codewhale config.toml is invalid: {e}"))?;
    }
    let without_markers = strip_marker_block(raw);
    let without_old_hooks = strip_managed_hook_tables(&without_markers);
    let mut updated = without_old_hooks.trim_end().to_string();
    if !updated.is_empty() {
        updated.push_str("\n\n");
    }
    updated.push_str(&codewhale_managed_hooks_block(script_path));
    updated.push('\n');
    toml::from_str::<toml::Value>(&updated).map_err(|e| {
        format!("Codewhale config.toml defines hooks in a shape Unpeel cannot extend: {e}")
    })?;
    Ok(updated)
}

pub(crate) fn ensure_codewhale_hooks_at(
    config_path: &Path,
    script_path: &Path,
) -> Result<(), String> {
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "Failed to create Codewhale config dir {}: {e}",
                parent.display()
            )
        })?;
    }
    let _lock = lock_state_file(config_path)?;
    let raw = match fs::read_to_string(config_path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("Failed to read Codewhale config.toml: {error}")),
    };
    let updated = reconcile_codewhale_config(&raw, script_path)?;
    if updated != raw {
        write_file_atomic(config_path, &updated, "Codewhale config.toml")?;
    }
    Ok(())
}

pub(crate) fn codewhale_managed_mcp_entry(shim: &Path) -> Value {
    json!({
        "command": shim.to_string_lossy(),
        "args": [],
        "env": {},
    })
}

fn entry_is_managed(value: &Value) -> bool {
    value
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(crate::integrations::install::is_mcp_shim_command)
}

/// Upsert the managed `unpeel` server into Codewhale's MCP config object.
/// Servers go under `servers`, or the `mcpServers` compatibility key when the
/// file only uses that one. A user-authored `unpeel` entry is left alone and
/// Unpeel's goes to `unpeel-unpeel` instead.
pub(crate) fn merge_codewhale_mcp_config(config: &mut Value, shim: &Path) -> Result<(), String> {
    let root = config
        .as_object_mut()
        .ok_or("Codewhale mcp.json is not a JSON object")?;
    let key = if !root.contains_key("servers") && root.contains_key("mcpServers") {
        "mcpServers"
    } else {
        "servers"
    };
    let servers = root
        .entry(key)
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| format!("Codewhale mcp.json `{key}` is not an object"))?;
    let name = match servers.get("unpeel") {
        Some(existing) if !entry_is_managed(existing) => "unpeel-unpeel",
        _ => "unpeel",
    };
    if servers.get(name).is_none_or(entry_is_managed) {
        servers.insert(name.to_string(), codewhale_managed_mcp_entry(shim));
    }
    Ok(())
}

pub(crate) fn write_codewhale_mcp_config_at(path: &Path, shim: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            format!(
                "Failed to create Codewhale MCP config dir {}: {e}",
                parent.display()
            )
        })?;
    }
    let _lock = lock_state_file(path)?;
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("Failed to read Codewhale mcp.json: {error}")),
    };
    let mut config = if raw.trim().is_empty() {
        json!({})
    } else {
        // Never replace malformed user configuration.
        serde_json::from_str::<Value>(&raw)
            .map_err(|e| format!("Existing Codewhale mcp.json is invalid: {e}"))?
    };
    merge_codewhale_mcp_config(&mut config, shim)?;
    let serialized = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Failed to serialize Codewhale mcp.json: {e}"))?;
    let updated = format!("{serialized}\n");
    if updated != raw {
        write_file_atomic(path, &updated, "Codewhale mcp.json")?;
    }
    Ok(())
}
