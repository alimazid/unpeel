//! Fork-only: the Inbox store — `Store` and the files under one Inbox
//! directory (items, claim, hold, router-touch).

use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use super::validation::{dedupe_item_id, room_for, short_uuid, stored_item, valid_id, validated};
use super::*;

/// The Inbox store under one root: `Store::home` for the real one,
/// `Store::at` for a temp directory in tests. Times are passed in so tests
/// control them.
#[derive(Debug, Clone)]
pub struct Store {
    pub(super) root: PathBuf,
}

impl Store {
    pub fn at(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn home() -> Self {
        Self::at(inboxes_root())
    }

    pub fn enqueue(&self, target: &str, new: NewItem, now_ms: u64) -> Result<Enqueued> {
        let dir = self.dir(target)?;
        let new = validated(new)?;
        let pending_dir = dir.join(PENDING_DIR);
        let _lock = self.lock(target)?;
        let pending = read_sized(&pending_dir);
        let dedupe_id = new.dedupe_key.as_deref().map(dedupe_item_id);
        if let Some(id) = dedupe_id.as_ref().filter(|id| item_exists(&dir, id)) {
            return Ok(Enqueued {
                item_id: id.clone(),
                pending: pending.len(),
                truncated: false,
                duplicate: true,
                replaced: Vec::new(),
            });
        }
        let at = pending
            .iter()
            .map(|(item, _)| item.at.saturating_add(1))
            .fold(now_ms, u64::max);
        let id = dedupe_id.unwrap_or_else(|| format!("{at}-{}", short_uuid()));
        let item = stored_item(id, at, new);
        let bytes = serde_json::to_vec(&item).map_err(|error| InboxError::Io(error.to_string()))?;
        let Some(replaced) = room_for(&pending, &item, bytes.len() as u64) else {
            return Err(InboxError::Full(format!(
                "inbox full: {target} already holds {} pending items (limits: \
                 {MAX_PENDING_ITEMS} items, {} MiB)",
                pending.len(),
                MAX_PENDING_BYTES / (1024 * 1024)
            )));
        };
        for victim in &replaced {
            remove_if_present(&pending_dir.join(file_name(victim)))?;
        }
        write_bytes(&pending_dir, &file_name(&item.id), &bytes)?;
        Ok(Enqueued {
            item_id: item.id,
            pending: pending.len() + 1 - replaced.len(),
            truncated: item.truncated_at_enqueue,
            duplicate: false,
            replaced,
        })
    }

    /// Whether anything pending should start a delivery: ride-along items
    /// only ever go out with a wake batch (or by pull).
    pub fn has_wake_pending(&self, session_id: &str) -> bool {
        let Ok(dir) = self.dir(session_id) else {
            return false;
        };
        read_items(&dir.join(PENDING_DIR)).iter().any(|item| {
            item.priority == Priority::Wake
                && !dir.join(DELIVERED_DIR).join(file_name(&item.id)).exists()
        })
    }

    /// Counts and enqueue times of what is pending (already-delivered
    /// leftovers excluded, as in `has_wake_pending`).
    pub fn pending_stats(&self, session_id: &str) -> PendingStats {
        let Ok(dir) = self.dir(session_id) else {
            return PendingStats::default();
        };
        read_items(&dir.join(PENDING_DIR))
            .iter()
            .filter(|item| !dir.join(DELIVERED_DIR).join(file_name(&item.id)).exists())
            .fold(PendingStats::default(), |stats, item| PendingStats {
                items: stats.items + 1,
                wake: stats.wake || item.priority == Priority::Wake,
                oldest_at: Some(stats.oldest_at.map_or(item.at, |at| at.min(item.at))),
                newest_at: Some(stats.newest_at.map_or(item.at, |at| at.max(item.at))),
            })
    }

    /// Every session id with an Inbox directory, sorted.
    pub fn inbox_ids(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let mut ids: Vec<String> = entries
            .flatten()
            .filter(|entry| entry.path().is_dir())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|id| valid_id(id))
            .collect();
        ids.sort();
        ids
    }

