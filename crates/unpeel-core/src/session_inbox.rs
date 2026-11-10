//! Fork-only: the durable per-session Inbox
//! (`<UNPEEL_HOME>/session-inboxes/<session_id>/`).
//!
//! Workers' reports and the Host's notices queue here while their target is
//! busy, and go out together as one bracketed paste once it is idle; the
//! supervisor decides when, this module only stores, claims and renders.
//! The store sits beside `app-sessions/`, never inside a session directory:
//! Resume and Reload tear that directory down, which would destroy a
//! Router's queue at exactly the moment it is recovered.
//!
//! Layout per session: `pending/<id>.json` (one item per file, FIFO by
//! `(at, id)`), `delivered/` (recent history, so `item_id` reads keep
//! working), and `inflight.json` (the current claim). Every
//! read-modify-write holds an exclusive flock on
//! `.locks/<sha256(session_id)>.lock`, kept outside the per-session
//! directory so a transfer or removal never renames or unlinks a lock file
//! another process is waiting on.
//!
//! `store.rs` holds the [`Store`] and its files, `validation.rs` what an
//! enqueue may store, `render.rs` the paste. A `Store` never announces on
//! the state bus itself: its real-home callers do, after a write, so tests
//! against `Store::at` never ping this machine's registry.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const ITEM_VERSION: u32 = 1;
const PENDING_DIR: &str = "pending";
const DELIVERED_DIR: &str = "delivered";
const LOCKS_DIR: &str = ".locks";
const INFLIGHT_FILE: &str = "inflight.json";
const MISSING_SINCE_FILE: &str = "missing-since";
const HOLD_FILE: &str = "hold.json";
const ROUTER_TOUCH_FILE: &str = "router-touch";
const MAX_ID_BYTES: usize = 128;

/// Stored text per item (summary + body); the rest is cut at enqueue.
pub const MAX_STORED_ITEM_BYTES: usize = 64 * 1024;
pub const MAX_SUMMARY_CHARS: usize = 1_000;
pub const MAX_LABEL_CHARS: usize = 80;
const MAX_STATUS_CHARS: usize = 32;
/// Pending caps: past either, reports get "inbox full".
pub const MAX_PENDING_ITEMS: usize = 200;
pub const MAX_PENDING_BYTES: u64 = 2 * 1024 * 1024;
/// Delivered history, so `item_id` reads keep working after a paste.
pub const DELIVERED_KEEP_ITEMS: usize = 200;
pub const DELIVERED_KEEP_MS: u64 = 24 * 60 * 60 * 1000;
/// Deliveries `list` shows.
pub const LIST_DELIVERED: usize = 20;
/// How long a session may have no manifest before GC removes its Inbox.
pub const GC_GRACE_MS: u64 = 10 * 60 * 1000;

/// Who queued an item. `Host` is reachable only from Host code; an MCP
/// enqueue only ever names the calling Session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Sender {
    Session(String),
    Host,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Report,
    Message,
    Task,
    Lifecycle,
    Watchdog,
    Handover,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ItemKind::Report => "report",
            ItemKind::Message => "message",
            ItemKind::Task => "task",
            ItemKind::Lifecycle => "lifecycle",
            ItemKind::Watchdog => "watchdog",
            ItemKind::Handover => "handover",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Wake,
    RideAlong,
}

#[derive(Debug, Clone)]
pub struct NewItem {
    pub sender: Sender,
    pub kind: ItemKind,
    pub priority: Priority,
    pub about: Option<String>,
    pub status: Option<String>,
    pub label: Option<String>,
    pub summary: String,
    pub body: String,
    pub dedupe_key: Option<String>,
}

/// One stored item, as written to `pending/<id>.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxItem {
    pub v: u32,
    /// The file stem; the `item_id` the pull API and Spill pointers use.
    pub id: String,
    /// Enqueue time in unix ms, strictly increasing within one Inbox.
    pub at: u64,
    pub sender: Sender,
    pub kind: ItemKind,
    pub priority: Priority,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub summary: String,
    pub body: String,
    /// The body's size as sent, before any truncation.
    pub body_bytes: usize,
    pub truncated_at_enqueue: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dedupe_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivered_at: Option<u64>,
}

