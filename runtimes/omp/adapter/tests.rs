use super::setup::*;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

fn servers_of(path: &Path) -> serde_json::Map<String, Value> {
    let raw = fs::read_to_string(path).expect("read mcp config");
    let value: Value = serde_json::from_str(&raw).expect("parse mcp config");
    value["mcpServers"]
        .as_object()
        .expect("mcpServers object")
        .clone()
}

#[test]
fn lifecycle_extension_is_discovered_by_native_extension_loading() {
    let agent_dir = omp_agent_dir().expect("agent dir");
    assert_eq!(omp_mcp_config_path(), Some(agent_dir.join("mcp.json")));
    assert_eq!(
        omp_extension_path().and_then(|path| path.parent().map(Path::to_path_buf)),
        Some(agent_dir.join("extensions"))
    );
    assert_eq!(
        omp_extension_path()
            .and_then(|path| path.file_name().map(|name| name.to_string_lossy().into_owned())),
        Some(OMP_EXTENSION_FILE_NAME.to_string())
    );
}

/// The extension's identity checker as the shipped asset names it: a string
/// literal the installer replaces whole (#75, ADR 0013).
const CHECKER_LITERAL: &str = "const IDENTITY_CHECKER = \"{{UNPEEL_HOST_BIN}}\";";

#[test]
fn lifecycle_extension_names_its_identity_checker_once() {
    assert_eq!(OMP_LIFECYCLE_EXTENSION.matches(CHECKER_LITERAL).count(), 1);
    assert_eq!(
        OMP_LIFECYCLE_EXTENSION
            .matches(crate::hook_assets::REPORTER_HOST_BIN_PLACEHOLDER)
            .count(),
        1
    );
}

#[test]
fn installer_writes_the_lifecycle_extension_with_the_installing_host_as_its_checker() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("extensions").join(OMP_EXTENSION_FILE_NAME);
    install_lifecycle_extension_at(&path).expect("install extension");
    let installed = fs::read_to_string(&path).expect("read extension");
    let host = crate::integrations::install::installing_host_binary().expect("host binary");
    assert!(host.is_absolute(), "{}", host.display());
    let literal = serde_json::to_string(&host.to_string_lossy()).expect("JSON string");
    assert!(
        installed.contains(&format!("const IDENTITY_CHECKER = {literal};")),
        "the checker is the installing Host, as a string literal"
    );
    assert!(!installed.contains(crate::hook_assets::REPORTER_HOST_BIN_PLACEHOLDER));
    assert_eq!(
        installed.replacen(&literal, "\"{{UNPEEL_HOST_BIN}}\"", 1),
        OMP_LIFECYCLE_EXTENSION,
        "nothing else changes"
    );
    // Reinstalling keeps the same contents, so an upgraded host refreshes the
    // reporter without disturbing anything else in the agent directory.
    install_lifecycle_extension_at(&path).expect("reinstall extension");
    assert_eq!(fs::read_to_string(&path).expect("read extension"), installed);
}

#[test]
fn a_checker_path_is_written_as_a_javascript_string() {
    let module = crate::hook_assets::reporter_module_with(
        OMP_LIFECYCLE_EXTENSION,
        Some(Path::new("/Applications/Un\"peel\\ Dev.app/unpeel-host")),
    );
    assert!(module.contains(
        r#"const IDENTITY_CHECKER = "/Applications/Un\"peel\\ Dev.app/unpeel-host";"#
    ));
    // No resolvable Host leaves the check inert rather than half-filled.
    let module = crate::hook_assets::reporter_module_with(OMP_LIFECYCLE_EXTENSION, None);
    assert!(module.contains(r#"const IDENTITY_CHECKER = "";"#));
}

#[test]
fn mcp_config_gains_one_managed_entry_and_keeps_unrelated_servers() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("mcp.json");
    fs::write(
        &path,
        r#"{
  "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
  }
}
"#,
    )
    .expect("seed mcp config");

    write_omp_mcp_config_at(&path, "/home/me/.unpeel/bin/unpeel-mcp").expect("first install");
    let servers = servers_of(&path);
    assert_eq!(servers["context7"]["command"], "npx");
    assert_eq!(servers["unpeel"]["command"], "/home/me/.unpeel/bin/unpeel-mcp");
    assert_eq!(servers["unpeel"]["args"], json!([]));
    assert_eq!(servers["unpeel"]["type"], "stdio");
    assert!(servers["unpeel"].get("env").is_none());

    let first = fs::read_to_string(&path).expect("read after first install");
    write_omp_mcp_config_at(&path, "/home/me/.unpeel/bin/unpeel-mcp").expect("second install");
    assert_eq!(
        fs::read_to_string(&path).expect("read after second install"),
        first,
        "a repeated install must not rewrite an unchanged config"
    );
}

#[test]
fn a_users_own_unpeel_server_is_never_replaced() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("mcp.json");
    fs::write(
        &path,
        r#"{
  "mcpServers": {
    "unpeel": { "command": "/opt/team/team-mcp", "args": ["--local"] }
  }
}
"#,
    )
    .expect("seed mcp config");

    write_omp_mcp_config_at(&path, "/home/me/.unpeel/bin/unpeel-mcp").expect("install");
    let servers = servers_of(&path);
    assert_eq!(servers["unpeel"]["command"], "/opt/team/team-mcp");
    assert_eq!(servers["omp-unpeel"]["command"], "/home/me/.unpeel/bin/unpeel-mcp");
}

#[test]
fn malformed_mcp_config_is_left_alone() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("mcp.json");
    fs::write(&path, "{ not json").expect("seed malformed config");
    write_omp_mcp_config_at(&path, "/home/me/.unpeel/bin/unpeel-mcp").expect("install");
    assert_eq!(
        fs::read_to_string(&path).expect("read malformed config"),
        "{ not json"
    );
}
