use super::*;
use serde_json::json;

const LAUNCHED_AT: u64 = 1_800_000_000_000;

/// A Running Session launched at `LAUNCHED_AT`, patched by `extra`.
fn manifest(extra: serde_json::Value) -> HostedSessionManifest {
    let mut value = json!({
        "session": {
            "id": "s", "project_id": "p", "label": "agent",
            "command": "claude", "created_at": LAUNCHED_AT,
        },
        "cwd": "/tmp",
        "state": "running",
        "pid": 42,
        "exit_code": null,
    });
    for (key, field) in extra.as_object().expect("patch object") {
        value[key] = field.clone();
    }
    serde_json::from_value(value).expect("test manifest")
}

fn observed_claude() -> serde_json::Value {
    json!({ "currentObservation": { "id": "claude", "pid": 43 } })
}

fn program(state: &str, changed_at: u64) -> serde_json::Value {
    json!({ "state": state, "changed_at": changed_at })
}

fn seed(event: &str, generation: Option<u64>, written_at_ms: u64) -> HookSeed {
    HookSeed {
        event: event.into(),
        runtime_generation: generation,
        written_at_ms,
    }
}

#[test]
fn a_running_session_with_no_activity_is_not_ready() {
    // The default-idle trap: Controllers read "idle" for a Running Session
    // with no activity entry. That default must never count as ready.
    assert_eq!(readiness_signal(&manifest(json!({})), None), None);
    let observed_but_silent = manifest(json!({ "runtime": observed_claude() }));
    assert_eq!(readiness_signal(&observed_but_silent, None), None);
}

#[test]
fn a_program_idle_report_after_launch_is_ready() {
    let reported = manifest(json!({ "program_status": program("idle", LAUNCHED_AT + 900) }));
    assert_eq!(
        readiness_signal(&reported, None),
        Some(ReadinessSignal::Program)
    );
}

#[test]
fn only_an_idle_program_record_counts() {
    for state in ["working", "blocked", "done", "error"] {
        let reported = manifest(json!({ "program_status": program(state, LAUNCHED_AT + 900) }));
        assert_eq!(readiness_signal(&reported, None), None, "{state}");
    }
}

#[test]
fn a_program_record_from_before_the_launch_is_not_ready() {
    let stale = manifest(json!({
        "runtime_launched_at": LAUNCHED_AT + 5_000,
        "program_status": program("idle", LAUNCHED_AT + 900),
    }));
    assert_eq!(readiness_signal(&stale, None), None);
}

#[test]
fn the_declared_idle_prompt_on_screen_is_ready() {
    let prompt = manifest(json!({ "runtime": observed_claude(), "screen_activity": "idle" }));
    assert_eq!(
        readiness_signal(&prompt, None),
        Some(ReadinessSignal::Screen)
    );
    let spinner = manifest(json!({ "runtime": observed_claude(), "screen_activity": "working" }));
    assert_eq!(readiness_signal(&spinner, None), None);
}

#[test]
fn a_screen_verdict_needs_a_runtime_that_declares_screen_rules() {
    let unobserved = manifest(json!({ "screen_activity": "idle" }));
    assert_eq!(readiness_signal(&unobserved, None), None);
    let no_rules = manifest(json!({
        "runtime": { "currentObservation": { "id": "not-a-runtime", "pid": 43 } },
        "screen_activity": "idle",
    }));
    assert_eq!(readiness_signal(&no_rules, None), None);
}

#[test]
fn a_hook_reporting_idle_after_launch_is_ready() {
    let running = manifest(json!({ "runtime_launch_generation": 1 }));
    for event in [
        "Idle",
        "Stop",
        "StopFailure",
        "StopCancelled",
        "stop_failure",
        "idle",
    ] {
        assert_eq!(
            readiness_signal(&running, Some(&seed(event, Some(1), LAUNCHED_AT + 10))),
            Some(ReadinessSignal::Hook),
            "{event}"
        );
    }
    // Older hook assets carry no generation.
    assert_eq!(
        readiness_signal(&running, Some(&seed("Idle", None, LAUNCHED_AT + 10))),
        Some(ReadinessSignal::Hook)
    );
}

#[test]
fn hooks_that_are_not_idle_or_not_from_this_launch_are_not_ready() {
    let running = manifest(json!({ "runtime_launch_generation": 2 }));
    for event in ["Start", "UserPromptSubmit", "PermissionRequest", "HookSeen"] {
        assert_eq!(
            readiness_signal(&running, Some(&seed(event, Some(2), LAUNCHED_AT + 10))),
            None,
            "{event}"
        );
    }
    assert_eq!(
        readiness_signal(&running, Some(&seed("Stop", Some(2), LAUNCHED_AT - 1))),
        None,
        "a seed written before the launch"
    );
    assert_eq!(
        readiness_signal(&running, Some(&seed("Stop", Some(1), LAUNCHED_AT + 10))),
        None,
        "a seed from the replaced runtime generation"
    );
}

