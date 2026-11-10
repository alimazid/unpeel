use crate::hook_assets::{
    notify_hook_script_path, write_executable_script, write_file_atomic, NOTIFY_HOOK_SCRIPT,
};
use std::fs;
use std::path::PathBuf;

pub(crate) const OPENCODE_PLUGIN_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../runtimes/opencode/assets/hooks/plugin.js"
));

/// Install the Unpeel notify plugin into OpenCode's own global plugin
/// directory. OpenCode loads every `plugin/*.js` beneath its config dir, so
/// a hand-typed `opencode` reports through the plugin without any launch
/// environment. The plugin no-ops outside an Unpeel session.
pub fn install() -> Result<(), String> {
    let notify_path = notify_hook_script_path();
    write_executable_script(&notify_path, &crate::hook_assets::reporter_script(NOTIFY_HOOK_SCRIPT), "notify hook script")?;

    let plugin_dir = opencode_plugin_dir();
    fs::create_dir_all(&plugin_dir).map_err(|e| {
        format!(
            "Failed to create OpenCode plugin dir {}: {e}",
            plugin_dir.display()
        )
    })?;
    let plugin =
        OPENCODE_PLUGIN_SCRIPT.replace("{{NOTIFY_PATH}}", notify_path.to_string_lossy().as_ref());
    write_file_atomic(&opencode_plugin_path(), &plugin, "OpenCode plugin")?;
    Ok(())
}

/// OpenCode's global config dir: `$XDG_CONFIG_HOME/opencode`, default
/// `~/.config/opencode`.
pub fn opencode_config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME").filter(|value| !value.is_empty()) {
        return PathBuf::from(dir).join("opencode");
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config")
        .join("opencode")
}

pub(crate) fn opencode_plugin_dir() -> PathBuf {
    opencode_config_dir().join("plugin")
}

pub(crate) fn opencode_plugin_path() -> PathBuf {
    opencode_plugin_dir().join("unpeel-notify.js")
}
