// Shared fixtures for the hook-reporter conformance tests; included by
// `unpeel_core::hook_assets::test_support` (test builds only).

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

pub(crate) struct CaptureServer {
    pub(crate) port: u16,
    pub(crate) events: Arc<Mutex<Vec<Value>>>,
    pub(crate) stop: Arc<AtomicBool>,
    pub(crate) handle: Option<thread::JoinHandle<()>>,
}

impl CaptureServer {
    pub(crate) fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind capture server");
        listener
            .set_nonblocking(true)
            .expect("set capture server nonblocking");
        let port = listener.local_addr().expect("capture addr").port();
        let events = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let events_for_thread = Arc::clone(&events);
        let stop_for_thread = Arc::clone(&stop);
        let handle = thread::spawn(move || {
            while !stop_for_thread.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        // BSD/macOS accepted sockets inherit the
                        // listener's O_NONBLOCK; a non-blocking read here
                        // races the request body and drops the post.
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                        let mut reader = BufReader::new(&stream);
                        let mut request_line = String::new();
                        if reader.read_line(&mut request_line).is_err() {
                            continue;
                        }

                        let mut content_length = 0usize;
                        loop {
                            let mut line = String::new();
                            if reader.read_line(&mut line).is_err() || line.trim().is_empty() {
                                break;
                            }
                            if let Some(value) = line
                                .to_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().to_string())
                            {
                                content_length = value.parse().unwrap_or(0);
                            }
                        }

                        let mut body = vec![0u8; content_length];
                        if content_length > 0 && reader.read_exact(&mut body).is_err() {
                            continue;
                        }
                        if let Ok(value) = serde_json::from_slice::<Value>(&body) {
                            events_for_thread.lock().unwrap().push(value);
                        }

                        let _ = write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{{\"ok\":true}}"
                        );
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(25));
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            port,
            events,
            stop,
            handle: Some(handle),
        }
    }

    pub(crate) fn wait_for_event(&self, expected: &str, timeout: Duration) -> bool {
        self.wait_for_event_payload(expected, timeout).is_some()
    }

    pub(crate) fn wait_for_event_payload(&self, expected: &str, timeout: Duration) -> Option<Value> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Some(event) = self.events.lock().unwrap().iter().find(|value| {
                value
                    .get("hook_event_name")
                    .and_then(|field| field.as_str())
                    == Some(expected)
            }) {
                return Some(event.clone());
            }
            thread::sleep(Duration::from_millis(50));
        }
        None
    }

    pub(crate) fn event_names(&self) -> Vec<String> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter_map(|value| {
                value
                    .get("hook_event_name")
                    .and_then(|field| field.as_str())
                    .map(ToString::to_string)
            })
            .collect()
    }

    pub(crate) fn events_snapshot(&self) -> Vec<Value> {
        self.events.lock().unwrap().clone()
    }
}

impl Drop for CaptureServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = std::net::TcpStream::connect(("127.0.0.1", self.port));
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

pub(crate) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("repo root")
        .to_path_buf()
}

pub(crate) fn temp_path(label: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "unpeel-live-cli-{}-{}-{}",
        label,
        std::process::id(),
        crate::state::current_timestamp_ms()
    ));
    fs::create_dir_all(&root).expect("create temp dir");
    root
}

pub(crate) fn write_temp_hook_script(label: &str, script: &str) -> PathBuf {
    let root = temp_path(label);
    let path = root.join(format!("{label}.sh"));
    super::write_executable_script(&path, script, label).expect("write hook script");
    path
}

pub(crate) fn write_temp_codex_notify_hook(label: &str) -> PathBuf {
    let root = temp_path(label);
    let transport_path = root.join("notify-transport.sh");
    super::write_executable_script(
        &transport_path,
        super::NOTIFY_HOOK_SCRIPT,
        "generic notify transport",
    )
    .expect("write generic notify transport");
    let normalizer_path = root.join("codex-notify.sh");
    let normalizer = super::CODEX_NOTIFY_NORMALIZER_SCRIPT
        .replace("{{NOTIFY_PATH}}", transport_path.to_string_lossy().as_ref());
    super::write_executable_script(&normalizer_path, &normalizer, "Codex notify normalizer")
        .expect("write Codex notify normalizer");
    normalizer_path
}

pub(crate) fn hook_env_home(label: &str) -> PathBuf {
    temp_path(&format!("{label}-home"))
}

pub(crate) fn hook_trace_file(label: &str) -> PathBuf {
    temp_path(&format!("{label}-trace")).join("trace.log")
}