#[test]
fn an_exited_session_is_never_ready() {
    let exited = manifest(json!({
        "state": "exited",
        "program_status": program("idle", LAUNCHED_AT + 900),
    }));
    assert_eq!(readiness_signal(&exited, None), None);
    assert_eq!(
        observe(Some(exited), Path::new("/nonexistent")),
        ReadinessObservation::Ended
    );
    assert_eq!(
        observe(None, Path::new("/nonexistent")),
        ReadinessObservation::Ended
    );
}

#[test]
fn the_hook_seed_is_read_from_the_session_directory() {
    let dir = tempfile::tempdir().expect("tempdir");
    assert_eq!(read_hook_seed(dir.path()), None);
    std::fs::write(
        dir.path().join("last-hook-event.json"),
        r#"{"hook_event_name":"Idle","unpeel_runtime_generation":3}"#,
    )
    .expect("seed");
    let read = read_hook_seed(dir.path()).expect("seed parses");
    assert_eq!(read.event, "Idle");
    assert_eq!(read.runtime_generation, Some(3));
    let now_ms = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .expect("clock")
        .as_millis() as u64;
    assert!(
        read.written_at_ms + 60_000 > now_ms,
        "mtime is the write time"
    );

    std::fs::write(dir.path().join("last-hook-event.json"), "not json").expect("seed");
    assert_eq!(read_hook_seed(dir.path()), None);
}

#[test]
fn a_running_session_dir_with_an_idle_seed_observes_ready() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(
        dir.path().join("last-hook-event.json"),
        r#"{"hook_event_name":"Stop"}"#,
    )
    .expect("seed");
    let fresh = manifest(json!({ "session": {
        "id": "s", "project_id": "p", "label": "agent", "command": "claude",
        "created_at": 1,
    }}));
    assert_eq!(
        observe(Some(fresh), dir.path()),
        ReadinessObservation::Ready(ReadinessSignal::Hook)
    );
}

#[test]
fn the_wait_returns_the_first_signal_and_stops_on_exit() {
    let far = Instant::now() + Duration::from_secs(5);
    let mut looks = vec![
        ReadinessObservation::NotYet,
        ReadinessObservation::NotYet,
        ReadinessObservation::Ready(ReadinessSignal::Screen),
    ]
    .into_iter();
    assert_eq!(
        wait_with(|| looks.next().unwrap(), far, Duration::from_millis(1)),
        ReadinessWait::Ready(ReadinessSignal::Screen)
    );
    let mut looks = vec![ReadinessObservation::NotYet, ReadinessObservation::Ended].into_iter();
    assert_eq!(
        wait_with(|| looks.next().unwrap(), far, Duration::from_millis(1)),
        ReadinessWait::Exited
    );
}

#[test]
fn the_wait_times_out_when_nothing_says_ready() {
    let started = Instant::now();
    let mut looks = 0;
    let outcome = wait_with(
        || {
            looks += 1;
            ReadinessObservation::NotYet
        },
        started + Duration::from_millis(60),
        Duration::from_millis(10),
    );
    assert_eq!(outcome, ReadinessWait::TimedOut);
    assert!(started.elapsed() >= Duration::from_millis(60));
    assert!(looks >= 2, "the wait keeps polling until the deadline");
    // Evidence present at the deadline still counts.
    assert_eq!(
        wait_with(
            || ReadinessObservation::Ready(ReadinessSignal::Program),
            started,
            Duration::from_millis(10),
        ),
        ReadinessWait::Ready(ReadinessSignal::Program)
    );
}

#[test]
fn an_agent_command_names_a_runtime_that_can_say_it_is_ready() {
    // Hooks (and a declared screen idle prompt) for Claude Code and Codex,
    // however the preset spells the executable.
    for command in [
        "claude",
        "claude --model opus",
        "/usr/local/bin/claude",
        "codex --dangerously-bypass-approvals-and-sandbox",
        "gemini --yolo",
        "cursor-agent --force",
    ] {
        assert!(is_agent_command(command), "{command}");
    }
    // Plain commands, and runtimes whose only lifecycle is output growth,
    // give no readiness signal to wait for.
    for command in ["", "  ", "true", "npm run dev", "sleep 60", "pi", "antigravity"] {
        assert!(!is_agent_command(command), "{command:?}");
    }
}
