use portable_pty::CommandBuilder;

pub mod install;
pub mod shared;

use crate::session_host::SessionHostLaunch;

/// Absolute path of the `unpeel-host` that hosts a session, exported to every
/// hosted child so Apps and scripts talk to the Host they run under.
pub const HOST_BIN_ENV: &str = "UNPEEL_HOST_BIN";
const APP_ACCENT_ENV: &str = "UNPEEL_APP_ACCENT";

#[derive(Clone, Copy)]
pub struct BuiltinPresetDefinition {
    pub id: &'static str,
    pub label: &'static str,
    pub command: &'static str,
    pub quick_launch: bool,
}

/// A built-in runtime's compiled adapter.
///
/// Launching is provider-neutral: a preset runs its command in the user's
/// own login shell exactly as typed, with only Unpeel's generic session
/// environment exported (see [`configure_host_command`]). Nothing here
/// rewrites the command, wraps the executable, or edits provider
/// configuration at launch. Provider-specific behavior is limited to the
/// explicitly installed integration ([`Integration::install`]) and the
/// resume recipe.
#[derive(Clone, Copy)]
pub struct Integration {
    /// Escape interrupts the foreground turn in this runtime. Opt in only
    /// from a documented provider contract; generic terminal input has no
    /// lifecycle authority.
    pub escape_cancels_turn: bool,
    /// Install this runtime's Unpeel integration — lifecycle hooks and the
    /// persistent registration of the unified `unpeel` MCP server — into the
    /// provider's own global configuration. Idempotent, locked, and
    /// content-guarded. It runs only when the user asks
    /// (`unpeel integrations install`, the `integrations.install` Host verb)
    /// or when the Host refreshes an integration the user already installed
    /// after an upgrade; never as a side effect of launching or observing
    /// an agent.
    pub install: Option<fn() -> Result<(), String>>,
    pub resume_adapter: Option<crate::resume::ResumeAdapter>,
}

impl Integration {
    pub const fn new(install: Option<fn() -> Result<(), String>>) -> Self {
        Self {
            escape_cancels_turn: false,
            install,
            resume_adapter: None,
        }
    }

    pub const fn with_escape_cancellation(mut self) -> Self {
        self.escape_cancels_turn = true;
        self
    }

    pub const fn with_resume_adapter(
        mut self,
        resume_adapter: crate::resume::ResumeAdapter,
    ) -> Self {
        self.resume_adapter = Some(resume_adapter);
        self
    }
}

include!(concat!(
    env!("OUT_DIR"),
    "/integration_adapters_generated.rs"
));

pub(crate) fn integration_for_id(tool: &str) -> Option<&'static Integration> {
    let normalized = tool.trim();
    INTEGRATIONS
        .iter()
        .find(|(legacy_slug, _)| legacy_slug.eq_ignore_ascii_case(normalized))
        .map(|(_, integration)| integration)
}

pub(crate) fn runtime_for_command(
    command: &str,
) -> Option<&'static crate::runtime_catalog::RuntimeDescriptor> {
    crate::runtime_catalog::builtin_runtime_catalog()
        .by_command_alias_for_current_platform(command_head(command))
}

pub(crate) fn integration_for_command(command: &str) -> Option<&'static Integration> {
    let runtime = runtime_for_command(command)?;
    integration_for_id(&runtime.legacy_slug)
}

pub(crate) fn runtime_for_dispatch(
    runtime_or_command: &str,
) -> Option<&'static crate::runtime_catalog::RuntimeDescriptor> {
    let catalog = crate::runtime_catalog::builtin_runtime_catalog();
    catalog
        .by_legacy_slug_for_current_platform(runtime_or_command)
        .or_else(|| {
            catalog
                .by_id(runtime_or_command)
                .filter(|runtime| runtime.supports_current_platform())
        })
        .or_else(|| runtime_for_command(runtime_or_command))
}

fn integration_for_dispatch(runtime_or_command: &str) -> Option<&'static Integration> {
    let runtime = runtime_for_dispatch(runtime_or_command)?;
    integration_for_id(&runtime.legacy_slug)
}

pub fn command_head(command: &str) -> &str {
    shared::command_head(command)
}

pub fn builtin_presets() -> &'static [BuiltinPresetDefinition] {
    BUILTIN_PRESETS
}

