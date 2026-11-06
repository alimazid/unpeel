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

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const ITEM_VERSION: u32 = 1;
const PENDING_DIR: &str = "pending";
const DELIVERED_DIR: &str = "delivered";
const LOCKS_DIR: &str = ".locks";
const MAX_ID_BYTES: usize = 128;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InboxError {
    /// A bad session id, item id or sender.
    Invalid(String),
    /// The store could not be read or written.
    Io(String),
}

impl std::fmt::Display for InboxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InboxError::Invalid(message) | InboxError::Io(message) => f.write_str(message),
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

/// The Inbox store under one root. Tests use `Store::at` against a temp
/// directory; `Store::home` is the real one and the only one that announces
/// on the state bus.
#[derive(Debug, Clone)]
pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn at(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn enqueue(&self, target: &str, new: NewItem, now_ms: u64) -> Result<Enqueued> {
        let dir = self.dir(target)?;
        let new = validated(new)?;
        let _lock = self.lock(target)?;
        let pending = read_items(&dir.join(PENDING_DIR));
        let dedupe_id = new.dedupe_key.as_deref().map(dedupe_item_id);
        if let Some(id) = dedupe_id.as_ref().filter(|id| item_exists(&dir, id)) {
            return Ok(Enqueued {
                item_id: id.clone(),
                pending: pending.len(),
                truncated: false,
                duplicate: true,
            });
        }
        let at = pending
            .iter()
            .map(|item| item.at.saturating_add(1))
            .fold(now_ms, u64::max);
        let id = dedupe_id.unwrap_or_else(|| format!("{at}-{}", short_uuid()));
        let item = InboxItem {
            v: ITEM_VERSION,
            id: id.clone(),
            at,
            body_bytes: new.body.len(),
            truncated_at_enqueue: false,
            sender: new.sender,
            kind: new.kind,
            priority: new.priority,
            about: new.about,
            status: new.status,
            label: new.label,
            summary: new.summary,
            body: new.body,
            dedupe_key: new.dedupe_key,
            delivered_at: None,
        };
        write_item(&dir.join(PENDING_DIR), &item)?;
        Ok(Enqueued {
            item_id: id,
            pending: pending.len() + 1,
            truncated: false,
            duplicate: false,
        })
    }

    pub fn list(&self, session_id: &str) -> Result<Listing> {
        let dir = self.dir(session_id)?;
        let pending = read_items(&dir.join(PENDING_DIR));
        let mut delivered = read_items(&dir.join(DELIVERED_DIR));
        delivered.reverse();
        Ok(Listing {
            pending: pending.iter().map(header).collect(),
            delivered: delivered.iter().map(header).collect(),
        })
    }

    /// The full stored item, pending or delivered: the Spill pointer target.
    pub fn item(&self, session_id: &str, item_id: &str) -> Result<Option<InboxItem>> {
        let dir = self.dir(session_id)?;
        if !valid_id(item_id) {
            return Err(InboxError::Invalid(format!("invalid item id {item_id:?}")));
        }
        Ok([PENDING_DIR, DELIVERED_DIR]
            .iter()
            .find_map(|sub| read_item(&dir.join(sub).join(format!("{item_id}.json")))))
    }

    fn dir(&self, session_id: &str) -> Result<PathBuf> {
        if !valid_id(session_id) {
            return Err(InboxError::Invalid(format!(
                "invalid session id {session_id:?}"
            )));
        }
        Ok(self.root.join(session_id))
    }

    fn lock(&self, session_id: &str) -> Result<crate::app_state::FileLock> {
        use sha2::{Digest, Sha256};
        let locks = self.root.join(LOCKS_DIR);
        fs::create_dir_all(&locks).map_err(|error| io_error(&locks, error))?;
        let target = locks.join(format!("{:x}", Sha256::digest(session_id.as_bytes())));
        crate::app_state::lock_exclusive(&target).map_err(InboxError::Io)
    }
}

/// The reserved sender id for Host notices; no Session may claim it.
pub const HOST_SENDER_ID: &str = "host";

fn validated(new: NewItem) -> Result<NewItem> {
    let dedupe_key = match &new.sender {
        Sender::Session(id) if !valid_id(id) || id.eq_ignore_ascii_case(HOST_SENDER_ID) => {
            return Err(InboxError::Invalid(format!("invalid sender id {id:?}")));
        }
        // Only the Host dedupes: a Session naming the key of a notice the
        // Host sends later would otherwise suppress it.
        Sender::Session(_) => None,
        Sender::Host => new.dedupe_key.filter(|key| !key.is_empty()),
    };
    Ok(NewItem { dedupe_key, ..new })
}

