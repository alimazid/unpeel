//! Provider-neutral gate behind every persistent MCP registration.
//!
//! Each installed integration registers the same stable shim
//! (`integrations::install::mcp_shim_path`), which starts this gate. The gate
//! resolves the calling Session (`session_identity`: the exported
//! `UNPEEL_SESSION_ID` once process ancestry backs it, or the Session
//! ancestor for launchers that strip their MCP children's environment) and
//! reads that Session's manifest grants to
//! decide which domains the unified server advertises. Outside a granted
//! hosted Session — a plain terminal, an agent started elsewhere — the
//! endpoint stays valid and serves no tools, so a global registration never
//! surprises the user. The grant environment variables remain readable for
//! configurations older builds wrote.

use serde_json::{json, Value};
use std::io::{BufRead, Write};

pub const MCP_GATE_ARG: &str = "__mcp_gate__";
pub const SESSIONS_KIND: &str = "sessions";
pub const BROWSER_KIND: &str = "browser";
pub const COMPUTER_KIND: &str = "computer";
/// The unified server behind one gate entry: enabled when *any* domain grant
/// is present; the registration mask and Session manifest must both grant a
/// domain before the server advertises it. Replaces per-domain entries in new
/// installs.
pub const UNIFIED_KIND: &str = "unified";

pub const SESSIONS_ENABLED_ENV: &str = "UNPEEL_SESSIONS_MCP_ENABLED";
pub const BROWSER_ENABLED_ENV: &str = "UNPEEL_BROWSER_MCP_ENABLED";
pub const COMPUTER_ENABLED_ENV: &str = "UNPEEL_COMPUTER_MCP_ENABLED";
const PROTOCOL_VERSION_FALLBACK: &str = "2025-06-18";
/// How long a gate that starts while its Session is still launching waits
/// for the Host to record the Session's pid before it decides.
const LAUNCH_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

pub fn run_stdio(kind: &str) -> Result<(), String> {
    // The gate decides once, at startup, whether to serve tools; a Session
    // still in its launch window has no pid to check yet, so ask until it
    // does rather than settle on "unknown" for the gate's whole life.
    let caller = crate::session_identity::current_waiting(LAUNCH_WAIT)
        .session_id()
        .map(str::to_owned);
    // The calling Session's manifest is the authority for a shim-based
    // registration. The generic environment grants remain honored for
    // configurations older builds scoped around a launch.
    let manifest = caller
        .as_deref()
        .and_then(crate::session_host::load_manifest);
    let manifest_sessions = manifest
        .as_ref()
        .is_some_and(|manifest| manifest.sessions_mcp_enabled());
    let manifest_browser = manifest
        .as_ref()
        .is_some_and(|manifest| manifest.browser_mcp_enabled());
    let sessions_granted = manifest_sessions || env_grant(SESSIONS_ENABLED_ENV);
    let browser_granted = manifest_browser || env_grant(BROWSER_ENABLED_ENV);
    let unified_domains = crate::mcp_host::McpDomainMask {
        sessions: sessions_granted,
        agents: sessions_granted,
        workspace: sessions_granted,
        artifacts: sessions_granted,
        browser: browser_granted,
        computer: false,
        // Apps discovery rides any granted domain: it is read-only manifest
        // discovery, present by default wherever the unified server is live.
        apps: sessions_granted || browser_granted,
        skills: sessions_granted || browser_granted,
    };
    let (granted, server_name) = match kind {
        UNIFIED_KIND => (sessions_granted || browser_granted, "unpeel"),
        SESSIONS_KIND => (sessions_granted, "unpeel-sessions"),
        BROWSER_KIND => (browser_granted, "unpeel-browser"),
        _ => return Err(format!("Unknown gated MCP kind: {kind}")),
    };

    let enabled = granted && caller.is_some();
    if enabled {
        return match kind {
            UNIFIED_KIND => crate::mcp_host::run_stdio_with_domains(unified_domains),
            // The sessions kind delegates to the same unified server, bounded
            // to that one domain: stale per-domain entries keep working after
            // a binary update without inheriting other manifest grants.
            SESSIONS_KIND => {
                crate::mcp_host::run_stdio_with_domains(crate::mcp_host::McpDomainMask {
                    sessions: true,
                    agents: true,
                    workspace: true,
                    artifacts: true,
                    browser: false,
                    computer: false,
                    apps: false,
                    skills: false,
                })
            }
            BROWSER_KIND => crate::browser_mcp::run_stdio(),
            _ => unreachable!(),
        };
    }

    run_empty_stdio(server_name)
}

