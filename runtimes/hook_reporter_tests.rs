// Provider-neutral hook reporter/transport conformance; included by
// `unpeel_core::hook_assets` (test builds only). Package-specific tests
// live in `runtimes/<slug>/adapter/tests.rs`.

use super::test_support::*;
use super::{
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

#[cfg(unix)]
#[test]
fn project_hook_write_refuses_committed_symlink() {
    let project = temp_path("symlink-repo");
    let outside = temp_path("symlink-outside");
    let secret = outside.join("victim.txt");
    fs::write(&secret, "original secret\n").expect("seed victim file");

    // A malicious repo commits a symlink at the hook directory location
    // pointing at a directory outside the repo.
    let github = project.join(".github");
    fs::create_dir_all(&github).expect("create .github");
    std::os::unix::fs::symlink(&outside, github.join("hooks")).expect("plant symlink dir");

    let result = super::write_project_file_no_symlinks(
        &project,
        Path::new(".github/hooks/victim.txt"),
        b"overwritten by unpeel\n",
    );
    assert!(result.is_err(), "expected symlink traversal to be refused");
    assert_eq!(
        fs::read_to_string(&secret).unwrap(),
        "original secret\n",
        "file outside the repo must not be overwritten"
    );

    // A symlink at the leaf itself is also refused.
    let safe_dir = project.join(".amp").join("plugins");
    fs::create_dir_all(&safe_dir).expect("create plugins dir");
    std::os::unix::fs::symlink(&secret, safe_dir.join("unpeel-notify.js"))
        .expect("plant symlink leaf");
    let leaf = super::write_project_file_no_symlinks(
        &project,
        Path::new(".amp/plugins/unpeel-notify.js"),
        b"overwritten\n",
    );
    assert!(leaf.is_err(), "expected leaf symlink to be refused");
    assert_eq!(fs::read_to_string(&secret).unwrap(), "original secret\n");

    // A hard link at the leaf must be replaced as a directory entry, not
    // opened and truncated. The outside inode keeps its original bytes.
    let hardlink_project = temp_path("hardlink-hook-repo");
    let hardlink_dir = hardlink_project.join(".amp").join("plugins");
    fs::create_dir_all(&hardlink_dir).expect("create hardlink plugins dir");
    let hardlink_leaf = hardlink_dir.join("unpeel-notify.js");
    fs::hard_link(&secret, &hardlink_leaf).expect("plant hardlink leaf");
    super::write_project_file_no_symlinks(
        &hardlink_project,
        Path::new(".amp/plugins/unpeel-notify.js"),
        b"installed hook\n",
    )
    .expect("hardlink leaf should be safely replaced");
    assert_eq!(fs::read_to_string(&secret).unwrap(), "original secret\n");
    assert_eq!(
        fs::read_to_string(&hardlink_leaf).unwrap(),
        "installed hook\n"
    );

    // The best-effort git exclude update uses the same anchored writer;
    // a repo-controlled `.git` symlink must not turn that secondary write
    // into an overwrite outside the project either.
    let exclude_project = temp_path("symlink-exclude-repo");
    let outside_info = outside.join("info");
    fs::create_dir_all(&outside_info).expect("create outside git info dir");
    let outside_exclude = outside_info.join("exclude");
    fs::write(&outside_exclude, "outside exclude sentinel\n").expect("seed outside exclude");
    std::os::unix::fs::symlink(&outside, exclude_project.join(".git"))
        .expect("plant .git symlink");
    super::ensure_project_exclude_entry(&exclude_project.to_string_lossy(), "victim.txt");
    assert_eq!(
        fs::read_to_string(&outside_exclude).unwrap(),
        "outside exclude sentinel\n",
        "the exclude writer must not traverse a symlinked .git directory"
    );

    // The exclude leaf itself may also be a repo-controlled symlink. Its
    // read must fail closed before the append path has any chance to
    // replace or truncate the file outside the project.
    let symlink_exclude_project = temp_path("symlink-exclude-leaf-repo");
    let symlink_git_info = symlink_exclude_project.join(".git").join("info");
    fs::create_dir_all(&symlink_git_info).expect("create symlink git info dir");
    let symlink_exclude = symlink_git_info.join("exclude");
    std::os::unix::fs::symlink(&outside_exclude, &symlink_exclude)
        .expect("plant symlinked exclude leaf");
    super::ensure_project_exclude_entry(
        &symlink_exclude_project.to_string_lossy(),
        "generated-hook.json",
    );
    assert_eq!(
        fs::read_to_string(&outside_exclude).unwrap(),
        "outside exclude sentinel\n",
        "the exclude writer must not follow a symlinked exclude file"
    );
    assert_eq!(
        fs::read_link(&symlink_exclude).unwrap(),
        outside_exclude,
        "a refused exclude symlink must remain untouched"
    );

    // A hard-linked exclude file is safe for the same reason as a hook
    // leaf: read its current content, then atomically replace only the
    // repository's directory entry.
    let hardlink_exclude_project = temp_path("hardlink-exclude-repo");
    let git_info = hardlink_exclude_project.join(".git").join("info");
    fs::create_dir_all(&git_info).expect("create git info dir");
    let linked_exclude = git_info.join("exclude");
    fs::hard_link(&secret, &linked_exclude).expect("plant hardlinked exclude");
    super::ensure_project_exclude_entry(
        &hardlink_exclude_project.to_string_lossy(),
        "generated-hook.json",
    );
    assert_eq!(fs::read_to_string(&secret).unwrap(), "original secret\n");
    assert_eq!(
        fs::read_to_string(&linked_exclude).unwrap(),
        "original secret\ngenerated-hook.json\n"
    );

    // A clean repo path still installs normally.
    super::write_project_file_no_symlinks(
        &project,
        Path::new(".config/hooks/unpeel.json"),
        b"{}\n",
    )
    .expect("clean install should succeed");
    assert_eq!(
        fs::read_to_string(project.join(".config/hooks/unpeel.json")).unwrap(),
        "{}\n"
    );
}

#[test]
fn native_stop_outcomes_survive_delivery_and_restart_seeding() {
    let codex = write_temp_codex_notify_hook("codex-native-outcomes");
    let cases = [
        (
            "codex",
            "",
            "",
            r#"{"hook_event_name":"Interrupt"}"#,
            "StopCancelled",
        ),
        (
            "codex",
            "",
            "",
            r#"{"type":"turn_aborted"}"#,
            "StopCancelled",
        ),
        (
            "cursor",
            CURSOR_HOOK_SCRIPT,
            "Stop",
            r#"{"status":"aborted"}"#,
            "StopCancelled",
        ),
        (
            "cursor",
            CURSOR_HOOK_SCRIPT,
            "Stop",
            r#"{"status":"error"}"#,
            "StopFailure",
        ),
        (
            "cursor",
            CURSOR_HOOK_SCRIPT,
            "Stop",
            r#"{"status":"completed"}"#,
            "Stop",
        ),
        (
            "cline",
            CLINE_HOOK_SCRIPT,
            "TaskCancel",
            "{}",
            "StopCancelled",
        ),
        ("cline", CLINE_HOOK_SCRIPT, "TaskError", "{}", "StopFailure"),
        (
            "kimi",
            KIMI_HOOK_SCRIPT,
            "StopCancelled",
            "{}",
            "StopCancelled",
        ),
        (
            "copilot",
            COPILOT_HOOK_SCRIPT,
            "sessionEnd",
            r#"{"reason":"abort"}"#,
            "StopCancelled",
        ),
        (
            "copilot",
            COPILOT_HOOK_SCRIPT,
            "sessionEnd",
            r#"{"reason":"user_exit"}"#,
            "StopCancelled",
        ),
        (
            "copilot",
            COPILOT_HOOK_SCRIPT,
            "sessionEnd",
            r#"{"reason":"error"}"#,
            "StopFailure",
        ),
        (
            "copilot",
            COPILOT_HOOK_SCRIPT,
            "sessionEnd",
            r#"{"reason":"timeout"}"#,
            "StopFailure",
        ),
        (
            "copilot",
            COPILOT_HOOK_SCRIPT,
            "agentStop",
            r#"{"stopReason":"end_turn"}"#,
            "Stop",
        ),
    ];
    for (label, source, arg, input, expected) in cases {
        let capture = CaptureServer::start();
        let session_dir = temp_path(&format!("outcome-{label}"));
        let script = if label == "codex" {
            codex.clone()
        } else {
            write_temp_hook_script(label, source)
        };
        // Registry-only delivery also models a surviving PTY whose original
        // Host port is no longer available after a restart.
        let registry = session_dir.join("ports");
        fs::write(&registry, format!("{}\n", capture.port)).unwrap();
        let mut command = Command::new("bash");
        command.arg(script);
        if !arg.is_empty() {
            command.arg(arg);
        }
        let mut child = command
            .env("HOME", &session_dir)
            .env("UNPEEL_HOME", &session_dir)
            .env("UNPEEL_HOOK_TRACE_FILE", session_dir.join("trace.log"))
            .env("UNPEEL_SESSION_ID", "outcome")
            .env("UNPEEL_SESSION_DIR", &session_dir)
            .env("UNPEEL_RUNTIME_GENERATION", "7")
            .env("UNPEEL_APP_PORT", "")
            .env("UNPEEL_APP_PORT_REGISTRY_FILE", registry)
            .env_remove("UNPEEL_HOOK_POST_SYNC")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "{label}: {output:?}");
        assert_eq!(capture.event_names(), [expected], "{label}: {input}");
        let seed = read_last_hook_event(&session_dir);
        assert_eq!(seed["hook_event_name"], expected, "{label}: {input}");
        assert_eq!(seed["unpeel_runtime_generation"], 7);
    }
}