/// `h-<sha256(key)[..16]>`: the same notice always lands in the same file.
fn dedupe_item_id(key: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = format!("{:x}", Sha256::digest(key.as_bytes()));
    format!("h-{}", &digest[..16])
}

fn item_exists(dir: &Path, item_id: &str) -> bool {
    [PENDING_DIR, DELIVERED_DIR]
        .iter()
        .any(|sub| dir.join(sub).join(format!("{item_id}.json")).exists())
}

/// Session and item ids become path components: one plain name, never a
/// dot file, a separator or a parent reference.
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_BYTES
        && !id.starts_with('.')
        && !id.contains("..")
        && !id
            .chars()
            .any(|c| matches!(c, '/' | '\\') || c.is_control())
}

fn short_uuid() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_owned()
}

fn header(item: &InboxItem) -> ItemHeader {
    ItemHeader {
        id: item.id.clone(),
        at: item.at,
        sender: item.sender.clone(),
        kind: item.kind,
        priority: item.priority,
        about: item.about.clone(),
        status: item.status.clone(),
        label: item.label.clone(),
        summary: item.summary.clone(),
        body_bytes: item.body_bytes,
        truncated_at_enqueue: item.truncated_at_enqueue,
        delivered_at: item.delivered_at,
    }
}

/// Every item in one of the item directories, oldest first: pending by
/// `(at, id)`, delivered by `(delivered_at, id)`. Temp files and anything
/// unreadable are skipped.
fn read_items(dir: &Path) -> Vec<InboxItem> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items: Vec<InboxItem> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !name.ends_with(".json") {
                return None;
            }
            read_item(&entry.path())
        })
        .collect();
    items.sort_by(|a, b| {
        (a.delivered_at.unwrap_or(a.at), &a.id).cmp(&(b.delivered_at.unwrap_or(b.at), &b.id))
    });
    items
}

/// One item; its id is always the file stem, whatever the content says.
fn read_item(path: &Path) -> Option<InboxItem> {
    let raw = fs::read(path).ok()?;
    let stem = path.file_stem()?.to_string_lossy().into_owned();
    match serde_json::from_slice::<InboxItem>(&raw) {
        Ok(item) => Some(InboxItem { id: stem, ..item }),
        Err(error) => {
            log::warn!("skipping unreadable inbox item {}: {error}", path.display());
            None
        }
    }
}