pub(crate) fn run_hook_script_with_stdin(
    script: &PathBuf,
    args: &[&str],
    input: &str,
    capture: &CaptureServer,
    label: &str,
) -> std::process::Output {
    let mut command = Command::new("bash");
    command
        .arg(script)
        .args(args)
        .env("HOME", hook_env_home(label))
        .env("UNPEEL_APP_PORT", capture.port.to_string())
        .env("UNPEEL_SESSION_ID", "unpeel-route-session")
        .env("UNPEEL_RUNTIME_GENERATION", "7")
        .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file(label))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn hook script");
    child
        .stdin
        .take()
        .expect("hook stdin")
        .write_all(input.as_bytes())
        .expect("write hook stdin");
    child.wait_with_output().expect("wait for hook script")
}

pub(crate) fn run_with_timeout(mut command: Command, timeout: Duration) -> Result<ExitStatus, String> {
    let mut child = command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;

    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("command timed out".to_string());
                }
                thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(format!("try_wait failed: {e}")),
        }
    }
}

pub(crate) fn real_command_path(name: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;

                std::fs::metadata(candidate)
                    .map(|metadata| {
                        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
                    })
                    .unwrap_or(false)
            }

            #[cfg(not(unix))]
            {
                candidate.is_file()
            }
        })
        .map(|path| path.to_string_lossy().to_string())
}

pub(crate) fn run_hook_script_recording(
    script_src: &str,
    label: &str,
    args: &[&str],
    input: &str,
    session_dir: &Path,
) -> std::process::Output {
    let script = write_temp_hook_script(label, script_src);
    run_hook_path_recording(&script, label, args, input, session_dir)
}

pub(crate) fn run_hook_path_recording(
    script: &Path,
    label: &str,
    args: &[&str],
    input: &str,
    session_dir: &Path,
) -> std::process::Output {
    let mut command = Command::new("bash");
    command
        .arg(script)
        .args(args)
        .env("HOME", hook_env_home(label))
        .env("UNPEEL_SESSION_ID", "unpeel-record-session")
        .env("UNPEEL_SESSION_DIR", session_dir)
        .env("UNPEEL_RUNTIME_GENERATION", "7")
        .env("UNPEEL_HOOK_TRACE_FILE", hook_trace_file(label))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn hook script");
    child
        .stdin
        .take()
        .expect("hook stdin")
        .write_all(input.as_bytes())
        .expect("write hook stdin");
    child.wait_with_output().expect("wait for hook script")
}

pub(crate) fn read_last_hook_event(session_dir: &Path) -> Value {
    let raw = fs::read_to_string(session_dir.join("last-hook-event.json"))
        .expect("read last-hook-event.json");
    serde_json::from_str(&raw).expect("parse last-hook-event.json")
}

pub(crate) struct ReporterCase {
    pub(crate) label: &'static str,
    pub(crate) script: &'static str,
    pub(crate) args: &'static [&'static str],
    pub(crate) input: &'static str,
}

pub(crate) fn reporter_cases() -> [ReporterCase; 11] {
    [
        ReporterCase {
            label: "claude-generation",
            script: super::CLAUDE_HOOK_SCRIPT,
            args: &[],
            input: r#"{"hook_event_name":"Stop"}"#,
        },
        ReporterCase {
            label: "notify-generation",
            script: super::NOTIFY_HOOK_SCRIPT,
            args: &[r#"{"hook_event_name":"Stop"}"#],
            input: "",
        },
        ReporterCase {
            label: "gemini-generation",
            script: super::GEMINI_HOOK_SCRIPT,
            args: &[],
            input: r#"{"hook_event_name":"AfterAgent"}"#,
        },
        ReporterCase {
            label: "kimi-generation",
            script: super::KIMI_HOOK_SCRIPT,
            args: &["Stop"],
            input: "{}",
        },
        ReporterCase {
            label: "kiro-generation",
            script: super::KIRO_HOOK_SCRIPT,
            args: &["Stop"],
            input: "{}",
        },
        ReporterCase {
            label: "cline-generation",
            script: super::CLINE_HOOK_SCRIPT,
            args: &["TaskComplete", "{}"],
            input: "",
        },
        ReporterCase {
            label: "copilot-generation",
            script: super::COPILOT_HOOK_SCRIPT,
            args: &["sessionEnd"],
            input: "{}",
        },
        ReporterCase {
            label: "cursor-generation",
            script: super::CURSOR_HOOK_SCRIPT,
            args: &["Stop"],
            input: "{}",
        },
        ReporterCase {
            label: "grok-generation",
            script: super::GROK_HOOK_SCRIPT,
            args: &["Stop"],
            input: "{}",
        },
        ReporterCase {
            label: "muse-generation",
            script: super::MUSE_HOOK_SCRIPT,
            args: &[],
            input: r#"{"hook_event_name":"Stop"}"#,
        },
        ReporterCase {
            label: "codewhale-generation",
            script: super::CODEWHALE_HOOK_SCRIPT,
            args: &["TurnEnd"],
            input: r#"{"event":"turn_end","model_backed":true,"status":"completed"}"#,
        },
    ]
}