#[test]
fn tool_metadata_does_not_overwrite_a_settled_turn() {
    for (label, script, arg, input) in [
        ("cline", CLINE_HOOK_SCRIPT, "PostToolUse", "{}"),
        ("copilot", COPILOT_HOOK_SCRIPT, "postToolUse", "{}"),
        (
            "gemini",
            GEMINI_HOOK_SCRIPT,
            "",
            r#"{"hook_event_name":"AfterTool"}"#,
        ),
    ] {
        let session_dir = temp_path(&format!("metadata-{label}"));
        let seed = r#"{"hook_event_name":"StopCancelled","unpeel_runtime_generation":7}"#;
        fs::write(session_dir.join("last-hook-event.json"), seed).unwrap();
        let args = if arg.is_empty() { vec![] } else { vec![arg] };
        let output = run_hook_script_recording(script, label, &args, input, &session_dir);
        assert!(output.status.success(), "{label}: {output:?}");
        assert_eq!(
            fs::read_to_string(session_dir.join("last-hook-event.json")).unwrap(),
            seed,
            "{label}"
        );
    }
}

#[test]
fn all_hook_scripts_record_last_hook_event() {
    for (label, script) in [
        ("claude", super::CLAUDE_HOOK_SCRIPT),
        ("cline", super::CLINE_HOOK_SCRIPT),
        ("kiro", super::KIRO_HOOK_SCRIPT),
        ("notify", super::NOTIFY_HOOK_SCRIPT),
        ("gemini", super::GEMINI_HOOK_SCRIPT),
        ("kimi", super::KIMI_HOOK_SCRIPT),
        ("copilot", super::COPILOT_HOOK_SCRIPT),
        ("cursor", super::CURSOR_HOOK_SCRIPT),
        ("grok", super::GROK_HOOK_SCRIPT),
        ("muse", super::MUSE_HOOK_SCRIPT),
        ("codewhale", super::CODEWHALE_HOOK_SCRIPT),
    ] {
        assert!(
            script.contains("record_last_hook_event() {"),
            "{label} hook script must define record_last_hook_event"
        );
        assert!(
            script.contains("record_last_hook_event \""),
            "{label} hook script must call record_last_hook_event"
        );
        assert!(
            script.contains("last-hook-event.json"),
            "{label} hook script must write last-hook-event.json"
        );
        assert!(
            script.contains("UNPEEL_SESSION_DIR"),
            "{label} hook script must honor UNPEEL_SESSION_DIR"
        );
    }
}

