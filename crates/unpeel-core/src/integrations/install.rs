//! Explicit, user-initiated installation of a runtime's Unpeel integration.
//!
//! An integration is everything provider-specific Unpeel needs in the
//! provider's own global configuration: the lifecycle hook registration that
//! makes busy/idle/attention reliable, and the persistent registration of the
//! unified `unpeel` MCP server. It is installed once, by the user, per Host
//! (`unpeel integrations install <runtime>`, or the `integrations.install`
//! Host verb behind Install integration on Settings ▸ Agents). Launching a preset or
//! observing a hand-typed agent never installs anything.
//!
//! What Unpeel keeps doing on its own is keeping an installed integration
//! current: a marker under `<machine home>/integrations/` records which Host
//! build installed it, and the workspace worker re-runs the (idempotent,
//! content-guarded) installer after an upgrade so hook scripts and the MCP
//! shim keep pointing at the running binary.
//!
//! The integration is a per-user fact, because the provider configs it edits
//! are per user: every local workspace of one account shares one set of
//! markers, hook scripts, and one shim under `app_paths::machine_home()`
//! (the machine's `~/.unpeel` whenever `UNPEEL_HOME` is a workspace in the
//! machine's registry, the isolated home itself otherwise — a blank
//! instance or a test is never registered). Installing from any local
//! workspace installs for all of them; a remote Host has its own machine
//! home.

use crate::app_paths::machine_home;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Name of the stable launcher every provider's MCP configuration points at.
/// The shim survives Host upgrades and dev/release swaps: it prefers the
/// `UNPEEL_HOST_BIN` the hosted shell exports and falls back to the binary
/// recorded at install time for launchers that strip the environment from
/// their MCP children.
pub const MCP_SHIM_NAME: &str = "unpeel-mcp";

const MARKER_SCHEMA: u8 = 1;

/// `<machine home>/bin/unpeel-mcp`.
pub fn mcp_shim_path() -> PathBuf {
    mcp_shim_path_in(&machine_home())
}

pub fn mcp_shim_path_in(home: &Path) -> PathBuf {
    home.join("bin").join(MCP_SHIM_NAME)
}

/// The shim's contents for a Host binary at `host_bin`.
pub fn mcp_shim_script(host_bin: &str) -> String {
    format!(
        "#!/bin/sh\n\
         # Managed by Unpeel. Starts the unified `unpeel` MCP server for the agent\n\
         # running inside an Unpeel session; outside one it serves no tools.\n\
         exec \"${{UNPEEL_HOST_BIN:-{host_bin}}}\" {gate} {kind}\n",
        host_bin = shell_double_quote_safe(host_bin),
        gate = crate::mcp_gate::MCP_GATE_ARG,
        kind = crate::mcp_gate::UNIFIED_KIND,
    )
}

/// Whether a provider config's `command` is the Unpeel MCP shim (any home).
pub fn is_mcp_shim_command(command: &str) -> bool {
    std::path::Path::new(command.trim())
        .file_name()
        .and_then(|name| name.to_str())
        == Some(MCP_SHIM_NAME)
}

fn shell_double_quote_safe(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
        .replace('`', "\\`")
}

/// The Host binary an installer records: `unpeel-host` itself when the
/// installer runs inside it (the worker's post-upgrade refresh), otherwise
/// the `unpeel-host` shipped next to the running `unpeel` CLI.
pub(crate) fn installing_host_binary() -> Result<PathBuf, String> {
    let path = crate::session_ops::resolve_host_binary()?;
    if path.is_absolute() {
        return Ok(path);
    }
    // Only a bare `unpeel-host` name means nothing was found beside this
    // executable; keep the running binary rather than a PATH lookup that
    // may resolve to a stale install.
    crate::session_host::resolve_current_executable()
}

/// Build identity of the Host binary an installer records, in the same
/// shape the worker reports for itself, so `current` compares like with
/// like whether the installer ran from the CLI or the worker.
fn installing_host_build_id() -> Option<String> {
    installing_host_binary()
        .ok()
        .and_then(|path| crate::session_host::host_build_id_for(&path))
        .or_else(crate::session_host::current_host_build_id)
}

