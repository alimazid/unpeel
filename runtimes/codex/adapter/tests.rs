use crate::hook_assets::test_support::*;
use crate::hook_assets::*;
use crate::hook_assets::{
    kiro_mcp_server_value, AMP_PLUGIN_SCRIPT, CLAUDE_HOOK_SCRIPT, CLINE_HOOK_SCRIPT,
    CODEX_NOTIFY_NORMALIZER_SCRIPT, COPILOT_HOOK_SCRIPT, CURSOR_HOOK_SCRIPT,
    GEMINI_HOOK_SCRIPT, KIMI_HOOK_SCRIPT, KIRO_HOOK_SCRIPT, NOTIFY_HOOK_SCRIPT,
    OPENCODE_PLUGIN_SCRIPT,
};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn codex_notify_normalizer_maps_provider_events_before_generic_transport() {
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("agent-turn-complete"));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("task_complete"));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("turn_aborted"));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("request_permissions"));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("apply_patch_approval_request"));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("EVENT_TYPE=\"Stop\""));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("EVENT_TYPE=\"PermissionRequest\""));
    assert!(CODEX_NOTIFY_NORMALIZER_SCRIPT.contains("{{NOTIFY_PATH}}"));
    assert!(!NOTIFY_HOOK_SCRIPT.contains("agent-turn-complete"));
    assert!(NOTIFY_HOOK_SCRIPT.contains("UNPEEL_PORT_REGISTRY_FILE"));
    assert!(NOTIFY_HOOK_SCRIPT.contains("current_unpeel_ports"));
    assert!(NOTIFY_HOOK_SCRIPT.contains("post_hook_payload_to_current_ports"));
}

#[test]
fn notify_hook_script_preserves_codex_session_and_transcript_for_busy_events() {
    let capture = CaptureServer::start();
    let script = write_temp_codex_notify_hook("notify-busy");
    let payload = json!({
        "type": "task_started",
        "session_id": "codex-provider-session",
        "transcript_path": "/tmp/codex-provider-session.jsonl",
        "cwd": "/tmp/project"
    })
    .to_string();

    let output = Command::new("bash")
        .arg(script)
        .arg(&payload)
        .env("HOME", hook_env_home("notify-busy"))
        .env("UNPEEL_APP_PORT", capture.port.to_string())
        .env("UNPEEL_SESSION_ID", "unpeel-route-session")
        .env("UNPEEL_HOOK_POST_SYNC", "1")
        .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file("notify-busy"))
        .output()
        .expect("run notify hook");

    assert!(output.status.success(), "notify hook failed: {output:?}");
    let event = capture
        .wait_for_event_payload("Start", Duration::from_secs(5))
        .unwrap_or_else(|| panic!("expected Start event, got {:?}", capture.events_snapshot()));
    assert_eq!(
        event.get("type").and_then(Value::as_str),
        Some("task_started")
    );
    assert_eq!(
        event.get("session_id").and_then(Value::as_str),
        Some("codex-provider-session")
    );
    assert_eq!(
        event.get("transcript_path").and_then(Value::as_str),
        Some("/tmp/codex-provider-session.jsonl")
    );
    assert_eq!(
        event.get("cwd").and_then(Value::as_str),
        Some("/tmp/project")
    );
}

#[test]
fn notify_hook_script_preserves_codex_metadata_for_permission_events() {
    let capture = CaptureServer::start();
    let script = write_temp_codex_notify_hook("notify-permission");
    let payload = json!({
        "type": "apply_patch_approval_request",
        "session_id": "codex-approval-session",
        "transcript_path": "/tmp/codex-approval-session.jsonl",
        "tool_name": "apply_patch"
    })
    .to_string();

    let output = Command::new("bash")
        .arg(&script)
        .arg(&payload)
        .env("HOME", hook_env_home("notify-permission"))
        .env("UNPEEL_APP_PORT", capture.port.to_string())
        .env("UNPEEL_SESSION_ID", "unpeel-route-session")
        .env("UNPEEL_HOOK_POST_SYNC", "1")
        .env(
            "UNPEEL_HOOK_TRACE_FILE",
            hook_trace_file("notify-permission"),
        )
        .output()
        .expect("run notify hook");

    assert!(output.status.success(), "notify hook failed: {output:?}");
    let event = capture
        .wait_for_event_payload("PermissionRequest", Duration::from_secs(5))
        .unwrap_or_else(|| {
            panic!(
                "expected PermissionRequest event, got {:?}",
                capture.events_snapshot()
            )
        });
    assert_eq!(
        event.get("type").and_then(Value::as_str),
        Some("apply_patch_approval_request")
    );
    assert_eq!(
        event.get("session_id").and_then(Value::as_str),
        Some("codex-approval-session")
    );
    assert_eq!(
        event.get("transcript_path").and_then(Value::as_str),
        Some("/tmp/codex-approval-session.jsonl")
    );
    assert_eq!(
        event.get("tool_name").and_then(Value::as_str),
        Some("apply_patch")
    );
}