#[test]
fn hook_reporters_are_inert_outside_unpeel() {
    for (label, script) in [
        ("claude", CLAUDE_HOOK_SCRIPT),
        ("notify", NOTIFY_HOOK_SCRIPT),
        ("gemini", GEMINI_HOOK_SCRIPT),
        ("copilot", COPILOT_HOOK_SCRIPT),
        ("cursor", CURSOR_HOOK_SCRIPT),
        ("grok", super::GROK_HOOK_SCRIPT),
        ("muse", super::MUSE_HOOK_SCRIPT),
        ("kimi", KIMI_HOOK_SCRIPT),
        ("kiro", KIRO_HOOK_SCRIPT),
        ("cline", CLINE_HOOK_SCRIPT),
        ("codewhale", super::CODEWHALE_HOOK_SCRIPT),
    ] {
        let home = temp_path(&format!("inert-{label}-home"));
        let script = write_temp_hook_script(&format!("inert-{label}"), script);
        // Keep an env-cleared parent shell for Muse's legacy ps fallback.
        let output = Command::new("bash")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &home)
            .env("UNPEEL_HOME", &home)
            .arg("-c")
            .arg("bash \"$1\"; result=$?; exit \"$result\"")
            .arg("hook-test")
            .arg(script)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "{label}: {output:?}");
        assert!(output.stderr.is_empty(), "{label}: {output:?}");
        assert_eq!(
            fs::read_dir(&home).unwrap().count(),
            0,
            "{label} must not write traces or markers outside a Session"
        );
    }
}

