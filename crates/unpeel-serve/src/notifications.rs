//! Host-owned lifecycle notification policy with platform delivery adapters.
//!
//! The workspace worker decides *when* a Session needs attention or finished,
//! and which authenticated Controller devices are already viewing it. A live
//! native adapter supplies only the platform effects: macOS Notification
//! Center and the APNs/Link request. Adapter loss never changes Host state.

use std::collections::HashSet;

use serde_json::json;

use crate::platform_adapter::{PlatformAdapterError, PlatformAdapterHub};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotificationKind {
    NeedsInput,
    Done,
    Alert,
}

impl NotificationKind {
    fn wire(self) -> &'static str {
        match self {
            Self::NeedsInput => "needs_input",
            Self::Done => "done",
            Self::Alert => "alert",
        }
    }

    fn default_body(self) -> &'static str {
        match self {
            Self::NeedsInput => "Needs your input",
            Self::Done => "Finished",
            Self::Alert => "Alert",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationRequest<'a> {
    pub session_id: &'a str,
    pub title: &'a str,
    pub kind: NotificationKind,
    pub body: Option<&'a str>,
    /// A finished edge always crosses the adapter. The native preference
    /// store decides whether this opt-in effect is enabled for the Session.
    pub requires_notify_when_done: bool,
    pub send_desktop: bool,
    pub suppress_device_ids: HashSet<String>,
    /// Fork-only: Scheduled Tasks. Set when the notice concerns a Run, of
    /// a Run Session or of a Run with no Session at all (`session_id`
    /// empty: it never launched).
    pub run: Option<RunContext<'a>>,
}

/// Fork-only: which Scheduled Task a notice is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RunContext<'a> {
    pub schedule_id: &'a str,
    /// For a finished turn: the task's "Notify when done", which decides
    /// in place of the app's global setting. Absent on the wire otherwise,
    /// and from older Hosts.
    pub notify_when_done: Option<bool>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeliveryOutcome {
    /// The app's currently visible pane is a platform observation source that
    /// cannot be inferred from Controller transport traffic.
    pub mac_observed: bool,
}