    /// Publish (or, with `None`, clear) the current hold reason. Never
    /// creates an Inbox: a session without pending items has nothing held.
    pub fn set_hold(&self, session_id: &str, hold: Option<&Hold>) -> Result<()> {
        let dir = self.dir(session_id)?;
        let _lock = self.lock(session_id)?;
        match hold {
            Some(hold) if dir.join(PENDING_DIR).is_dir() => {
                let bytes =
                    serde_json::to_vec(hold).map_err(|error| InboxError::Io(error.to_string()))?;
                write_bytes(&dir, HOLD_FILE, &bytes)
            }
            Some(_) => Ok(()),
            None => remove_if_present(&dir.join(HOLD_FILE)),
        }
    }

    /// The last published hold reason, if any.
    pub fn hold(&self, session_id: &str) -> Option<Hold> {
        let raw = fs::read(self.dir(session_id).ok()?.join(HOLD_FILE)).ok()?;
        serde_json::from_slice(&raw).ok()
    }

    /// Claim everything pending for one paste. An earlier claim that was
    /// never completed or released is the same batch again (same id, same
    /// items, a higher attempt), so the target can skip a batch it has
    /// already handled; items queued since wait for the next batch.
    pub fn claim_batch(&self, session_id: &str, now_ms: u64) -> Result<Option<Batch>> {
        let dir = self.dir(session_id)?;
        let _lock = self.lock(session_id)?;
        let pending = settled_pending(&dir)?;
        if pending.is_empty() {
            remove_if_present(&dir.join(INFLIGHT_FILE))?;
            return Ok(None);
        }
        let reclaimed = read_claim(&dir).and_then(|claim| {
            let items: Vec<InboxItem> = pending
                .iter()
                .filter(|item| claim.item_ids.contains(&item.id))
                .cloned()
                .collect();
            (!items.is_empty()).then(|| {
                let claim = Claim {
                    item_ids: items.iter().map(|item| item.id.clone()).collect(),
                    attempt: claim.attempt.saturating_add(1),
                    ..claim
                };
                (claim, items)
            })
        });
        let (claim, items) = reclaimed.unwrap_or_else(|| {
            let claim = Claim {
                batch_id: short_uuid(),
                item_ids: pending.iter().map(|item| item.id.clone()).collect(),
                claimed_at: now_ms,
                attempt: 1,
            };
            (claim, pending)
        });
        write_claim(&dir, &claim)?;
        Ok(Some(Batch {
            session_id: session_id.to_owned(),
            batch_id: claim.batch_id,
            attempt: claim.attempt,
            items,
        }))
    }

    /// The paste of `batch_id` reached the target: its items move to
    /// `delivered/`. `false` when that batch is no longer the claim.
    pub fn complete(&self, session_id: &str, batch_id: &str, now_ms: u64) -> Result<bool> {
        let dir = self.dir(session_id)?;
        let _lock = self.lock(session_id)?;
        let Some(claim) = read_claim(&dir).filter(|claim| claim.batch_id == batch_id) else {
            return Ok(false);
        };
        for item_id in &claim.item_ids {
            mark_delivered(&dir, item_id, now_ms)?;
        }
        remove_if_present(&dir.join(INFLIGHT_FILE))?;
        prune_delivered(&dir, now_ms)?;
        Ok(true)
    }

    /// The paste of `batch_id` failed: drop the claim so the next one is a
    /// fresh batch. `false` when that batch is no longer the claim.
    pub fn release(&self, session_id: &str, batch_id: &str) -> Result<bool> {
        let dir = self.dir(session_id)?;
        let _lock = self.lock(session_id)?;
        if read_claim(&dir).is_none_or(|claim| claim.batch_id != batch_id) {
            return Ok(false);
        }
        remove_if_present(&dir.join(INFLIGHT_FILE))?;
        Ok(true)
    }

