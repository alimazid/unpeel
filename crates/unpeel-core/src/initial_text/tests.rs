use super::*;

fn marker(dir: &Path) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(dir.join(OUTCOME_MARKER)).expect("marker written"))
        .expect("marker json")
}

#[test]
fn every_outcome_is_recorded_for_the_caller_to_observe() {
    let cases = [
        (
            InitialTextWhen::AgentReady,
            InitialTextOutcome::Delivered {
                signal: Some(ReadinessSignal::Screen),
            },
            "delivered",
            Some("screen"),
        ),
        (
            InitialTextWhen::Attached,
            InitialTextOutcome::Delivered { signal: None },
            "delivered",
            None,
        ),
        (
            InitialTextWhen::AgentReady,
            InitialTextOutcome::ReadinessTimeout,
            "readiness_timeout",
            None,
        ),
        (
            InitialTextWhen::AgentReady,
            InitialTextOutcome::Exited,
            "exited",
            None,
        ),
        (
            InitialTextWhen::Attached,
            InitialTextOutcome::HostNotReady("Timed out waiting for session host".into()),
            "host_not_ready",
            None,
        ),
        (
            InitialTextWhen::AgentReady,
            InitialTextOutcome::DeliveryFailed("socket closed".into()),
            "delivery_failed",
            None,
        ),
    ];
    for (when, outcome, state, signal) in cases {
        let dir = tempfile::tempdir().expect("tempdir");
        record_in(dir.path(), when, Some(&outcome), 1234).expect("record");
        let recorded = marker(dir.path());
        assert_eq!(recorded["state"], state, "{outcome:?}");
        assert_eq!(recorded["when"], when.as_str());
        assert_eq!(recorded["signal"].as_str(), signal, "{outcome:?}");
        assert_eq!(recorded["at"], 1234);
        assert_eq!(recorded.get("error").is_some(), outcome.error().is_some());
    }
}

#[test]
fn a_pending_wait_is_recorded_as_waiting() {
    let dir = tempfile::tempdir().expect("tempdir");
    record_in(dir.path(), InitialTextWhen::AgentReady, None, 99).expect("record");
    let recorded = marker(dir.path());
    assert_eq!(recorded["state"], "waiting");
    assert_eq!(recorded["when"], "agent_ready");
}

#[test]
fn recording_never_creates_a_removed_session_directory() {
    let dir = tempfile::tempdir().expect("tempdir");
    let gone = dir.path().join("removed-session");
    assert!(record_in(
        &gone,
        InitialTextWhen::AgentReady,
        Some(&InitialTextOutcome::ReadinessTimeout),
        1
    )
    .is_err());
    assert!(!gone.exists());
}

#[test]
fn only_a_delivery_counts_as_typed() {
    assert!(InitialTextOutcome::Delivered { signal: None }.typed());
    for outcome in [
        InitialTextOutcome::ReadinessTimeout,
        InitialTextOutcome::Exited,
        InitialTextOutcome::HostNotReady(String::new()),
        InitialTextOutcome::DeliveryFailed(String::new()),
    ] {
        assert!(!outcome.typed(), "{outcome:?}");
    }
}

#[test]
fn text_over_the_cap_is_refused_before_touching_the_session() {
    let text = "x".repeat(MAX_INITIAL_TEXT_BYTES + 1);
    let outcome = deliver(
        "no-such-session-for-cap-test",
        &text,
        InitialTextSubmitMode::PasteAndSubmit,
        InitialTextWhen::AgentReady,
    );
    assert_eq!(
        outcome,
        InitialTextOutcome::DeliveryFailed("initial text too large".into())
    );
}

#[test]
fn a_prompt_over_the_cap_is_refused_before_touching_the_session() {
    let prompt = "x".repeat(MAX_INITIAL_TEXT_BYTES + 1);
    let (outcome, typed_at) = prompt_when_ready("no-such-session-for-cap-test", &prompt);
    assert_eq!(
        outcome,
        InitialTextOutcome::DeliveryFailed("initial text too large".into())
    );
    assert_eq!(typed_at, None);
}

#[test]
fn the_ready_timeout_is_two_minutes_unless_a_test_host_shortens_it() {
    assert_eq!(
        agent_ready_timeout_from(None, None),
        Duration::from_secs(120)
    );
    assert_eq!(
        agent_ready_timeout_from(None, Some("5000")),
        Duration::from_secs(120),
        "production Hosts ignore the override"
    );
    assert_eq!(
        agent_ready_timeout_from(Some("1"), Some("5000")),
        Duration::from_millis(5000)
    );
    assert_eq!(
        agent_ready_timeout_from(Some("1"), Some("soon")),
        Duration::from_secs(120)
    );
}