#[test]
fn stalled_ports_do_not_starve_later_hook_listeners() {
    for case in reporter_cases() {
        let home = temp_path(&format!("stalled-{}", case.label));
        let script = write_temp_hook_script(case.label, case.script);
        let stalled = (0..4)
            .map(|_| TcpListener::bind("127.0.0.1:0").unwrap())
            .collect::<Vec<_>>();
        let capture = CaptureServer::start();
        let registry = home.join("ports");
        fs::write(
            &registry,
            stalled
                .iter()
                .skip(1)
                .map(|socket| format!("{}\n", socket.local_addr().unwrap().port()))
                .collect::<String>()
                + &format!("{}\n", capture.port),
        )
        .unwrap();
        let mut command = Command::new("bash");
        command
            .arg(script)
            .args(case.args)
            .env("HOME", &home)
            .env("UNPEEL_HOME", &home)
            .env("UNPEEL_SESSION_ID", "stalled")
            .env("UNPEEL_HOOK_TRACE_FILE", home.join("trace.log"))
            .env(
                "UNPEEL_APP_PORT",
                stalled[0].local_addr().unwrap().port().to_string(),
            )
            .env("UNPEEL_APP_PORT_REGISTRY_FILE", registry)
            .env_remove("UNPEEL_HOOK_POST_SYNC")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let started = Instant::now();
        let mut child = command.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(case.input.as_bytes())
            .unwrap();
        // Four silent TCP peers used to consume eight seconds in sequence,
        // beyond the provider's five-second hook deadline.
        assert!(
            capture.wait_for_event("Stop", Duration::from_secs(4)),
            "{}",
            case.label
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(child.wait().unwrap().success());
    }
}

#[test]
fn every_owned_hook_reporter_tags_http_payload_and_durable_seed_generation() {
    for case in reporter_cases() {
        let capture = CaptureServer::start();
        let peer = CaptureServer::start();
        let session_dir = temp_path(&format!("{}-session", case.label));
        let registry = session_dir.join("ports");
        fs::write(
            &registry,
            format!(
                "{}\n{}\n{}\ninvalid 42\n70000\n",
                capture.port, peer.port, peer.port
            ),
        )
        .unwrap();
        let script = write_temp_hook_script(case.label, case.script);
        let mut command = Command::new("bash");
        command
            .arg(&script)
            .args(case.args)
            .env("HOME", hook_env_home(case.label))
            .env("UNPEEL_APP_PORT", capture.port.to_string())
            .env("UNPEEL_SESSION_ID", "unpeel-generation-session")
            .env("UNPEEL_SESSION_DIR", &session_dir)
            .env("UNPEEL_RUNTIME_GENERATION", "42")
            .env_remove("UNPEEL_HOOK_POST_SYNC")
            .env("all_proxy", "http://127.0.0.1:9")
            .env_remove("NO_PROXY")
            .env_remove("no_proxy")
            .env("UNPEEL_APP_PORT_REGISTRY_FILE", &registry)
            .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file(case.label))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().expect("spawn generation hook reporter");
        child
            .stdin
            .take()
            .expect("hook stdin")
            .write_all(case.input.as_bytes())
            .expect("write generation hook stdin");
        let output = child.wait_with_output().expect("wait for hook reporter");
        assert!(
            output.status.success(),
            "{} reporter failed: {output:?}",
            case.label
        );
        assert_eq!(
            capture.events_snapshot().len(),
            1,
            "{} direct delivery finishes before exit and is deduplicated",
            case.label
        );
        assert_eq!(
            peer.events_snapshot().len(),
            1,
            "{} registry delivery finishes before exit and bypasses proxy env",
            case.label
        );

        let posted = capture
            .wait_for_event_payload("Stop", Duration::from_secs(5))
            .unwrap_or_else(|| {
                panic!(
                    "{} did not post Stop; got {:?}",
                    case.label,
                    capture.events_snapshot()
                )
            });
        assert_eq!(
            posted
                .get("unpeel_runtime_generation")
                .and_then(Value::as_u64),
            Some(42),
            "{} HTTP payload",
            case.label
        );
        let seed = read_last_hook_event(&session_dir);
        assert_eq!(
            seed.get("unpeel_runtime_generation")
                .and_then(Value::as_u64),
            Some(42),
            "{} durable seed",
            case.label
        );
    }

    // OpenCode and Amp both invoke the Notify reporter above instead of
    // maintaining an independent HTTP/seed implementation.
    assert!(super::OPENCODE_PLUGIN_SCRIPT.contains("bash ${notifyPath}"));
    assert!(super::AMP_PLUGIN_SCRIPT.contains("Bun.spawn([\"bash\", notifyPath, body]"));
}