/// Durable once it returns: temp file, fsync, rename, then a best-effort
/// fsync of the directory so the rename itself survives a crash.
fn write_item(dir: &Path, item: &InboxItem) -> Result<()> {
    let bytes = serde_json::to_vec(item).map_err(|error| InboxError::Io(error.to_string()))?;
    fs::create_dir_all(dir).map_err(|error| io_error(dir, error))?;
    let tmp = dir.join(format!(".tmp-{}", short_uuid()));
    let written = fs::File::create(&tmp)
        .and_then(|mut file| file.write_all(&bytes).and_then(|()| file.sync_all()))
        .and_then(|()| fs::rename(&tmp, dir.join(format!("{}.json", item.id))));
    if let Err(error) = written {
        let _ = fs::remove_file(&tmp);
        return Err(io_error(dir, error));
    }
    if let Ok(handle) = fs::File::open(dir) {
        let _ = handle.sync_all();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::at(dir.path().join("session-inboxes"));
        (dir, store)
    }

    fn report(from: &str, summary: &str) -> NewItem {
        NewItem {
            sender: Sender::Session(from.into()),
            kind: ItemKind::Report,
            priority: Priority::Wake,
            about: None,
            status: Some("done".into()),
            label: Some("fix-login".into()),
            summary: summary.into(),
            body: format!("details of {summary}"),
            dedupe_key: None,
        }
    }

    #[test]
    fn an_enqueued_report_is_listed_pending_and_readable_in_full() {
        let (_tmp, store) = store();
        let queued = store
            .enqueue("router", report("w1", "login fixed"), 1_000)
            .unwrap();
        assert_eq!(queued.pending, 1);
        assert!(!queued.duplicate && !queued.truncated);

        let listing = store.list("router").unwrap();
        assert_eq!(listing.pending.len(), 1);
        let header = &listing.pending[0];
        assert_eq!(header.id, queued.item_id);
        assert_eq!(header.sender, Sender::Session("w1".into()));
        assert_eq!(header.kind, ItemKind::Report);
        assert_eq!(header.status.as_deref(), Some("done"));
        assert_eq!(header.label.as_deref(), Some("fix-login"));
        assert_eq!(header.summary, "login fixed");
        assert!(listing.delivered.is_empty());

        let item = store.item("router", &queued.item_id).unwrap().unwrap();
        assert_eq!(item.body, "details of login fixed");
        assert_eq!(item.at, 1_000);
        // Stored where the spec puts it: one JSON file per item.
        assert!(store
            .root
            .join("router/pending")
            .join(format!("{}.json", queued.item_id))
            .is_file());
    }

    fn pending_summaries(store: &Store, id: &str) -> Vec<String> {
        store
            .list(id)
            .unwrap()
            .pending
            .into_iter()
            .map(|header| header.summary)
            .collect()
    }

    #[test]
    fn items_stay_fifo_even_within_one_millisecond() {
        let (_tmp, store) = store();
        for n in 0..12 {
            store
                .enqueue("router", report("w1", &format!("r{n}")), 5_000)
                .unwrap();
        }
        let expected: Vec<String> = (0..12).map(|n| format!("r{n}")).collect();
        assert_eq!(pending_summaries(&store, "router"), expected);
    }

    #[test]
    fn concurrent_enqueues_lose_nothing() {
        let (_tmp, store) = store();
        let workers: Vec<_> = (0..4)
            .map(|worker| {
                let store = store.clone();
                std::thread::spawn(move || {
                    for round in 0..10 {
                        store
                            .enqueue("router", report("w1", &format!("w{worker}-{round}")), 7)
                            .unwrap();
                    }
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        let summaries = pending_summaries(&store, "router");
        assert_eq!(summaries.len(), 40, "an enqueue was lost: {summaries:?}");
        // Each writer's own items keep their order.
        for worker in 0..4 {
            let mine: Vec<&String> = summaries
                .iter()
                .filter(|s| s.starts_with(&format!("w{worker}-")))
                .collect();
            let expected: Vec<String> = (0..10).map(|r| format!("w{worker}-{r}")).collect();
            assert_eq!(mine, expected.iter().collect::<Vec<_>>());
        }
    }

    fn host_notice(about: &str, event: &str, key: Option<&str>) -> NewItem {
        NewItem {
            sender: Sender::Host,
            kind: ItemKind::Lifecycle,
            priority: Priority::Wake,
            about: Some(about.into()),
            status: Some(event.into()),
            label: None,
            summary: format!("{about} {event}"),
            body: String::new(),
            dedupe_key: key.map(str::to_owned),
        }
    }

    #[test]
    fn a_host_notice_with_a_dedupe_key_is_written_once() {
        let (_tmp, store) = store();
        let first = store
            .enqueue("router", host_notice("w1", "exited", Some("exit:w1:42")), 1)
            .unwrap();
        assert!(first.item_id.starts_with("h-") && first.item_id.len() == 18);
        assert!(!first.duplicate);
        let again = store
            .enqueue("router", host_notice("w1", "exited", Some("exit:w1:42")), 2)
            .unwrap();
        assert!(again.duplicate);
        assert_eq!(again.item_id, first.item_id);
        assert_eq!(again.pending, 1);
        assert_eq!(pending_summaries(&store, "router").len(), 1);
        // A different key is a different notice.
        store
            .enqueue("router", host_notice("w1", "exited", Some("exit:w1:43")), 3)
            .unwrap();
        assert_eq!(pending_summaries(&store, "router").len(), 2);
    }

    #[test]
    fn a_session_can_neither_speak_as_the_host_nor_claim_a_host_dedupe_key() {
        let (_tmp, store) = store();
        for forged in ["host", "HOST", "Host"] {
            let error = store
                .enqueue("router", report(forged, "hi"), 1)
                .expect_err("id:host is reserved");
            assert!(matches!(error, InboxError::Invalid(_)), "{error:?}");
        }
        for bad in ["", "../x", "a/b", ".hidden"] {
            assert!(store.enqueue(bad, report("w1", "x"), 1).is_err(), "{bad:?}");
            assert!(
                store.enqueue("router", report(bad, "x"), 1).is_err(),
                "{bad:?}"
            );
        }
        // A Worker naming the key of a notice the Host will send later must
        // not pre-empt it: Session items ignore dedupe keys.
        let mut sneaky = report("w1", "pre-empt");
        sneaky.dedupe_key = Some("exit:w2:9".into());
        let queued = store.enqueue("router", sneaky.clone(), 1).unwrap();
        assert!(!queued.item_id.starts_with("h-"));
        assert!(!store.enqueue("router", sneaky, 2).unwrap().duplicate);
        let host = store
            .enqueue("router", host_notice("w2", "exited", Some("exit:w2:9")), 3)
            .unwrap();
        assert!(!host.duplicate);
        assert_eq!(pending_summaries(&store, "router").len(), 3);
    }
}