/// What an enqueue did, for the sender's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Enqueued {
    pub item_id: String,
    /// Pending items after this enqueue.
    pub pending: usize,
    /// The stored text was cut to the item cap; the sender is told.
    pub truncated: bool,
    /// Already pending or delivered under the same dedupe key; nothing new
    /// was written.
    pub duplicate: bool,
    /// Older Host notices about the same child dropped to make room.
    pub replaced: Vec<String>,
}

/// An item as the pull API lists it: everything but the body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ItemHeader {
    pub id: String,
    pub at: u64,
    pub sender: Sender,
    pub kind: ItemKind,
    pub priority: Priority,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub about: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub summary: String,
    pub body_bytes: usize,
    pub truncated_at_enqueue: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivered_at: Option<u64>,
}

/// `sessions inbox` with no parameters: pending headers (FIFO) and recent
/// deliveries (newest first).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Listing {
    pub pending: Vec<ItemHeader>,
    pub delivered: Vec<ItemHeader>,
}

/// What is pending, for the supervisor's delivery gates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PendingStats {
    pub items: usize,
    /// At least one wake item. Only those start a delivery, until the drain
    /// promotes ride-along items by `oldest_at` (#83).
    pub wake: bool,
    pub oldest_at: Option<u64>,
    /// When the oldest wake item was queued: with `oldest_at`, when a
    /// delivery became due, for the Host's health check (#84).
    pub oldest_wake_at: Option<u64>,
    pub newest_at: Option<u64>,
}

/// `hold.json`: why the supervisor is not pasting this Inbox right now
/// (`busy`, `no_agent_authority`, …), for `sessions inbox` and `report`
/// results in other processes. Edge-written by the Host worker only while
/// items are pending.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hold {
    pub reason: String,
    /// Unix ms the supervisor first held for this reason.
    pub since: u64,
}

/// Everything pending at claim time, pasted as one: wake and ride-along
/// items alike, FIFO.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub session_id: String,
    pub batch_id: String,
    /// 1 on the first paste; higher means this batch was claimed before and
    /// never completed, so it may already have reached the target.
    pub attempt: u32,
    pub items: Vec<InboxItem>,
}

impl Batch {
    pub fn redelivery(&self) -> bool {
        self.attempt > 1
    }
}

/// `inflight.json`: the claim a paste is working from.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Claim {
    batch_id: String,
    item_ids: Vec<String>,
    claimed_at: u64,
    attempt: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InboxError {
    /// The pending caps are reached ("inbox full").
    Full(String),
    /// A bad session id, item id or sender.
    Invalid(String),
    /// The store could not be read or written.
    Io(String),
}

impl std::fmt::Display for InboxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InboxError::Full(message) | InboxError::Invalid(message) | InboxError::Io(message) => {
                f.write_str(message)
            }
        }
    }
}

impl From<InboxError> for String {
    fn from(error: InboxError) -> Self {
        error.to_string()
    }
}

type Result<T> = std::result::Result<T, InboxError>;

fn io_error(context: &Path, error: std::io::Error) -> InboxError {
    InboxError::Io(format!("{}: {error}", context.display()))
}

/// `<UNPEEL_HOME>/session-inboxes`, a sibling of `app-sessions/`.
pub fn inboxes_root() -> PathBuf {
    crate::app_paths::unpeel_home().join("session-inboxes")
}

mod render;
mod store;
mod validation;

pub use render::{render_batch, MAX_BATCH_PASTE_CHARS, MAX_DIGESTS, MAX_ITEM_PASTE_CHARS};
pub use store::Store;
use validation::header_text;

/// The reserved sender id for Host notices; no Session may claim it.
pub const HOST_SENDER_ID: &str = "host";

#[cfg(test)]
mod tests;