#[test]
fn notify_hook_script_records_mapped_last_hook_event() {
    let session_dir = temp_path("notify-record-session");
    let payload = json!({ "type": "agent-turn-complete" }).to_string();
    let script = write_temp_codex_notify_hook("notify-record");
    let output =
        run_hook_path_recording(&script, "notify-record", &[&payload], "", &session_dir);
    assert!(output.status.success(), "notify hook failed: {output:?}");
    let event = read_last_hook_event(&session_dir);
    assert_eq!(
        event.get("hook_event_name").and_then(Value::as_str),
        Some("Stop")
    );
}

#[test]
fn record_last_hook_event_skips_missing_session_dir() {
    let missing_dir = temp_path("claude-record-missing").join("gone");
    let payload = json!({ "hook_event_name": "Stop" }).to_string();
    let output = run_hook_script_recording(
        super::CLAUDE_HOOK_SCRIPT,
        "claude-record-missing",
        &[],
        &payload,
        &missing_dir,
    );
    assert!(output.status.success(), "claude hook failed: {output:?}");
    assert!(
        !missing_dir.exists(),
        "record must never create the session dir"
    );
}

#[test]
fn read_mergeable_json_skips_update_on_malformed_settings() {
    let dir = std::env::temp_dir().join(format!("unpeel-merge-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);

    // Missing file → an empty object to merge into.
    let missing = dir.join("missing.json");
    assert_eq!(
        super::read_mergeable_json_object(&missing, "missing").unwrap(),
        Some(serde_json::json!({}))
    );

    // Malformed JSON (e.g. trailing comma / torn write) → None, so callers
    // skip the update and leave the user's file intact instead of clobbering
    // it with an Unpeel-only object.
    let malformed = dir.join("malformed.json");
    std::fs::write(&malformed, "{ \"hooks\": {,,, ").unwrap();
    assert_eq!(
        super::read_mergeable_json_object(&malformed, "malformed").unwrap(),
        None
    );

    // A non-object root (array) is also treated as "do not touch".
    let array = dir.join("array.json");
    std::fs::write(&array, "[1,2,3]").unwrap();
    assert_eq!(
        super::read_mergeable_json_object(&array, "array").unwrap(),
        None
    );

    // Valid object → returned for merging.
    let valid = dir.join("valid.json");
    std::fs::write(&valid, "{\"existing\":true}").unwrap();
    assert_eq!(
        super::read_mergeable_json_object(&valid, "valid").unwrap(),
        Some(serde_json::json!({"existing": true}))
    );

    let _ = std::fs::remove_dir_all(&dir);
}
