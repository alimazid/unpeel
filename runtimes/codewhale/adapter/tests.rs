use super::setup::*;
use crate::hook_assets::test_support::*;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

const SCRIPT: &str = "/opt/unpeel home/hooks/codewhale-hook.sh";

fn script_path() -> PathBuf {
    PathBuf::from(SCRIPT)
}

fn managed_hooks(config: &str) -> Vec<Value> {
    let value: toml::Value = toml::from_str(config).expect("valid TOML");
    let hooks = value
        .get("hooks")
        .and_then(|hooks| hooks.get("hooks"))
        .and_then(toml::Value::as_array)
        .cloned()
        .unwrap_or_default();
    hooks
        .into_iter()
        .map(|hook| serde_json::to_value(hook).expect("hook as JSON"))
        .filter(|hook| {
            hook["command"]
                .as_str()
                .is_some_and(|command| command.contains("hooks/codewhale-hook.sh"))
        })
        .collect()
}

#[test]
fn managed_block_registers_every_observer_event_once() {
    let config = reconcile_codewhale_config("", &script_path()).expect("reconcile empty");
    let hooks = managed_hooks(&config);
    let events: Vec<&str> = hooks
        .iter()
        .map(|hook| hook["event"].as_str().unwrap())
        .collect();
    assert_eq!(
        events,
        [
            "session_start",
            "session_busy",
            "waiting_for_user",
            "turn_end",
            "session_idle",
            "session_end"
        ]
    );
    for hook in &hooks {
        assert_eq!(hook["timeout_secs"], 5);
        assert!(hook.get("background").is_none());
    }
    // Steering hooks would sit in the foreground of every submit/tool call.
    assert!(!config.contains("message_submit"));
    assert!(!config.contains("tool_call_before"));
    // The command survives a space in the Unpeel home.
    assert_eq!(
        hooks[1]["command"],
        "[ ! -x '/opt/unpeel home/hooks/codewhale-hook.sh' ] || '/opt/unpeel home/hooks/codewhale-hook.sh' Busy"
    );
}

#[test]
fn reconcile_preserves_user_configuration_and_is_idempotent() {
    let user = r#"# my settings
default_text_model = "deepseek-flash"

[providers.deepseek]
api_key = "sk-secret"

[hooks]
enabled = true
default_timeout_secs = 20

[[hooks.hooks]]
name = "announce"
event = "session_start"
command = "echo started"
"#;
    let once = reconcile_codewhale_config(user, &script_path()).expect("reconcile");
    assert!(once.starts_with(user.trim_end()));
    assert!(once.contains("api_key = \"sk-secret\""));
    assert!(once.contains("command = \"echo started\""));
    assert_eq!(managed_hooks(&once).len(), CODEWHALE_HOOK_EVENTS.len());
    let twice = reconcile_codewhale_config(&once, &script_path()).expect("reconcile again");
    assert_eq!(once, twice);

    // A tool that rewrote the file without our markers leaves bare managed
    // tables behind; the next install replaces them instead of duplicating.
    let unmarked = once
        .replace(CODEWHALE_MANAGED_HOOKS_START, "")
        .replace(CODEWHALE_MANAGED_HOOKS_END, "");
    let repaired = reconcile_codewhale_config(&unmarked, &script_path()).expect("repair");
    assert_eq!(managed_hooks(&repaired).len(), CODEWHALE_HOOK_EVENTS.len());
    assert!(repaired.contains("command = \"echo started\""));
}

#[test]
fn reconcile_refuses_configs_it_cannot_extend() {
    assert!(reconcile_codewhale_config("api_key = ", &script_path())
        .unwrap_err()
        .contains("invalid"));
    // An inline `hooks` array cannot take appended `[[hooks.hooks]]` tables.
    let inline = "[hooks]\nhooks = []\n";
    assert!(reconcile_codewhale_config(inline, &script_path()).is_err());
}

#[test]
fn installer_never_rewrites_a_malformed_config() {
    let dir = tempfile::tempdir().expect("temp dir");
    let config = dir.path().join("config.toml");
    fs::write(&config, "api_key = \n").unwrap();
    assert!(ensure_codewhale_hooks_at(&config, &script_path()).is_err());
    assert_eq!(fs::read_to_string(&config).unwrap(), "api_key = \n");

    let fresh = dir.path().join("fresh").join("config.toml");
    ensure_codewhale_hooks_at(&fresh, &script_path()).expect("create config");
    assert_eq!(
        managed_hooks(&fs::read_to_string(&fresh).unwrap()).len(),
        CODEWHALE_HOOK_EVENTS.len()
    );
}