/// Write (or refresh) the MCP shim for the Host binary and return its path.
/// Every integration installer calls this before registering the shim with
/// its provider, so the shim is only ever as old as the newest installed
/// integration.
pub fn write_mcp_shim() -> Result<PathBuf, String> {
    let host = installing_host_binary()?;
    let path = mcp_shim_path();
    crate::hook_assets::write_executable_script(
        &path,
        &mcp_shim_script(&host.to_string_lossy()),
        "Unpeel MCP shim",
    )?;
    Ok(path)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Marker {
    schema: u8,
    /// `session_host::current_host_build_id` of the installing Host.
    #[serde(default)]
    host_build_id: Option<String>,
    #[serde(default)]
    host_version: String,
    #[serde(default)]
    installed_at_ms: u64,
    /// Set when the marker was minted from a pre-0.7 launch-time install
    /// (see `adopt_legacy_installs`) rather than by the user's verb.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    adopted_from: Option<String>,
}

fn markers_dir_in(home: &Path) -> PathBuf {
    home.join("integrations")
}

fn marker_path_in(home: &Path, legacy_slug: &str) -> PathBuf {
    markers_dir_in(home).join(format!("{legacy_slug}.json"))
}

fn read_marker(path: &Path) -> Option<Marker> {
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str::<Marker>(&raw).ok()
}

/// One row of `unpeel integrations list` and of bootstrap's
/// `availableAgents[].integration*` fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IntegrationStatus {
    /// Stable catalog id (`com.anthropic.claude-code`).
    pub id: String,
    /// The install verb's spelling (`claude`).
    pub runtime: String,
    pub label: String,
    /// The runtime ships an installer at all. Detection-only runtimes (Pi)
    /// have nothing to install.
    pub installable: bool,
    /// The user installed the integration on this Host.
    pub installed: bool,
    /// The installed copy was written by this Host build. `false` means the
    /// worker will refresh it (or already is).
    pub current: bool,
    /// What the integration provides, from the runtime descriptor.
    pub lifecycle_hooks: bool,
    pub mcp: bool,
}

fn status_for(
    home: &Path,
    runtime: &crate::runtime_catalog::RuntimeDescriptor,
) -> IntegrationStatus {
    let installable = super::has_integration_installer(&runtime.legacy_slug);
    let marker = read_marker(&marker_path_in(home, &runtime.legacy_slug));
    let installed = installable && marker.is_some();
    let current = installed
        && marker
            .as_ref()
            .and_then(|marker| marker.host_build_id.clone())
            .is_some_and(|recorded| {
                installing_host_build_id().as_deref() == Some(recorded.as_str())
            });
    IntegrationStatus {
        id: runtime.id.clone(),
        runtime: runtime.legacy_slug.clone(),
        label: runtime.label.clone(),
        installable,
        installed,
        current,
        lifecycle_hooks: runtime.lifecycle.uses_hook_port(),
        mcp: runtime.capabilities.iter().any(|capability| {
            matches!(
                capability,
                crate::runtime_catalog::RuntimeCapability::McpSessions
                    | crate::runtime_catalog::RuntimeCapability::McpBrowser
            )
        }),
    }
}

/// Whether the user installed `tool`'s integration on this Host. `tool` is
/// a legacy slug, catalog id, or command; unknown runtimes are never
/// installed.
pub fn is_installed(tool: &str) -> bool {
    is_installed_in(&machine_home(), tool)
}

pub fn is_installed_in(home: &Path, tool: &str) -> bool {
    super::runtime_for_dispatch(tool).is_some_and(|runtime| status_for(home, runtime).installed)
}

/// Status of one runtime's integration, or `None` for an unknown runtime.
pub fn status(tool: &str) -> Option<IntegrationStatus> {
    status_in(&machine_home(), tool)
}

pub fn status_in(home: &Path, tool: &str) -> Option<IntegrationStatus> {
    super::runtime_for_dispatch(tool).map(|runtime| status_for(home, runtime))
}

/// Every agent runtime on this platform, in catalog order.
pub fn list() -> Vec<IntegrationStatus> {
    list_in(&machine_home())
}

pub fn list_in(home: &Path) -> Vec<IntegrationStatus> {
    let mut runtimes = crate::runtime_catalog::builtin_runtime_catalog()
        .current_platform_descriptors()
        .filter(|runtime| runtime.display.kind == crate::runtime_catalog::RuntimeKind::Agent)
        .collect::<Vec<_>>();
    runtimes.sort_by(|left, right| {
        left.legacy_order
            .unwrap_or(u16::MAX)
            .cmp(&right.legacy_order.unwrap_or(u16::MAX))
            .then_with(|| left.slug.cmp(&right.slug))
    });
    runtimes
        .into_iter()
        .map(|runtime| status_for(home, runtime))
        .collect()
}