#[test]
fn codex_config_toml_enables_hooks_feature_without_rewriting_other_sections() {
    let raw = r#"model = "gpt-5.5"

[features]
mcp_client = true

[profiles.default]
approval_policy = "on-request"
"#;
    let updated = crate::hook_assets::enable_codex_hooks_feature_in_toml(raw).expect("enable hooks feature");
    assert!(updated.contains("[features]\nhooks = true\nmcp_client = true"));
    assert!(updated.contains("[profiles.default]\napproval_policy = \"on-request\""));
    assert!(crate::hook_assets::codex_hooks_feature_is_enabled(&updated).expect("parse updated"));
    assert_eq!(
        crate::hook_assets::enable_codex_hooks_feature_in_toml(&updated).expect("idempotent enable"),
        updated
    );
}

#[test]
fn codex_config_toml_replaces_disabled_hooks_feature() {
    let raw = r#"[features]
codex_hooks = false
some_other_flag = true
"#;
    let updated = crate::hook_assets::enable_codex_hooks_feature_in_toml(raw).expect("enable hooks feature");
    assert!(updated.contains("hooks = true"));
    assert!(!updated.contains("codex_hooks"));
    assert!(updated.contains("some_other_flag = true"));
}

#[test]
fn codex_config_toml_migrates_deprecated_feature_flags() {
    let raw = r#"[features]
codex_hooks = true
collab = true
js_repl = false
"#;
    let updated = crate::hook_assets::enable_codex_hooks_feature_in_toml(raw).expect("migrate features");
    assert!(updated.contains("hooks = true"));
    assert!(updated.contains("multi_agent = true"));
    assert!(updated.contains("js_repl = false"));
    assert!(!updated.contains("codex_hooks"));
    assert!(!updated.contains("collab"));
}

#[test]
fn codex_permission_request_hook_entry_matches_all_tools() {
    let script_path = PathBuf::from("/tmp/unpeel notify's hook");
    let entry = crate::hook_assets::build_codex_hook_entry("PermissionRequest", &script_path);
    assert_eq!(entry.get("matcher").and_then(Value::as_str), Some("*"));
    let command = entry
        .get("hooks")
        .and_then(Value::as_array)
        .and_then(|hooks| hooks.first())
        .and_then(|hook| hook.get("command"))
        .and_then(Value::as_str)
        .expect("hook command");
    assert!(command.contains("[ -x "));
    assert!(command.ends_with(crate::hook_assets::CODEX_MANAGED_HOOK_SUFFIX));
    assert_eq!(
        crate::hook_assets::parse_managed_codex_hook_command(command).as_deref(),
        Some(script_path.as_path())
    );
}

#[test]
fn codex_managed_hook_command_guards_only_a_missing_script() {
    let root = temp_path("codex-managed-guard");
    let script_path = root.join("hook path's notify.sh");
    let command = crate::hook_assets::build_codex_hook_command(&script_path);
    let missing_status = Command::new("/bin/sh")
        .arg("-c")
        .arg(&command)
        .status()
        .expect("run guarded hook command");
    assert!(missing_status.success());

    crate::hook_assets::write_executable_script(&script_path, "#!/bin/sh\nexit 23\n", "failing hook")
        .expect("write failing hook");
    let failing_status = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .status()
        .expect("run existing hook command");
    assert_eq!(failing_status.code(), Some(23));

    let _ = fs::remove_dir_all(root);
}