#[test]
fn state_files_target_what_codewhale_reads() {
    let dir = tempfile::tempdir().expect("temp dir");
    let home = dir.path().join(".codewhale");
    let legacy = dir.path().join(".deepseek");
    let dirs = CodewhaleDirs {
        home: home.clone(),
        legacy: Some(legacy.clone()),
    };
    // Nothing yet: create the current file.
    assert_eq!(
        resolve_state_file(&dirs, "config.toml"),
        home.join("config.toml")
    );
    // Only a pre-rename file: edit it rather than shadow it.
    fs::create_dir_all(&legacy).unwrap();
    fs::write(legacy.join("config.toml"), "").unwrap();
    assert_eq!(
        resolve_state_file(&dirs, "config.toml"),
        legacy.join("config.toml")
    );
    assert_eq!(resolve_state_file(&dirs, "mcp.json"), home.join("mcp.json"));
    // The current file always wins once it exists.
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("config.toml"), "").unwrap();
    assert_eq!(
        resolve_state_file(&dirs, "config.toml"),
        home.join("config.toml")
    );
    // CODEWHALE_HOME replaces the base directory with no legacy fallback.
    let explicit = CodewhaleDirs {
        home: dir.path().join("custom"),
        legacy: None,
    };
    assert_eq!(
        resolve_state_file(&explicit, "config.toml"),
        dir.path().join("custom").join("config.toml")
    );
}

fn shim() -> PathBuf {
    crate::integrations::install::mcp_shim_path_in(Path::new("/opt/unpeel"))
}

#[test]
fn mcp_config_gains_one_managed_server_and_keeps_the_rest() {
    let mut config = json!({
        "timeouts": { "connect_timeout": 30 },
        "servers": { "git": { "command": "git-mcp", "args": [] } }
    });
    merge_codewhale_mcp_config(&mut config, &shim()).expect("merge");
    merge_codewhale_mcp_config(&mut config, &shim()).expect("merge again");
    assert_eq!(config["timeouts"]["connect_timeout"], 30);
    assert_eq!(config["servers"]["git"]["command"], "git-mcp");
    assert_eq!(
        config["servers"]["unpeel"],
        codewhale_managed_mcp_entry(&shim())
    );
    assert_eq!(config["servers"].as_object().unwrap().len(), 2);
}

#[test]
fn mcp_config_respects_compat_key_and_user_owned_names() {
    let mut compat = json!({ "mcpServers": { "fs": { "command": "fs-mcp" } } });
    merge_codewhale_mcp_config(&mut compat, &shim()).expect("merge compat");
    assert!(compat.get("servers").is_none());
    assert_eq!(
        compat["mcpServers"]["unpeel"]["command"],
        shim().to_string_lossy().as_ref()
    );

    let mut user_owned = json!({ "servers": { "unpeel": { "command": "my-own-unpeel" } } });
    merge_codewhale_mcp_config(&mut user_owned, &shim()).expect("merge user-owned");
    assert_eq!(user_owned["servers"]["unpeel"]["command"], "my-own-unpeel");
    assert_eq!(
        user_owned["servers"]["unpeel-unpeel"],
        codewhale_managed_mcp_entry(&shim())
    );
}

#[test]
fn mcp_installer_leaves_malformed_json_untouched() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("mcp.json");
    fs::write(&path, "{ not json").unwrap();
    assert!(write_codewhale_mcp_config_at(&path, &shim()).is_err());
    assert_eq!(fs::read_to_string(&path).unwrap(), "{ not json");

    let fresh = dir.path().join("new").join("mcp.json");
    write_codewhale_mcp_config_at(&fresh, &shim()).expect("create mcp.json");
    let written: Value = serde_json::from_str(&fs::read_to_string(&fresh).unwrap()).unwrap();
    assert_eq!(
        written["servers"]["unpeel"],
        codewhale_managed_mcp_entry(&shim())
    );
}