/// Whether a preset with this command may be starred for Quick Launch. A
/// catalog runtime answers with its descriptor flag (fx opts out); any other
/// non-empty command — an App or a plain custom command — may be starred
/// and becomes its own quick-launch chip (community #13). The empty
/// blank-terminal pseudo-preset never is; the sidebar strip draws that chip
/// itself.
pub fn preset_supports_quick_launch(command: &str) -> bool {
    match runtime_for_command(command) {
        Some(runtime) => runtime.supports_quick_launch,
        None => !command.trim().is_empty(),
    }
}

pub fn uses_hook_port(tool: &str) -> bool {
    runtime_for_dispatch(tool)
        .map(|runtime| runtime.lifecycle.uses_hook_port())
        .unwrap_or(false)
}

/// Whether `tool` (a legacy slug, catalog id, or command) names a runtime
/// with an installable Unpeel integration.
pub fn has_integration_installer(tool: &str) -> bool {
    integration_for_dispatch(tool).is_some_and(|integration| integration.install.is_some())
}

/// Run the runtime's integration installer. Callers are the explicit install
/// surfaces and the post-upgrade refresh in [`install`]; the launch path
/// never calls this.
pub(crate) fn run_integration_installer(tool: &str) -> Result<(), String> {
    match integration_for_dispatch(tool).and_then(|integration| integration.install) {
        Some(installer) => installer(),
        None => Err(format!("{tool} has no Unpeel integration to install")),
    }
}

/// Export Unpeel's generic session environment into a hosted PTY. This is
/// the whole of what a launch adds on top of the user's login shell: the
/// session identity hook scripts and the MCP server read, the Host binary,
/// the installed-Apps bin, the workspace accent, and the hook port.
/// Provider-specific variables never appear here.
pub fn configure_host_command(
    launch: &SessionHostLaunch,
    cmd: &mut CommandBuilder,
    shell_prelude: &mut Vec<String>,
) -> Result<(), String> {
    // The unified MCP host uses this identity for every domain. These paths
    // must also be explicit for hookless headless/CLI launches: otherwise an
    // isolated `UNPEEL_HOME` can fall back to the user's default ~/.unpeel.
    let session_dir = crate::app_paths::app_sessions_root().join(&launch.session.id);
    let session_dir_value = session_dir.to_string_lossy().to_string();
    let home = crate::app_paths::unpeel_home();
    let registry_value = home.join("app-ports").to_string_lossy().to_string();
    let trace_value = home
        .join("hooks")
        .join("trace.log")
        .to_string_lossy()
        .to_string();
    cmd.env("UNPEEL_SESSION_ID", &launch.session.id);
    cmd.env("UNPEEL_SESSION_DIR", &session_dir_value);
    cmd.env("UNPEEL_APP_PORT_REGISTRY_FILE", &registry_value);
    cmd.env("UNPEEL_HOOK_TRACE_FILE", &trace_value);
    shell_prelude.push(format!(
        "export UNPEEL_SESSION_ID={} UNPEEL_SESSION_DIR={} UNPEEL_APP_PORT_REGISTRY_FILE={} UNPEEL_HOOK_TRACE_FILE={}",
        shared::shell_quote(&launch.session.id),
        shared::shell_quote(&session_dir_value),
        shared::shell_quote(&registry_value),
        shared::shell_quote(&trace_value),
    ));

    // Installed Unpeel Apps live in the Host's own `apps/bin`, which no
    // shell startup file knows about. Put it first in PATH — on the child
    // process for blank terminals (rc files may reorder it but keep it) and
    // through the prelude for command launches (which run after rc files) —
    // so an App launched by name from the launch list, a script, or an agent
    // resolves. The directory holds only App binaries, so it shadows nothing.
    let apps_bin = crate::app_installer::install_dir(&home)
        .to_string_lossy()
        .to_string();
    let inherited_path = cmd
        .get_env("PATH")
        .map(|value| value.to_string_lossy().to_string())
        .or_else(|| std::env::var("PATH").ok())
        .unwrap_or_default();
    let child_path = if inherited_path.split(':').any(|dir| dir == apps_bin) {
        inherited_path
    } else if inherited_path.is_empty() {
        apps_bin.clone()
    } else {
        format!("{apps_bin}:{inherited_path}")
    };
    cmd.env("PATH", &child_path);
    shell_prelude.push(format!(
        "export PATH={}:\"$PATH\"",
        shared::shell_quote(&apps_bin),
    ));

    // Every hosted child must reach THIS Host's own binary — never whatever
    // `unpeel-host` happens to sit on the user's PATH (a stale CLI install
    // there answers with an older protocol). Unpeel Apps use it to spawn the
    // unified MCP server for peer discovery and agent handoff, and the
    // installed MCP shim (`integrations::install::mcp_shim_path`) prefers it
    // over the path recorded at install time.
    if let Ok(host_bin) = crate::session_host::resolve_current_executable() {
        let host_bin = host_bin.to_string_lossy().to_string();
        cmd.env(HOST_BIN_ENV, &host_bin);
        shell_prelude.push(format!(
            "export {HOST_BIN_ENV}={}",
            shared::shell_quote(&host_bin),
        ));
    }

    // Frontends resolve the most local applicable color before launch:
    // project folder first, then workspace. Keep this an explicit hosted
    // environment value and clear any inherited parent-session accent when
    // the launch has none, so standalone/default styling remains honest.
    if let Some(accent) = launch.app_accent.as_deref().and_then(normalize_app_accent) {
        cmd.env(APP_ACCENT_ENV, &accent);
        shell_prelude.push(format!(
            "export {APP_ACCENT_ENV}={}",
            shared::shell_quote(&accent),
        ));
    } else {
        cmd.env_remove(APP_ACCENT_ENV);
        shell_prelude.push(format!("unset {APP_ACCENT_ENV}"));
    }

    export_schedule_run(launch, cmd, shell_prelude);

    if let Some(port) = launch.hook_port {
        let port_value = port.to_string();
        // Hook scripts persist the last lifecycle event into the session dir
        // (last-hook-event.json) so a restarted app can re-seed busy/attention
        // state. The shared paths above keep that state workspace-isolated.
        cmd.env("UNPEEL_APP_PORT", &port_value);
        shell_prelude.push(format!(
            "export UNPEEL_APP_PORT={}",
            shared::shell_quote(&port_value),
        ));
    } else {
        // `unpeel create` can itself run inside another hosted Session. Never
        // let the nested child inherit its parent's hook endpoint.
        cmd.env_remove("UNPEEL_APP_PORT");
        shell_prelude.push("unset UNPEEL_APP_PORT".to_string());
    }

    Ok(())
}