/// Install (or refresh) `tool`'s integration and record the marker.
pub fn install(tool: &str) -> Result<IntegrationStatus, String> {
    install_in(&machine_home(), tool)
}

pub fn install_in(home: &Path, tool: &str) -> Result<IntegrationStatus, String> {
    let runtime =
        super::runtime_for_dispatch(tool).ok_or_else(|| format!("unknown runtime '{tool}'"))?;
    if !super::has_integration_installer(&runtime.legacy_slug) {
        return Err(format!(
            "{} has no Unpeel integration to install: it is recognized by detection only",
            runtime.label
        ));
    }
    super::run_integration_installer(&runtime.legacy_slug)?;
    let marker = Marker {
        schema: MARKER_SCHEMA,
        host_build_id: installing_host_build_id(),
        host_version: env!("CARGO_PKG_VERSION").to_string(),
        installed_at_ms: now_ms(),
        adopted_from: None,
    };
    write_marker(home, &runtime.legacy_slug, &marker)?;
    Ok(status_for(home, runtime))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default()
}

fn write_marker(home: &Path, legacy_slug: &str, marker: &Marker) -> Result<(), String> {
    let path = marker_path_in(home, legacy_slug);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Failed to create {}: {error}", parent.display()))?;
    }
    let serialized = serde_json::to_string_pretty(marker)
        .map_err(|error| format!("Failed to serialize integration marker: {error}"))?;
    crate::hook_assets::write_file_atomic(&path, &format!("{serialized}\n"), "integration marker")
}

/// Upgrade path from the launch-time installs of 0.6 and earlier: a runtime
/// whose hooks Unpeel demonstrably installed on this machine (its
/// descriptor's `integration.legacy_evidence` files exist under the machine
/// home) but which has no marker yet is adopted as an installed integration.
/// The marker carries no build id, so `refresh_installed` re-runs that
/// runtime's installer next — which is what registers the MCP shim the old
/// per-launch injection used to supply. Only ever touches provider
/// configuration Unpeel already edited; a runtime with no evidence stays
/// "not installed" until the user asks. Returns the adopted runtimes.
pub fn adopt_legacy_installs() -> Vec<String> {
    adopt_legacy_installs_in(&machine_home())
}

pub fn adopt_legacy_installs_in(home: &Path) -> Vec<String> {
    let mut adopted = Vec::new();
    for runtime in crate::runtime_catalog::builtin_runtime_catalog().current_platform_descriptors()
    {
        if !super::has_integration_installer(&runtime.legacy_slug)
            || marker_path_in(home, &runtime.legacy_slug).exists()
        {
            continue;
        }
        let Some(integration) = &runtime.integration else {
            continue;
        };
        let evidence = integration
            .legacy_evidence
            .iter()
            .find(|relative| home.join(relative).exists());
        let Some(evidence) = evidence else { continue };
        let marker = Marker {
            schema: MARKER_SCHEMA,
            host_build_id: None,
            host_version: String::new(),
            installed_at_ms: now_ms(),
            adopted_from: Some(format!("pre-0.7 launch-time install ({evidence})")),
        };
        if write_marker(home, &runtime.legacy_slug, &marker).is_ok() {
            adopted.push(runtime.legacy_slug.clone());
        }
    }
    adopted
}

/// Re-run the installer of every integration the user installed with a
/// different Host build, so provider configs keep pointing at current
/// assets after an upgrade. Never installs anything new. Returns one result
/// per refreshed runtime.
pub fn refresh_installed() -> Vec<(String, Result<(), String>)> {
    refresh_installed_in(&machine_home())
}

