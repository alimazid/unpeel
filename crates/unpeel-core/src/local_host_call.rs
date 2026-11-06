//! Fork-only: one Controller request to this workspace's own Host worker,
//! over its owner-only local socket (`remote_stdio::local_host_socket_path`),
//! in the framed wire every local Controller speaks. The MCP server is a
//! core process: what only the live worker can do (a Scheduled Task write,
//! checked on the Host's clock against its catalog) it asks the worker for
//! here, through the same route the Mac app uses, so there is one writer.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde_json::Value;

use crate::relay_wire::{self, TunnelRequest};
use crate::remote_stdio;

/// How long one request waits for the worker. Its slowest write route
/// (Run now) answers within 5 s or reports that it did not.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(15);

/// `POST path` with a JSON `body` to the worker serving `home`: its status
/// and JSON body. `Err` when no worker answers or the answer is not one.
pub fn post(home: &Path, path: &str, body: &Value) -> Result<(u16, Value), String> {
    let socket = remote_stdio::local_host_socket_path(home);
    let mut stream = UnixStream::connect(&socket)
        .map_err(|error| format!("could not reach this workspace's Host service: {error}"))?;
    stream
        .set_read_timeout(Some(ANSWER_TIMEOUT))
        .and_then(|()| stream.set_write_timeout(Some(ANSWER_TIMEOUT)))
        .map_err(|error| format!("could not configure the Host socket: {error}"))?;
    let request = TunnelRequest {
        // The worker's replay cache keys on the id within this connection's
        // namespace; a fresh one per request never collides (kept under
        // 2^53, so every JSON reader keeps it exact).
        id: uuid::Uuid::new_v4().as_u64_pair().0 >> 11,
        method: "POST".into(),
        path: path.into(),
        query: Vec::new(),
        auth: None,
        content_type: Some("application/json".into()),
        body: serde_json::to_vec(body).map_err(|error| error.to_string())?,
    };
    remote_stdio::write_frame(
        &mut stream,
        remote_stdio::FRAME_KIND_REQUEST,
        &relay_wire::encode_tunnel_request(&request),
    )?;
    let frame = remote_stdio::read_frame(&mut stream)?
        .ok_or("the Host service closed the connection without answering")?;
    if frame.kind != remote_stdio::FRAME_KIND_RESPONSE {
        return Err("the Host service sent an invalid response".into());
    }
    let response = relay_wire::parse_tunnel_response(&frame.payload)?;
    let answer = serde_json::from_slice::<Value>(&response.body)
        .map_err(|_| "the Host service answered with invalid JSON".to_string())?;
    Ok((response.status, answer))
}