    /// Pull mode: mark every pending item up to and including `item_id`
    /// consumed, so it is never pasted. Returns how many it consumed (0 when
    /// `item_id` was already delivered).
    pub fn ack_through(&self, session_id: &str, item_id: &str, now_ms: u64) -> Result<usize> {
        let dir = self.dir(session_id)?;
        if !valid_id(item_id) {
            return Err(InboxError::Invalid(format!("invalid item id {item_id:?}")));
        }
        let _lock = self.lock(session_id)?;
        let pending = settled_pending(&dir)?;
        let Some(position) = pending.iter().position(|item| item.id == item_id) else {
            if dir.join(DELIVERED_DIR).join(file_name(item_id)).exists() {
                return Ok(0);
            }
            return Err(InboxError::Invalid(format!(
                "no item {item_id} in the inbox of {session_id}"
            )));
        };
        for item in &pending[..=position] {
            mark_delivered(&dir, &item.id, now_ms)?;
        }
        prune_delivered(&dir, now_ms)?;
        Ok(position + 1)
    }

    /// A stopped Worker's undelivered items go to its Router instead of
    /// being dropped: as ride-along items, `about` the Worker unless they
    /// already name someone. They bypass the pending caps (the Worker's own
    /// Inbox already respected them). Returns how many moved.
    pub fn move_pending(&self, from: &str, to: &str) -> Result<usize> {
        self.move_pending_with(from, to, |item| {
            Some(InboxItem {
                priority: Priority::RideAlong,
                about: item.about.clone().or_else(|| Some(from.to_owned())),
                ..item
            })
        })
    }

    /// A new Router took over from `from`: its undelivered items go to `to`
    /// as they were (a Worker's result still wakes its new Router), except
    /// those `drop` names, which no longer apply to anyone. Returns how many
    /// moved.
    pub fn hand_over_pending(
        &self,
        from: &str,
        to: &str,
        drop: impl Fn(&InboxItem) -> bool,
    ) -> Result<usize> {
        self.move_pending_with(from, to, |item| (!drop(&item)).then_some(item))
    }

    /// Fork-only (ticket 09): drop the pending items `drop` names, for good
    /// (a stopped Router's own instructions). A batch already claimed is
    /// re-claimed without them. Returns how many were dropped.
    pub fn drop_pending(
        &self,
        session_id: &str,
        drop: impl Fn(&InboxItem) -> bool,
    ) -> Result<usize> {
        let dir = self.dir(session_id)?;
        if !dir.is_dir() {
            return Ok(0);
        }
        let _lock = self.lock(session_id)?;
        let mut dropped = 0;
        for item in settled_pending(&dir)?.iter().filter(|item| drop(item)) {
            remove_if_present(&dir.join(PENDING_DIR).join(file_name(&item.id)))?;
            dropped += 1;
        }
        Ok(dropped)
    }

    /// Every pending item of `from` leaves it; `reshape` gives what lands in
    /// `to` (`None`: dropped). An in-flight claim on `from` is dropped too.
    fn move_pending_with(
        &self,
        from: &str,
        to: &str,
        reshape: impl Fn(InboxItem) -> Option<InboxItem>,
    ) -> Result<usize> {
        let (source, target) = (self.dir(from)?, self.dir(to)?);
        if from == to {
            return Ok(0);
        }
        let _locks = self.lock_pair(from, to)?;
        let pending = settled_pending(&source)?;
        remove_if_present(&source.join(INFLIGHT_FILE))?;
        let mut moved = 0;
        for item in pending {
            let source_path = source.join(PENDING_DIR).join(file_name(&item.id));
            if !item_exists(&target, &item.id) {
                if let Some(landed) = reshape(item) {
                    write_item(&target.join(PENDING_DIR), &landed)?;
                    moved += 1;
                }
            }
            remove_if_present(&source_path)?;
        }
        Ok(moved)
    }