pub fn deliver(adapters: &PlatformAdapterHub, request: NotificationRequest<'_>) -> DeliveryOutcome {
    if !adapters.supports("notification.deliver") {
        return DeliveryOutcome::default();
    }
    let mut suppressed = request.suppress_device_ids.into_iter().collect::<Vec<_>>();
    suppressed.sort();
    let mut body = json!({
        "sessionID": request.session_id,
        "title": request.title,
        "body": request.body.unwrap_or_else(|| request.kind.default_body()),
        "kind": request.kind.wire(),
        "requiresNotifyWhenDone": request.requires_notify_when_done,
        "sendDesktop": request.send_desktop,
        "suppressDeviceIDs": suppressed,
    });
    if let (Some(run), Some(fields)) = (request.run, body.as_object_mut()) {
        // Additive: an app that predates Scheduled Tasks ignores both.
        fields.insert("scheduleID".into(), run.schedule_id.into());
        if let Some(notify) = run.notify_when_done {
            fields.insert("runNotifyWhenDone".into(), notify.into());
        }
    }
    let response = adapters.call("notification.deliver", body);
    match response {
        Ok(response) if response.status == 200 => DeliveryOutcome {
            mac_observed: response
                .body
                .get("macObserved")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
        },
        Ok(response) => {
            crate::tracelog::trace(
                "notification",
                &format!("platform delivery returned status {}", response.status),
            );
            DeliveryOutcome::default()
        }
        Err(PlatformAdapterError::Unavailable) => DeliveryOutcome::default(),
        Err(error) => {
            crate::tracelog::trace(
                "notification",
                &format!("platform delivery failed: {error}"),
            );
            DeliveryOutcome::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::platform_adapter::{PlatformAdapterRegistration, PLATFORM_ADAPTER_VERSION};

    /// Deliver `request` to a one-shot adapter that answers
    /// `macObserved: true`; returns the outcome and the callback envelope.
    fn capture(request: NotificationRequest<'_>) -> (DeliveryOutcome, serde_json::Value) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let captured = Arc::new(Mutex::new(Vec::new()));
        let captured_thread = Arc::clone(&captured);
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut raw = Vec::new();
            let separator = loop {
                let mut chunk = [0u8; 1_024];
                let count = stream.read(&mut chunk).unwrap();
                assert!(count > 0);
                raw.extend_from_slice(&chunk[..count]);
                let Some(separator) = raw.windows(4).position(|part| part == b"\r\n\r\n") else {
                    continue;
                };
                let head = std::str::from_utf8(&raw[..separator]).unwrap();
                let length = head
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .map(str::to_owned)
                    })
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap();
                if raw.len() >= separator + 4 + length {
                    break separator;
                }
            };
            *captured_thread.lock().unwrap() = raw[separator + 4..].to_vec();
            let body = br#"{"ok":true,"macObserved":true}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            stream.write_all(body).unwrap();
        });
        let hub = PlatformAdapterHub::default();
        hub.register(
            1,
            PlatformAdapterRegistration {
                version: PLATFORM_ADAPTER_VERSION,
                instance_id: "native-test".into(),
                callback_port: port,
                callback_token: "0123456789abcdef0123456789abcdef".into(),
                capabilities: vec!["notification.deliver".into()],
            },
        )
        .unwrap();

        let outcome = deliver(&hub, request);
        server.join().unwrap();
        let envelope = serde_json::from_slice(&captured.lock().unwrap()).unwrap();
        (outcome, envelope)
    }

    fn session_request(kind: NotificationKind) -> NotificationRequest<'static> {
        NotificationRequest {
            session_id: "session-1",
            title: "Research",
            kind,
            body: None,
            requires_notify_when_done: kind == NotificationKind::Done,
            send_desktop: true,
            suppress_device_ids: HashSet::new(),
            run: None,
        }
    }

    #[test]
    fn delivery_is_bounded_sorted_and_returns_mac_observation() {
        let (outcome, envelope) = capture(NotificationRequest {
            suppress_device_ids: HashSet::from(["z-phone".into(), "a-phone".into()]),
            ..session_request(NotificationKind::Done)
        });
        assert!(outcome.mac_observed);
        assert_eq!(envelope["operation"], "notification.deliver");
        assert_eq!(envelope["request"]["body"], "Finished");
        assert_eq!(
            envelope["request"]["suppressDeviceIDs"],
            json!(["a-phone", "z-phone"])
        );
    }

    #[test]
    fn an_ordinary_session_says_nothing_about_scheduled_tasks() {
        let (_, envelope) = capture(session_request(NotificationKind::Done));
        let request = envelope["request"].as_object().unwrap();
        assert!(!request.contains_key("scheduleID"), "{request:?}");
        assert!(!request.contains_key("runNotifyWhenDone"), "{request:?}");
    }

    #[test]
    fn a_run_names_its_task_and_carries_the_tasks_notify_when_done() {
        for notify in [true, false] {
            let (_, envelope) = capture(NotificationRequest {
                run: Some(RunContext {
                    schedule_id: "sch_1",
                    notify_when_done: Some(notify),
                }),
                ..session_request(NotificationKind::Done)
            });
            assert_eq!(envelope["request"]["scheduleID"], "sch_1");
            assert_eq!(envelope["request"]["runNotifyWhenDone"], notify);
            assert_eq!(envelope["request"]["requiresNotifyWhenDone"], true);
        }
    }

    #[test]
    fn a_run_without_a_session_sends_an_empty_session_id() {
        let (_, envelope) = capture(NotificationRequest {
            session_id: "",
            title: "Morning report",
            kind: NotificationKind::Alert,
            body: Some("Failed: the preset ok no longer exists"),
            requires_notify_when_done: false,
            send_desktop: true,
            suppress_device_ids: HashSet::new(),
            run: Some(RunContext {
                schedule_id: "sch_1",
                notify_when_done: None,
            }),
        });
        let request = envelope["request"].as_object().unwrap();
        assert_eq!(request["sessionID"], "");
        assert_eq!(request["scheduleID"], "sch_1");
        assert_eq!(request["kind"], "alert");
        assert_eq!(request["body"], "Failed: the preset ok no longer exists");
        // Only a finished Run's eligibility is the task's to decide.
        assert!(!request.contains_key("runNotifyWhenDone"), "{request:?}");
    }

    #[test]
    fn missing_adapter_is_a_noop_not_a_host_failure() {
        let outcome = deliver(
            &PlatformAdapterHub::default(),
            NotificationRequest {
                session_id: "s",
                title: "Session",
                kind: NotificationKind::NeedsInput,
                body: None,
                requires_notify_when_done: false,
                send_desktop: true,
                suppress_device_ids: HashSet::new(),
                run: None,
            },
        );
        assert_eq!(outcome, DeliveryOutcome::default());
    }
}