pub fn refresh_installed_in(home: &Path) -> Vec<(String, Result<(), String>)> {
    list_in(home)
        .into_iter()
        .filter(|status| status.installed && !status.current)
        .map(|status| {
            let result = install_in(home, &status.runtime).map(|_| ());
            (status.runtime, result)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(tag: &str) -> PathBuf {
        let dir = PathBuf::from(format!("/tmp/upi-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_pre_0_7_hook_install_is_adopted_and_marked_for_refresh() {
        let home = temp_home("adopt");
        fs::create_dir_all(home.join("hooks")).unwrap();
        fs::write(home.join("hooks").join("claude-hooks.sh"), "#!/bin/sh\n").unwrap();
        let adopted = adopt_legacy_installs_in(&home);
        assert_eq!(adopted, vec!["claude".to_string()]);
        let claude = status_in(&home, "claude").unwrap();
        assert!(claude.installed, "adopted install counts as installed");
        assert!(
            !claude.current,
            "adopted install is stale so the worker refreshes it"
        );
        let marker = read_marker(&marker_path_in(&home, "claude")).unwrap();
        assert!(marker
            .adopted_from
            .as_deref()
            .unwrap_or("")
            .contains("claude-hooks.sh"));
        // Runtimes without evidence stay untouched, and a second pass is a no-op.
        assert!(!status_in(&home, "codex").unwrap().installed);
        assert!(adopt_legacy_installs_in(&home).is_empty());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn adoption_never_overwrites_an_existing_marker() {
        let home = temp_home("adopt-keep");
        fs::create_dir_all(home.join("hooks")).unwrap();
        fs::write(home.join("hooks").join("gemini-hook.sh"), "#!/bin/sh\n").unwrap();
        let existing = Marker {
            schema: MARKER_SCHEMA,
            host_build_id: Some("build-x".into()),
            host_version: "0.7.0".into(),
            installed_at_ms: 42,
            adopted_from: None,
        };
        write_marker(&home, "gemini", &existing).unwrap();
        assert!(adopt_legacy_installs_in(&home).is_empty());
        let marker = read_marker(&marker_path_in(&home, "gemini")).unwrap();
        assert_eq!(marker.host_build_id.as_deref(), Some("build-x"));
        assert_eq!(marker.installed_at_ms, 42);
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn nothing_is_installed_in_a_fresh_home() {
        let home = temp_home("fresh");
        let rows = list_in(&home);
        assert!(rows.iter().any(|row| row.runtime == "claude"));
        assert!(rows.iter().all(|row| !row.installed && !row.current));
        let pi = rows.iter().find(|row| row.runtime == "pi").expect("pi row");
        assert!(!pi.installable && !pi.lifecycle_hooks && !pi.mcp);
        let claude = rows.iter().find(|row| row.runtime == "claude").unwrap();
        assert!(claude.installable && claude.lifecycle_hooks && claude.mcp);
        assert!(!is_installed_in(&home, "claude"));
        assert!(!is_installed_in(&home, "not-a-runtime"));
        assert!(status_in(&home, "not-a-runtime").is_none());
        assert!(refresh_installed_in(&home).is_empty());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn detection_only_runtimes_refuse_installation() {
        let home = temp_home("pi");
        let error = install_in(&home, "pi").unwrap_err();
        assert!(error.contains("detection only"), "{error}");
        assert!(install_in(&home, "not-a-runtime").is_err());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn markers_track_the_installing_build() {
        let home = temp_home("marker");
        let marker_path = marker_path_in(&home, "claude");
        fs::create_dir_all(marker_path.parent().unwrap()).unwrap();
        fs::write(
            &marker_path,
            serde_json::to_string(&Marker {
                schema: MARKER_SCHEMA,
                host_build_id: Some("older-build".into()),
                host_version: "0.0.1".into(),
                installed_at_ms: 1,
                adopted_from: None,
            })
            .unwrap(),
        )
        .unwrap();
        let status = status_in(&home, "com.anthropic.claude-code").unwrap();
        assert!(status.installed);
        assert!(!status.current, "a foreign build id is never current");
        assert!(is_installed_in(&home, "claude"));
        assert!(is_installed_in(&home, "/opt/bin/claude --resume x"));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn shim_commands_are_recognized_by_basename() {
        assert!(is_mcp_shim_command("/home/me/.unpeel/bin/unpeel-mcp"));
        assert!(is_mcp_shim_command("/tmp/other-home/bin/unpeel-mcp"));
        assert!(!is_mcp_shim_command("/usr/local/bin/unpeel-host"));
        assert!(!is_mcp_shim_command("unpeel-mcp-other"));
    }

    #[test]
    fn shim_prefers_the_hosted_binary_and_falls_back_to_the_installer() {
        let script = mcp_shim_script("/Applications/Unpeel.app/Contents/MacOS/unpeel-host");
        assert!(script.starts_with("#!/bin/sh\n"));
        assert!(script.contains(
            "exec \"${UNPEEL_HOST_BIN:-/Applications/Unpeel.app/Contents/MacOS/unpeel-host}\" __mcp_gate__ unified"
        ));
        let quoted = mcp_shim_script("/tmp/odd \"dir\"/unpeel-host");
        assert!(quoted.contains("/tmp/odd \\\"dir\\\"/unpeel-host"));
    }
}