    /// The Router just wrote to, stopped or closed its Worker `worker`: the
    /// supervisor reads this stamp to tell an edge the Router caused from
    /// the Worker's own (§17.7). It lives in the Worker's Inbox directory,
    /// which follows the Worker through a Resume.
    pub fn touch_router(&self, worker: &str, now_ms: u64) -> Result<()> {
        let dir = self.dir(worker)?;
        let _lock = self.lock(worker)?;
        write_bytes(&dir, ROUTER_TOUCH_FILE, now_ms.to_string().as_bytes())
    }

    /// When the Router last touched `worker`, in unix ms.
    pub fn router_touched_at(&self, worker: &str) -> Option<u64> {
        let raw = fs::read_to_string(self.dir(worker).ok()?.join(ROUTER_TOUCH_FILE)).ok()?;
        raw.trim().parse().ok()
    }

    /// Resume gave the session a new id: its Inbox follows, merged into
    /// anything already queued for the new id. An in-flight claim is dropped,
    /// so the next paste is a fresh batch. `true` when an Inbox moved.
    pub fn transfer(&self, old: &str, new: &str) -> Result<bool> {
        let (source, target) = (self.dir(old)?, self.dir(new)?);
        // Nothing queued under the old id: not even a lock file is made.
        if old == new || !source.is_dir() {
            return Ok(false);
        }
        let _locks = self.lock_pair(old, new)?;
        if !source.is_dir() {
            return Ok(false);
        }
        remove_if_present(&source.join(INFLIGHT_FILE))?;
        remove_if_present(&source.join(MISSING_SINCE_FILE))?;
        remove_if_present(&source.join(HOLD_FILE))?;
        if !target.exists() {
            fs::rename(&source, &target).map_err(|error| io_error(&source, error))?;
            return Ok(true);
        }
        for sub in [PENDING_DIR, DELIVERED_DIR] {
            merge_items(&source.join(sub), &target, sub)?;
        }
        fs::remove_dir_all(&source).map_err(|error| io_error(&source, error))?;
        Ok(true)
    }

    /// Remove the Inboxes of sessions that have been gone (not in
    /// `live_ids`, the ids with a manifest) for `GC_GRACE_MS`, and prune
    /// every live Inbox's delivered history. The first sweep that misses a
    /// session only stamps `missing-since`: Reload tears the session
    /// directory down and respawns under the same id, and that gap must not
    /// cost a Router its queue. Returns the removed ids.
    pub fn gc(&self, live_ids: &HashSet<String>, now_ms: u64) -> Result<Vec<String>> {
        if let Err(error) = fs::read_dir(&self.root) {
            if error.kind() == std::io::ErrorKind::NotFound {
                return Ok(Vec::new());
            }
            return Err(io_error(&self.root, error));
        }
        let mut removed = Vec::new();
        for id in self.inbox_ids() {
            match self.sweep(&id, live_ids.contains(&id), now_ms) {
                Ok(true) => removed.push(id),
                Ok(false) => {}
                Err(error) => log::warn!("inbox gc skipped {id}: {error}"),
            }
        }
        Ok(removed)
    }

    fn sweep(&self, session_id: &str, live: bool, now_ms: u64) -> Result<bool> {
        let dir = self.dir(session_id)?;
        let _lock = self.lock(session_id)?;
        let stamp = dir.join(MISSING_SINCE_FILE);
        if !dir.is_dir() {
            return Ok(false);
        }
        if live {
            remove_if_present(&stamp)?;
            prune_delivered(&dir, now_ms)?;
            return Ok(false);
        }
        let since = fs::read_to_string(&stamp)
            .ok()
            .and_then(|raw| raw.trim().parse::<u64>().ok());
        match since {
            None => {
                write_bytes(&dir, MISSING_SINCE_FILE, now_ms.to_string().as_bytes())?;
                Ok(false)
            }
            Some(since) if now_ms.saturating_sub(since) >= GC_GRACE_MS => {
                fs::remove_dir_all(&dir).map_err(|error| io_error(&dir, error))?;
                Ok(true)
            }
            Some(_) => Ok(false),
        }
    }