/// A Run Session names its Scheduled Task and Run; any other Session clears
/// both, so a Session started from inside a Run never claims to be one.
fn export_schedule_run(
    launch: &SessionHostLaunch,
    cmd: &mut CommandBuilder,
    shell_prelude: &mut Vec<String>,
) {
    use crate::schedules::{SCHEDULE_ID_ENV, SCHEDULE_RUN_ID_ENV};
    match &launch.schedule_run {
        Some(run) => {
            cmd.env(SCHEDULE_ID_ENV, &run.schedule_id);
            cmd.env(SCHEDULE_RUN_ID_ENV, &run.run_id);
            shell_prelude.push(format!(
                "export {SCHEDULE_ID_ENV}={} {SCHEDULE_RUN_ID_ENV}={}",
                shared::shell_quote(&run.schedule_id),
                shared::shell_quote(&run.run_id),
            ));
        }
        None => {
            cmd.env_remove(SCHEDULE_ID_ENV);
            cmd.env_remove(SCHEDULE_RUN_ID_ENV);
            shell_prelude.push(format!("unset {SCHEDULE_ID_ENV} {SCHEDULE_RUN_ID_ENV}"));
        }
    }
}

fn normalize_app_accent(value: &str) -> Option<String> {
    let value = value.trim();
    let digits = value.strip_prefix('#').unwrap_or(value);
    if digits.len() != 6 || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("#{}", digits.to_ascii_uppercase()))
}

/// Evidence that the agent this Session launches can actually reach the
/// unified `unpeel` MCP server: the runtime declares the domain, the user has
/// installed its Unpeel integration on this Host, and the launch grants the
/// domain. Domain authorization is recorded independently on the Session
/// manifest; this is only setup evidence, so clients never mistake a launch
/// grant for a configured provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct McpRegistrationEvidence {
    pub sessions: bool,
    pub browser: bool,
}