/// Run the reporter as Codewhale does — argv[1] from the managed command,
/// the event payload on stdin — and return what reached the Host and disk.
fn report(
    label: &str,
    argument: &str,
    input: &str,
    seed: Option<&str>,
) -> (CaptureServer, PathBuf, std::process::Output) {
    let capture = CaptureServer::start();
    let session_dir = temp_path(&format!("{label}-session"));
    if let Some(seed) = seed {
        fs::write(session_dir.join("last-hook-event.json"), seed).unwrap();
    }
    let script = write_temp_hook_script(label, CODEWHALE_HOOK_SCRIPT);
    let mut child = Command::new("bash")
        .arg(&script)
        .arg(argument)
        .env("HOME", hook_env_home(label))
        .env("UNPEEL_APP_PORT", capture.port.to_string())
        .env("UNPEEL_SESSION_ID", "unpeel-route-session")
        .env("UNPEEL_SESSION_DIR", &session_dir)
        .env("UNPEEL_RUNTIME_GENERATION", "7")
        .env(
            "UNPEEL_APP_PORT_REGISTRY_FILE",
            session_dir.join("no-ports"),
        )
        .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file(label))
        .env("CODEWHALE_SESSION_ID", "sess_1234abcd")
        .env("DEEPSEEK_SESSION_ID", "sess_1234abcd")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn codewhale hook");
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let output = child.wait_with_output().expect("wait for codewhale hook");
    assert!(output.status.success(), "{label}: {output:?}");
    assert!(output.stdout.is_empty(), "{label} must print nothing");
    (capture, session_dir, output)
}

fn delivered(capture: &CaptureServer, label: &str) -> Value {
    let events = capture.events_snapshot();
    assert_eq!(events.len(), 1, "{label}: {events:?}");
    events.into_iter().next().unwrap()
}

/// Run the reporter under a parent that holds `held` open, the way the
/// Codewhale process holds its current session's `.live` file.
fn report_under_holder(label: &str, held: &Path) -> Value {
    let capture = CaptureServer::start();
    let session_dir = temp_path(&format!("{label}-session"));
    let script = write_temp_hook_script(label, CODEWHALE_HOOK_SCRIPT);
    let mut child = Command::new("bash")
        .arg("-c")
        // The trailing `exit` keeps bash from exec-ing the reporter, so the
        // holder stays its parent.
        .arg("exec 9<\"$1\"; bash \"$2\" TurnEnd; exit $?")
        .arg("holder")
        .arg(held)
        .arg(&script)
        .env("HOME", hook_env_home(label))
        .env("UNPEEL_APP_PORT", capture.port.to_string())
        .env("UNPEEL_SESSION_ID", "unpeel-route-session")
        .env("UNPEEL_SESSION_DIR", &session_dir)
        .env("UNPEEL_RUNTIME_GENERATION", "7")
        .env(
            "UNPEEL_APP_PORT_REGISTRY_FILE",
            session_dir.join("no-ports"),
        )
        .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file(label))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn holder");
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(br#"{"event":"turn_end","model_backed":true,"status":"completed"}"#)
        .unwrap();
    let output = child.wait_with_output().expect("wait for holder");
    assert!(output.status.success(), "{label}: {output:?}");
    delivered(&capture, label)
}

#[test]
fn turn_end_reports_the_saved_session_codewhale_holds_open() {
    let sessions = temp_path("codewhale-saved-session").join("sessions");
    let id = "0ba332ad-97b9-4809-a925-c04069629139";
    fs::create_dir_all(sessions.join(".late-usage")).unwrap();
    let live = sessions.join(".late-usage").join(format!("{id}.live"));
    fs::write(&live, "").unwrap();

    // No saved document yet: nothing resumable to report.
    let event = report_under_holder("codewhale-unsaved-session", &live);
    assert_eq!(event["hook_event_name"], "Stop");
    assert!(event.get("session_id").is_none(), "{event}");

    let document = sessions.join(format!("{id}.json"));
    fs::write(&document, "{}").unwrap();
    let event = report_under_holder("codewhale-saved-session", &live);
    assert_eq!(event["session_id"], id);
    let reported = PathBuf::from(event["transcript_path"].as_str().unwrap());
    assert_eq!(
        fs::canonicalize(reported).unwrap(),
        fs::canonicalize(&document).unwrap()
    );
}

#[test]
fn turn_end_status_becomes_the_turn_outcome() {
    for (status, expected) in [
        ("completed", "Stop"),
        ("interrupted", "StopCancelled"),
        ("failed", "StopFailure"),
    ] {
        let label = format!("codewhale-turn-{status}");
        let input = format!(
            r#"{{"event":"turn_end","session_id":"sess_1234abcd","model_backed":true,"turn_id":"t1","status":"{status}","error":null}}"#
        );
        let (capture, session_dir, _) = report(&label, "TurnEnd", &input, None);
        let event = delivered(&capture, &label);
        assert_eq!(event["hook_event_name"], expected);
        assert_eq!(event["unpeel_runtime_generation"], 7);
        // The hook id is not the saved-session id `--resume` accepts.
        assert!(event.get("session_id").is_none(), "{event}");
        let seed = read_last_hook_event(&session_dir);
        assert_eq!(seed["hook_event_name"], expected);
        assert_eq!(seed["unpeel_runtime_generation"], 7);
    }
}