#[test]
fn codex_hooks_prune_only_stale_unpeel_entries() {
    let root = temp_path("codex-hook-cleanup");
    let current = root.join(".unpeel/hooks/notify-hook.sh");
    let other_live = root.join("unpeel-dev/hooks/notify-hook.sh");
    let stale = root.join("unpeel-color-probe-test/hooks/notify-hook.sh");
    let foreign = root.join(".clarity/hooks/notify-hook.sh");
    for path in [&current, &other_live] {
        fs::create_dir_all(path.parent().unwrap()).expect("create hook dir");
        fs::write(path, "#!/bin/sh\n").expect("write hook");
    }

    let mut hooks_json = json!({
        "hooks": {
            "UserPromptSubmit": [
                { "hooks": [{ "type": "command", "command": current.to_string_lossy() }] },
                { "hooks": [{ "type": "command", "command": other_live.to_string_lossy() }] },
                { "hooks": [{ "type": "command", "command": stale.to_string_lossy() }] },
                { "hooks": [{ "type": "command", "command": foreign.to_string_lossy() }] }
            ]
        }
    });

    assert!(crate::hook_assets::reconcile_codex_hooks_json(&mut hooks_json, &current));

    let prompt_commands: Vec<_> = hooks_json["hooks"]["UserPromptSubmit"]
        .as_array()
        .expect("prompt hooks")
        .iter()
        .filter_map(|entry| entry["hooks"][0]["command"].as_str())
        .collect();
    assert!(prompt_commands.contains(&current.to_string_lossy().as_ref()));
    assert!(prompt_commands.contains(&other_live.to_string_lossy().as_ref()));
    assert!(prompt_commands.contains(&foreign.to_string_lossy().as_ref()));
    assert!(!prompt_commands.contains(&stale.to_string_lossy().as_ref()));

    let stop_command = hooks_json["hooks"]["Stop"][0]["hooks"][0]["command"]
        .as_str()
        .expect("managed stop command");
    assert_eq!(
        crate::hook_assets::parse_managed_codex_hook_command(stop_command).as_deref(),
        Some(current.as_path())
    );
    assert!(!crate::hook_assets::reconcile_codex_hooks_json(
        &mut hooks_json,
        &current
    ));

    let _ = fs::remove_dir_all(root);
}

// Codex's shared app-server daemon starts MCP servers with the environment it
// started with, which can name a Session that is gone or a different one (#54).
// Forwarding that variable would hand the gate a stale identity, so the
// registration carries none and the gate falls back to process ancestry.
#[test]
fn codex_mcp_registration_forwards_no_unpeel_environment() {
    let shim = PathBuf::from("/tmp/unpeel home/bin/unpeel-mcp");
    let notify = PathBuf::from("/tmp/unpeel home/hooks/codex-notify-hook.sh");
    let updated = super::setup::reconcile_codex_config_toml("", &notify, &shim)
        .expect("reconcile Codex config.toml");
    let root = updated
        .parse::<toml::Value>()
        .expect("parse reconciled config");
    let server = root
        .get("mcp_servers")
        .and_then(|servers| servers.get("unpeel"))
        .and_then(toml::Value::as_table)
        .expect("[mcp_servers.unpeel]");
    let mut keys = server.keys().map(String::as_str).collect::<Vec<_>>();
    keys.sort_unstable();
    assert_eq!(keys, ["args", "command"], "{updated}");
    assert_eq!(
        server.get("command").and_then(toml::Value::as_str),
        Some(shim.to_string_lossy().as_ref())
    );
    assert!(!updated.contains("UNPEEL_"), "{updated}");
}

// Codex 0.156+ attaches every interactive launch to its shared daemon unless
// `--no-daemon` is on the command line; only the embedded server keeps MCP
// servers and hooks inside the Session (#54).
#[test]
fn codex_suggested_presets_run_without_the_shared_daemon() {
    let codex = crate::runtime_catalog::builtin_runtime_catalog()
        .by_slug("codex")
        .expect("codex descriptor");
    assert!(!codex.suggested_presets.is_empty());
    for preset in &codex.suggested_presets {
        let words = preset.command.split_whitespace().collect::<Vec<_>>();
        assert_eq!(words.first(), Some(&"codex"), "{}", preset.command);
        assert!(words.contains(&"--no-daemon"), "{}", preset.command);
    }
}