    /// The session is gone for good: so is its Inbox. `true` when one was
    /// removed.
    pub fn remove(&self, session_id: &str) -> Result<bool> {
        let dir = self.dir(session_id)?;
        if !dir.exists() {
            return Ok(false);
        }
        let _lock = self.lock(session_id)?;
        match fs::remove_dir_all(&dir) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(io_error(&dir, error)),
        }
    }

    /// Pending headers (FIFO) and the last `LIST_DELIVERED` deliveries
    /// (newest first).
    pub fn list(&self, session_id: &str) -> Result<Listing> {
        let dir = self.dir(session_id)?;
        let pending = read_items(&dir.join(PENDING_DIR));
        let delivered = read_items(&dir.join(DELIVERED_DIR));
        Ok(Listing {
            pending: pending.iter().map(header).collect(),
            delivered: delivered
                .iter()
                .rev()
                .take(LIST_DELIVERED)
                .map(header)
                .collect(),
        })
    }

    /// Every pending and delivered header, oldest first by enqueue time:
    /// unlike `list`, older deliveries are kept, so a caller can find the
    /// last item a given sender queued.
    pub fn history(&self, session_id: &str) -> Result<Vec<ItemHeader>> {
        let dir = self.dir(session_id)?;
        let mut headers: Vec<ItemHeader> = [DELIVERED_DIR, PENDING_DIR]
            .iter()
            .flat_map(|sub| read_items(&dir.join(sub)))
            .map(|item| header(&item))
            .collect();
        headers.sort_by(|a, b| (a.at, &a.id).cmp(&(b.at, &b.id)));
        headers.dedup_by(|a, b| a.id == b.id);
        Ok(headers)
    }

    /// The full stored item, pending or delivered: the Spill pointer target.
    pub fn item(&self, session_id: &str, item_id: &str) -> Result<Option<InboxItem>> {
        let dir = self.dir(session_id)?;
        if !valid_id(item_id) {
            return Err(InboxError::Invalid(format!("invalid item id {item_id:?}")));
        }
        Ok([PENDING_DIR, DELIVERED_DIR]
            .iter()
            .find_map(|sub| read_item(&dir.join(sub).join(file_name(item_id)))))
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

    /// Both Inboxes' locks, always taken in id order so two crossing moves
    /// can't deadlock. The ids must differ: a second flock on the same file
    /// would wait on the first forever.
    fn lock_pair(
        &self,
        a: &str,
        b: &str,
    ) -> Result<(crate::app_state::FileLock, crate::app_state::FileLock)> {
        let (first, second) = if a <= b { (a, b) } else { (b, a) };
        Ok((self.lock(first)?, self.lock(second)?))
    }
}

/// Rename every item file of one sub-directory into the same sub-directory
/// of `target`, skipping names `target` already holds (the same Host
/// notice queued for both ids).
fn merge_items(source: &Path, target: &Path, sub: &str) -> Result<()> {
    let destination = target.join(sub);
    fs::create_dir_all(&destination).map_err(|error| io_error(&destination, error))?;
    for item in read_items(source) {
        let path = source.join(file_name(&item.id));
        if !item_exists(target, &item.id) {
            fs::rename(&path, destination.join(file_name(&item.id)))
                .map_err(|error| io_error(&path, error))?;
        }
    }
    Ok(())
}

fn item_exists(dir: &Path, item_id: &str) -> bool {
    [PENDING_DIR, DELIVERED_DIR]
        .iter()
        .any(|sub| dir.join(sub).join(file_name(item_id)).exists())
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
    read_sized(dir).into_iter().map(|(item, _)| item).collect()
}