pub fn mcp_registration_evidence(
    tool: &str,
    mcp_enabled: bool,
    browser_mcp_enabled: bool,
) -> McpRegistrationEvidence {
    mcp_registration_evidence_in(
        &crate::app_paths::unpeel_home(),
        tool,
        mcp_enabled,
        browser_mcp_enabled,
    )
}

pub fn mcp_registration_evidence_in(
    home: &std::path::Path,
    tool: &str,
    mcp_enabled: bool,
    browser_mcp_enabled: bool,
) -> McpRegistrationEvidence {
    if !(mcp_enabled || browser_mcp_enabled) {
        return McpRegistrationEvidence::default();
    }
    let Some(runtime) = runtime_for_dispatch(tool) else {
        return McpRegistrationEvidence::default();
    };
    if !install::is_installed_in(home, &runtime.legacy_slug) {
        return McpRegistrationEvidence::default();
    }
    let supports = |capability| runtime.capabilities.contains(&capability);
    McpRegistrationEvidence {
        sessions: mcp_enabled && supports(crate::runtime_catalog::RuntimeCapability::McpSessions),
        browser: browser_mcp_enabled
            && supports(crate::runtime_catalog::RuntimeCapability::McpBrowser),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_commands_can_be_quick_launched_but_a_blank_terminal_cannot() {
        assert!(preset_supports_quick_launch("my-tool --serve"));
        assert!(preset_supports_quick_launch("./scripts/dev.sh"));
        assert!(!preset_supports_quick_launch(""));
        assert!(!preset_supports_quick_launch("   "));
        assert!(preset_supports_quick_launch("claude"));
    }

    #[test]
    fn runtime_catalog_generated_registry_preserves_legacy_order_and_metadata() {
        let catalog = crate::runtime_catalog::builtin_runtime_catalog();
        let slugs = INTEGRATIONS
            .iter()
            .map(|(slug, _)| *slug)
            .collect::<Vec<_>>();
        let mut catalog_adapters = catalog
            .current_platform_descriptors()
            .filter(|runtime| {
                runtime
                    .adapter
                    .as_deref()
                    .is_some_and(|adapter| adapter.starts_with("builtin:"))
            })
            .collect::<Vec<_>>();
        catalog_adapters.sort_by_key(|runtime| runtime.legacy_order);
        assert_eq!(
            catalog_adapters
                .iter()
                .map(|runtime| runtime.legacy_slug.as_str())
                .collect::<Vec<_>>(),
            slugs,
            "every built-in descriptor must produce exactly one integration entry"
        );

        let mut catalog_preset_runtimes =
            catalog.current_platform_descriptors().collect::<Vec<_>>();
        catalog_preset_runtimes.sort_by(|left, right| {
            left.legacy_order
                .unwrap_or(u16::MAX)
                .cmp(&right.legacy_order.unwrap_or(u16::MAX))
                .then_with(|| left.slug.cmp(&right.slug))
                .then_with(|| left.id.cmp(&right.id))
        });
        let catalog_presets = catalog_preset_runtimes
            .iter()
            .flat_map(|runtime| runtime.suggested_presets.iter())
            .collect::<Vec<_>>();
        assert_eq!(catalog_presets.len(), BUILTIN_PRESETS.len());
        assert_eq!(catalog_presets.len(), BUILTIN_PRESET_IDS.len());
        for (catalog_preset, generated_preset) in catalog_presets.into_iter().zip(BUILTIN_PRESETS) {
            assert_eq!(catalog_preset.id, generated_preset.id);
            assert_eq!(catalog_preset.label, generated_preset.label);
            assert_eq!(catalog_preset.command, generated_preset.command);
            assert_eq!(catalog_preset.quick_launch, generated_preset.quick_launch);
        }
        for (preset_id, generated_preset) in BUILTIN_PRESET_IDS.iter().zip(BUILTIN_PRESETS) {
            assert_eq!(*preset_id, generated_preset.id);
        }

        for (legacy_slug, _) in INTEGRATIONS {
            let runtime = catalog
                .by_legacy_slug(legacy_slug)
                .unwrap_or_else(|| panic!("catalog missing {legacy_slug}"));
            assert!(runtime.supports_current_platform());
            assert_eq!(
                uses_hook_port(legacy_slug),
                runtime.lifecycle.uses_hook_port()
            );
            assert_eq!(
                preset_supports_quick_launch(legacy_slug),
                runtime.supports_quick_launch
            );

            let integration = integration_for_id(legacy_slug).expect("generated integration");
            assert_eq!(
                has_integration_installer(legacy_slug),
                integration.install.is_some(),
                "{legacy_slug}: installer dispatch must follow the adapter callback"
            );
            let declares_mcp = runtime.capabilities.iter().any(|capability| {
                matches!(
                    capability,
                    crate::runtime_catalog::RuntimeCapability::McpSessions
                        | crate::runtime_catalog::RuntimeCapability::McpBrowser
                        | crate::runtime_catalog::RuntimeCapability::McpComputer
                )
            });
            if declares_mcp || runtime.lifecycle.uses_hook_port() {
                assert!(
                    integration.install.is_some(),
                    "{legacy_slug}: hooks or MCP capabilities need an installer"
                );
            }
            // Catalog ids dispatch like legacy slugs, so every install
            // surface can accept either spelling.
            assert!(std::ptr::eq(
                integration_for_dispatch(&runtime.id).expect("id dispatch"),
                integration
            ));
        }
    }

    #[test]
    fn command_dispatch_normalizes_absolute_paths_and_every_declared_alias() {
        let catalog = crate::runtime_catalog::builtin_runtime_catalog();
        for runtime in catalog
            .current_platform_descriptors()
            .filter(|runtime| runtime.adapter.is_some())
        {
            let expected = integration_for_id(&runtime.legacy_slug).expect("generated integration");
            for alias in &runtime.detection.command_aliases {
                for command in [
                    alias.clone(),
                    format!("/opt/unpeel/bin/{alias} --test-flag"),
                    format!("UNPEEL_TEST_MODE=local {alias}"),
                ] {
                    let actual = integration_for_command(&command)
                        .unwrap_or_else(|| panic!("missing dispatch for {command}"));
                    assert!(
                        std::ptr::eq(actual, expected),
                        "{command} did not dispatch through {}",
                        runtime.legacy_slug
                    );
                    assert_eq!(
                        runtime_for_command(&command).map(|value| value.id.as_str()),
                        Some(runtime.id.as_str())
                    );
                    assert_eq!(uses_hook_port(&command), runtime.lifecycle.uses_hook_port());
                    assert_eq!(
                        preset_supports_quick_launch(&command),
                        runtime.supports_quick_launch
                    );
                }
            }
        }

        assert!(integration_for_command("/opt/unpeel/bin/not-an-agent --flag").is_none());
        assert!(!has_integration_installer("/opt/unpeel/bin/not-an-agent"));
        assert!(run_integration_installer("/opt/unpeel/bin/not-an-agent").is_err());
    }

    /// The preset a runtime suggests names that runtime, including a preset
    /// that sets the provider's environment first (Cline's
    /// `CLINE_SESSION_BACKEND_MODE=local cline`, #79).
    #[test]
    fn every_suggested_preset_dispatches_to_its_own_runtime() {
        let catalog = crate::runtime_catalog::builtin_runtime_catalog();
        for runtime in catalog.current_platform_descriptors() {
            for preset in &runtime.suggested_presets {
                assert_eq!(
                    runtime_for_command(&preset.command).map(|value| value.id.as_str()),
                    Some(runtime.id.as_str()),
                    "{}",
                    preset.command
                );
            }
        }
        assert_eq!(
            runtime_for_command("CLINE_SESSION_BACKEND_MODE=local cline")
                .map(|value| value.legacy_slug.as_str()),
            Some("cline")
        );
        assert!(runtime_for_command("CLINE_SESSION_BACKEND_MODE=local").is_none());
    }

    /// A launch grant is never registration evidence on its own: the
    /// runtime must declare the domain and the user must have installed its
    /// integration on this Host (nothing is installed in a test home).
    #[test]
    fn registration_evidence_requires_an_installed_integration() {
        let home = std::path::PathBuf::from(format!("/tmp/upe-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        for tool in ["codex", "claude", "kiro-cli", "pi", "cat"] {
            assert_eq!(
                mcp_registration_evidence_in(&home, tool, true, true),
                McpRegistrationEvidence::default(),
                "{tool}"
            );
        }
        // Installed + declared + granted is the only true shape.
        std::fs::create_dir_all(home.join("integrations")).unwrap();
        std::fs::write(
            home.join("integrations").join("claude.json"),
            r#"{"schema":1,"host_build_id":"x","host_version":"0","installed_at_ms":1}"#,
        )
        .unwrap();
        assert_eq!(
            mcp_registration_evidence_in(&home, "claude", true, false),
            McpRegistrationEvidence {
                sessions: true,
                browser: false
            }
        );
        assert_eq!(
            mcp_registration_evidence_in(&home, "claude", false, false),
            McpRegistrationEvidence::default()
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    /// The hook env block must pin the registry/trace fallback paths to this
    /// instance's UNPEEL_HOME — otherwise a workspace instance's hook scripts
    /// broadcast against (and trace into) the real ~/.unpeel.
    #[test]
    fn hook_env_block_pins_registry_and_trace_to_unpeel_home() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "test-session",
                "project_id": "test-project",
                "label": "test",
                "command": "sh"
            },
            "cwd": "/tmp",
            "dark_mode": null,
            "hook_port": 4321
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        let mut prelude = Vec::new();
        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");
        let exports = prelude.join("\n");
        let home = crate::app_paths::unpeel_home();
        let registry = shared::shell_quote(&home.join("app-ports").to_string_lossy());
        let trace = shared::shell_quote(&home.join("hooks").join("trace.log").to_string_lossy());
        assert!(
            exports.contains(&format!("UNPEEL_APP_PORT_REGISTRY_FILE={registry}")),
            "registry path missing from prelude: {exports}"
        );
        assert!(
            exports.contains(&format!("UNPEEL_HOOK_TRACE_FILE={trace}")),
            "trace path missing from prelude: {exports}"
        );
    }

    #[test]
    fn hosted_app_accent_is_normalized_and_exported() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "accent-session",
                "project_id": "test-project",
                "label": "test",
                "command": "sh"
            },
            "cwd": "/tmp",
            "dark_mode": true,
            "app_accent": " 4ec3c9 "
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        let mut prelude = Vec::new();

        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");

        assert_eq!(
            cmd.get_env(APP_ACCENT_ENV),
            Some(std::ffi::OsStr::new("#4EC3C9"))
        );
        assert!(prelude
            .join("\n")
            .contains("export UNPEEL_APP_ACCENT='#4EC3C9'"));
    }

    #[test]
    fn hookless_launch_keeps_mcp_identity_and_workspace_paths_without_parent_port() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "headless-session",
                "project_id": "test-project",
                "label": "test",
                "command": "sh"
            },
            "cwd": "/tmp",
            "dark_mode": null
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        cmd.env("UNPEEL_APP_PORT", "9999");
        cmd.env(APP_ACCENT_ENV, "#D97757");
        let mut prelude = Vec::new();

        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");

        let session_dir = crate::app_paths::app_sessions_root().join("headless-session");
        let home = crate::app_paths::unpeel_home();
        assert_eq!(
            cmd.get_env("UNPEEL_SESSION_ID"),
            Some(std::ffi::OsStr::new("headless-session"))
        );
        assert_eq!(
            cmd.get_env("UNPEEL_SESSION_DIR"),
            Some(session_dir.as_os_str())
        );
        assert_eq!(
            cmd.get_env("UNPEEL_APP_PORT_REGISTRY_FILE"),
            Some(home.join("app-ports").as_os_str())
        );
        assert_eq!(
            cmd.get_env("UNPEEL_HOOK_TRACE_FILE"),
            Some(home.join("hooks").join("trace.log").as_os_str())
        );
        assert_eq!(cmd.get_env("UNPEEL_APP_PORT"), None);
        assert_eq!(cmd.get_env(APP_ACCENT_ENV), None);
        let host_bin = crate::session_host::resolve_current_executable().expect("current exe");
        assert_eq!(cmd.get_env(HOST_BIN_ENV), Some(host_bin.as_os_str()));
        let apps_bin = crate::app_installer::install_dir(&home)
            .to_string_lossy()
            .to_string();
        let child_path = cmd.get_env("PATH").unwrap().to_string_lossy().to_string();
        assert_eq!(child_path.split(':').next(), Some(apps_bin.as_str()));

        let exports = prelude.join("\n");
        assert!(exports.contains("UNPEEL_SESSION_ID='headless-session'"));
        assert!(exports.contains("UNPEEL_SESSION_DIR="));
        assert!(exports.contains("UNPEEL_APP_PORT_REGISTRY_FILE="));
        assert!(exports.contains("UNPEEL_HOOK_TRACE_FILE="));
        assert!(exports.contains("unset UNPEEL_APP_PORT"));
        assert!(exports.contains("unset UNPEEL_APP_ACCENT"));
        assert!(exports.contains(&format!(
            "export UNPEEL_HOST_BIN={}",
            shared::shell_quote(&host_bin.to_string_lossy())
        )));
        assert!(exports.contains(&format!(
            "export PATH={}:\"$PATH\"",
            shared::shell_quote(&apps_bin)
        )));
    }

    /// A Scheduled Task's Run Session learns its task and Run through the
    /// child environment and the prelude command launches see.
    #[test]
    fn a_run_session_exports_its_schedule_and_run() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "run-session",
                "project_id": "test-project",
                "label": "test",
                "command": "true"
            },
            "cwd": "/tmp",
            "dark_mode": null,
            "schedule_run": {"schedule_id": "sch_1", "run_id": "run_9"}
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        let mut prelude = Vec::new();
        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");
        assert_eq!(
            cmd.get_env(crate::schedules::SCHEDULE_ID_ENV),
            Some(std::ffi::OsStr::new("sch_1"))
        );
        assert_eq!(
            cmd.get_env(crate::schedules::SCHEDULE_RUN_ID_ENV),
            Some(std::ffi::OsStr::new("run_9"))
        );
        assert!(prelude
            .join("\n")
            .contains("export UNPEEL_SCHEDULE_ID='sch_1' UNPEEL_SCHEDULE_RUN_ID='run_9'"));
    }

    /// `unpeel new` from inside a Run Session must not inherit the Run.
    #[test]
    fn any_other_session_clears_an_inherited_schedule() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "nested-session",
                "project_id": "test-project",
                "label": "test",
                "command": "true"
            },
            "cwd": "/tmp",
            "dark_mode": null
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        cmd.env(crate::schedules::SCHEDULE_ID_ENV, "sch_parent");
        cmd.env(crate::schedules::SCHEDULE_RUN_ID_ENV, "run_parent");
        let mut prelude = Vec::new();
        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");
        assert_eq!(cmd.get_env(crate::schedules::SCHEDULE_ID_ENV), None);
        assert_eq!(cmd.get_env(crate::schedules::SCHEDULE_RUN_ID_ENV), None);
        assert!(prelude
            .join("\n")
            .contains("unset UNPEEL_SCHEDULE_ID UNPEEL_SCHEDULE_RUN_ID"));
    }

    /// A launched agent command reaches the PTY untouched: no provider
    /// variable, wrapper directory, or injected flag appears in what the
    /// login shell runs.
    #[test]
    fn launch_environment_carries_no_provider_specific_variables() {
        let launch: SessionHostLaunch = serde_json::from_value(serde_json::json!({
            "session": {
                "id": "plain-session",
                "project_id": "test-project",
                "label": "test",
                "command": "codex --dangerously-bypass-approvals-and-sandbox"
            },
            "cwd": "/tmp",
            "dark_mode": null,
            "hook_port": 4321,
            "mcp_enabled": true,
            "browser_mcp_enabled": true
        }))
        .expect("launch fixture");
        let mut cmd = CommandBuilder::new("true");
        let mut prelude = Vec::new();
        configure_host_command(&launch, &mut cmd, &mut prelude).expect("configure");
        let exports = prelude.join("\n");
        for forbidden in [
            "UNPEEL_MCP_BIN",
            "UNPEEL_REAL_CODEX_BIN",
            "UNPEEL_ORIGINAL_PATH",
            "hooks/bin",
            "UNPEEL_SESSIONS_MCP_ENABLED",
            "UNPEEL_KIRO_",
            "CLINE_",
            "MUSE_EXPERIMENTAL_PLUGINS",
            "OPENCODE_CONFIG_DIR",
            "GROK_",
        ] {
            assert!(
                !exports.contains(forbidden),
                "{forbidden} leaked: {exports}"
            );
            assert!(
                cmd.get_env(forbidden).is_none(),
                "{forbidden} set on the child"
            );
        }
    }
}