#[test]
fn shell_only_turns_and_unknown_statuses_settle_without_completion() {
    for (label, input) in [
        (
            "codewhale-shell-turn",
            r#"{"event":"turn_end","model_backed":false,"turn_id":"user_shell_3","status":"completed"}"#,
        ),
        (
            "codewhale-odd-turn",
            r#"{"event":"turn_end","model_backed":true,"status":"something_new"}"#,
        ),
    ] {
        let (capture, session_dir, _) = report(
            label,
            "TurnEnd",
            input,
            Some(r#"{"hook_event_name":"Start"}"#),
        );
        assert_eq!(delivered(&capture, label)["hook_event_name"], "HookSeen");
        assert_eq!(
            read_last_hook_event(&session_dir)["hook_event_name"],
            "Idle"
        );
    }
}

#[test]
fn idle_backstop_never_overwrites_a_known_outcome() {
    let (capture, session_dir, _) = report(
        "codewhale-idle-after-stop",
        "Idle",
        r#"{"from":"in_progress","to":"idle","last_turn_status":"completed"}"#,
        Some(r#"{"hook_event_name":"StopCancelled","unpeel_runtime_generation":7}"#),
    );
    assert_eq!(
        delivered(&capture, "codewhale-idle-after-stop")["hook_event_name"],
        "HookSeen"
    );
    assert_eq!(
        read_last_hook_event(&session_dir)["hook_event_name"],
        "StopCancelled"
    );

    let (_, session_dir, _) = report(
        "codewhale-idle-repairs-open-turn",
        "Idle",
        r#"{"from":"in_progress","to":"idle"}"#,
        Some(r#"{"hook_event_name":"Start","unpeel_runtime_generation":7}"#),
    );
    assert_eq!(
        read_last_hook_event(&session_dir)["hook_event_name"],
        "Idle"
    );
}

#[test]
fn busy_and_waiting_map_to_opening_and_attention_events() {
    let (capture, session_dir, _) = report(
        "codewhale-busy",
        "Busy",
        r#"{"from":"waiting","to":"in_progress"}"#,
        None,
    );
    assert_eq!(
        delivered(&capture, "codewhale-busy")["hook_event_name"],
        "Start"
    );
    assert_eq!(
        read_last_hook_event(&session_dir)["hook_event_name"],
        "Start"
    );

    for reason in ["approval", "user_input", "goal_continuation"] {
        let label = format!("codewhale-waiting-{reason}");
        let input = format!(r#"{{"from":"in_progress","to":"waiting","reason":"{reason}"}}"#);
        let (capture, _, _) = report(&label, "Attention", &input, None);
        let event = capture
            .wait_for_event_payload("PermissionRequest", Duration::from_secs(5))
            .unwrap_or_else(|| panic!("{label}: {:?}", capture.events_snapshot()));
        assert_eq!(event["tool_name"], reason);
    }
}

#[test]
fn session_start_latches_without_touching_the_durable_outcome() {
    let (capture, session_dir, _) = report(
        "codewhale-session-start",
        "HookSeen",
        "",
        Some(r#"{"hook_event_name":"Stop","unpeel_runtime_generation":7}"#),
    );
    assert_eq!(
        delivered(&capture, "codewhale-session-start")["hook_event_name"],
        "HookSeen"
    );
    assert_eq!(
        read_last_hook_event(&session_dir)["hook_event_name"],
        "Stop"
    );
}

#[test]
fn managed_command_runs_the_reporter_and_tolerates_a_removed_script() {
    let capture = CaptureServer::start();
    let script = write_temp_hook_script("codewhale-managed-command", CODEWHALE_HOOK_SCRIPT);
    let run = |command: &str| {
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(command)
            .env("HOME", hook_env_home("codewhale-managed-command"))
            .env("UNPEEL_APP_PORT", capture.port.to_string())
            .env("UNPEEL_SESSION_ID", "unpeel-route-session")
            .env(
                "UNPEEL_HOOK_TRACE_FILE",
                hook_trace_file("codewhale-managed-command"),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn sh");
        use std::io::Write;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"from":"idle","to":"in_progress"}"#)
            .unwrap();
        child.wait_with_output().expect("wait for sh")
    };
    let output = run(&codewhale_hook_command(&script, "Busy"));
    assert!(output.status.success(), "{output:?}");
    assert!(capture.wait_for_event("Start", Duration::from_secs(5)));

    let missing = script.with_file_name("gone.sh");
    let output = run(&codewhale_hook_command(&missing, "Busy"));
    assert!(output.status.success(), "{output:?}");
    assert!(output.stderr.is_empty(), "{output:?}");
}