fn env_grant(name: &str) -> bool {
    std::env::var(name).ok().as_deref() == Some("1")
}

fn run_empty_stdio(server_name: &str) -> Result<(), String> {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| format!("Failed to read gated MCP stdin: {error}"))?;
        let Ok(message) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let Some(response) = empty_response(server_name, &message) else {
            continue;
        };
        let body = serde_json::to_string(&response)
            .map_err(|error| format!("Failed to encode gated MCP response: {error}"))?;
        let mut out = stdout.lock();
        out.write_all(body.as_bytes())
            .and_then(|_| out.write_all(b"\n"))
            .and_then(|_| out.flush())
            .map_err(|error| format!("Failed to write gated MCP response: {error}"))?;
    }
    Ok(())
}

fn empty_response(server_name: &str, message: &Value) -> Option<Value> {
    let id = match message.get("id") {
        Some(id) if !id.is_null() => id.clone(),
        _ => return None,
    };
    let method = message.get("method").and_then(Value::as_str)?;
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let modern = crate::mcp_host::request_uses_modern_meta(&params) || method == "server/discover";
    if modern {
        if let Err(error) = crate::mcp_host::validate_modern_request_meta(&params) {
            return Some(json!({ "jsonrpc": "2.0", "id": id, "error": error }));
        }
    }
    let result = match method {
        "initialize" if !modern => {
            let protocol_version = message
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or(PROTOCOL_VERSION_FALLBACK);
            json!({
                "protocolVersion": protocol_version,
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": server_name,
                    "version": env!("CARGO_PKG_VERSION"),
                },
            })
        }
        "server/discover" => json!({
            "supportedVersions": [crate::mcp_host::MODERN_PROTOCOL_VERSION],
            "capabilities": { "tools": {} },
            "instructions": "This Unpeel MCP registration is disabled for the current process.",
            "ttlMs": 0,
            "cacheScope": "private",
        }),
        "ping" => json!({}),
        "tools/list" => {
            if modern {
                json!({ "tools": [], "ttlMs": 0, "cacheScope": "private" })
            } else {
                json!({ "tools": [] })
            }
        }
        "tools/call" => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {
                    "code": -32601,
                    "message": "This Unpeel MCP server is not enabled for the current session.",
                },
            }));
        }
        _ => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {
                    "code": -32601,
                    "message": format!("Method not found: {method}"),
                },
            }));
        }
    };
    Some(json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": if modern {
            crate::mcp_host::modern_result_for_server(result, server_name)
        } else {
            result
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_gate_advertises_no_tools() {
        let response = empty_response(
            "unpeel-sessions",
            &json!({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
        )
        .expect("response");
        assert_eq!(response["result"]["tools"], json!([]));
    }

    #[test]
    fn initialize_echoes_the_requested_protocol() {
        let response = empty_response(
            "unpeel-browser",
            &json!({
                "jsonrpc":"2.0",
                "id":"init",
                "method":"initialize",
                "params":{"protocolVersion":"2026-01-01"}
            }),
        )
        .expect("response");
        assert_eq!(response["result"]["protocolVersion"], "2026-01-01");
        assert_eq!(response["result"]["serverInfo"]["name"], "unpeel-browser");
    }
}