/// `read_items` with each file's size on disk, for the pending byte cap.
fn read_sized(dir: &Path) -> Vec<(InboxItem, u64)> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items: Vec<(InboxItem, u64)> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !name.ends_with(".json") {
                return None;
            }
            let size = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
            read_item(&entry.path()).map(|item| (item, size))
        })
        .collect();
    // Pending items have no `delivered_at`; a batch delivered together keeps
    // its FIFO order.
    items.sort_by(|(a, _), (b, _)| {
        (a.delivered_at, a.at, &a.id).cmp(&(b.delivered_at, b.at, &b.id))
    });
    items
}

fn file_name(item_id: &str) -> String {
    format!("{item_id}.json")
}

/// Pending items, minus any a crash left behind after their delivered copy
/// was written (that leftover pending copy is removed).
fn settled_pending(dir: &Path) -> Result<Vec<InboxItem>> {
    let mut pending = Vec::new();
    for item in read_items(&dir.join(PENDING_DIR)) {
        if dir.join(DELIVERED_DIR).join(file_name(&item.id)).exists() {
            remove_if_present(&dir.join(PENDING_DIR).join(file_name(&item.id)))?;
        } else {
            pending.push(item);
        }
    }
    Ok(pending)
}

/// Move one pending item to `delivered/`, stamped: the delivered copy is
/// written first, so a crash in between leaves it in both places, which
/// reads as delivered. A missing item (acked, replaced) is skipped.
fn mark_delivered(dir: &Path, item_id: &str, now_ms: u64) -> Result<()> {
    let pending_path = dir.join(PENDING_DIR).join(file_name(item_id));
    let Some(item) = read_item(&pending_path) else {
        return Ok(());
    };
    let delivered = InboxItem {
        delivered_at: Some(now_ms),
        ..item
    };
    write_item(&dir.join(DELIVERED_DIR), &delivered)?;
    remove_if_present(&pending_path)
}

/// Delivered history keeps at most `DELIVERED_KEEP_ITEMS` items, none
/// older than `DELIVERED_KEEP_MS`.
fn prune_delivered(dir: &Path, now_ms: u64) -> Result<()> {
    let delivered = read_items(&dir.join(DELIVERED_DIR));
    let excess = delivered.len().saturating_sub(DELIVERED_KEEP_ITEMS);
    for (index, item) in delivered.iter().enumerate() {
        let delivered_at = item.delivered_at.unwrap_or(0);
        if index < excess || now_ms.saturating_sub(delivered_at) > DELIVERED_KEEP_MS {
            remove_if_present(&dir.join(DELIVERED_DIR).join(file_name(&item.id)))?;
        }
    }
    Ok(())
}

fn read_claim(dir: &Path) -> Option<Claim> {
    let raw = fs::read(dir.join(INFLIGHT_FILE)).ok()?;
    serde_json::from_slice(&raw).ok()
}

fn write_claim(dir: &Path, claim: &Claim) -> Result<()> {
    let bytes = serde_json::to_vec(claim).map_err(|error| InboxError::Io(error.to_string()))?;
    write_bytes(dir, INFLIGHT_FILE, &bytes)
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(io_error(path, error)),
        _ => Ok(()),
    }
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
    write_bytes(dir, &file_name(&item.id), &bytes)
}

fn write_bytes(dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    fs::create_dir_all(dir).map_err(|error| io_error(dir, error))?;
    let tmp = dir.join(format!(".tmp-{}", short_uuid()));
    let written = fs::File::create(&tmp)
        .and_then(|mut file| file.write_all(bytes).and_then(|()| file.sync_all()))
        .and_then(|()| fs::rename(&tmp, dir.join(name)));
    if let Err(error) = written {
        let _ = fs::remove_file(&tmp);
        return Err(io_error(dir, error));
    }
    if let Ok(handle) = fs::File::open(dir) {
        let _ = handle.sync_all();
    }
    Ok(())
}
