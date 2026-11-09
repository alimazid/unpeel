//! Fork-only: what an enqueue may store — sender and id checks, header
//! fields reduced to one plain line, the item and pending caps.

use super::*;

/// Checks the ids and reduces every header field to one short plain line,
/// so a per-item header can never be forged from inside a field.
pub(super) fn validated(new: NewItem) -> Result<NewItem> {
    let dedupe_key = match &new.sender {
        Sender::Session(id) if !valid_id(id) || id.eq_ignore_ascii_case(HOST_SENDER_ID) => {
            return Err(InboxError::Invalid(format!("invalid sender id {id:?}")));
        }
        // Only the Host dedupes: a Session naming the key of a notice the
        // Host sends later would otherwise suppress it.
        Sender::Session(_) => None,
        Sender::Host => new.dedupe_key.filter(|key| !key.is_empty()),
    };
    let about = new.about.filter(|about| !about.is_empty());
    if let Some(about) = about.as_ref().filter(|about| !valid_id(about)) {
        return Err(InboxError::Invalid(format!("invalid about id {about:?}")));
    }
    let status: String = new
        .status
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        .take(MAX_STATUS_CHARS)
        .collect();
    let label = new
        .label
        .map(|label| header_text(&label, MAX_LABEL_CHARS))
        .filter(|label| !label.is_empty());
    Ok(NewItem {
        dedupe_key,
        about,
        status: (!status.is_empty()).then_some(status),
        label,
        ..new
    })
}

/// The item as stored: the summary is one line, and summary plus body fit
/// the item cap (cut on a character boundary, flagged, original size kept).
pub(super) fn stored_item(id: String, at: u64, new: NewItem) -> InboxItem {
    let flat = one_line(&new.summary);
    let summary: String = flat.chars().take(MAX_SUMMARY_CHARS).collect();
    let body_room = MAX_STORED_ITEM_BYTES.saturating_sub(summary.len());
    let body_bytes = new.body.len();
    let body = new.body[..floor_char_boundary(&new.body, body_room)].to_owned();
    InboxItem {
        v: ITEM_VERSION,
        id,
        at,
        truncated_at_enqueue: summary.len() < flat.len() || body.len() < body_bytes,
        body_bytes,
        sender: new.sender,
        kind: new.kind,
        priority: new.priority,
        about: new.about,
        status: new.status,
        label: new.label,
        summary,
        body,
        dedupe_key: new.dedupe_key,
        delivered_at: None,
    }
}

/// The pending items to drop so `incoming` fits under the caps (empty when
/// it already fits), or `None` when it can't. A Host notice replaces older
/// Host notices about the same child. Then, for any item, a Host notice
/// waiting to ride along gives way, so a looping Worker's turns never crowd
/// out a report.
pub(super) fn room_for(
    pending: &[(InboxItem, u64)],
    incoming: &InboxItem,
    incoming_bytes: u64,
) -> Option<Vec<String>> {
    let mut count = pending.len() + 1;
    let mut bytes = pending.iter().map(|(_, size)| size).sum::<u64>() + incoming_bytes;
    let about_same_child = |item: &InboxItem| {
        incoming.sender == Sender::Host
            && item.sender == Sender::Host
            && item.about == incoming.about
    };
    let (same_child, others): (Vec<_>, Vec<_>) =
        pending.iter().partition(|(item, _)| about_same_child(item));
    let riding_along = others
        .into_iter()
        .filter(|(item, _)| item.sender == Sender::Host && item.priority == Priority::RideAlong);
    let mut candidates = same_child.into_iter().chain(riding_along);
    let mut victims = Vec::new();
    while count > MAX_PENDING_ITEMS || bytes > MAX_PENDING_BYTES {
        let (victim, size) = candidates.next()?;
        count -= 1;
        bytes = bytes.saturating_sub(*size);
        victims.push(victim.id.clone());
    }
    Some(victims)
}

/// Whitespace and control characters collapse to single spaces.
fn one_line(text: &str) -> String {
    text.split(|c: char| c.is_whitespace() || c.is_control())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// A header value: one line, without the characters that shape a header
/// (`[`, `]`, `"`), at most `max_chars` long.
pub(super) fn header_text(text: &str, max_chars: usize) -> String {
    let plain: String = text
        .chars()
        .filter(|c| !matches!(c, '[' | ']' | '"'))
        .collect();
    one_line(&plain).chars().take(max_chars).collect()
}

fn floor_char_boundary(text: &str, max_bytes: usize) -> usize {
    if max_bytes >= text.len() {
        return text.len();
    }
    (0..=max_bytes)
        .rev()
        .find(|&index| text.is_char_boundary(index))
        .unwrap_or(0)
}

/// `h-<sha256(key)[..16]>`: the same notice always lands in the same file.
pub(super) fn dedupe_item_id(key: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = format!("{:x}", Sha256::digest(key.as_bytes()));
    format!("h-{}", &digest[..16])
}

/// Session and item ids become path components and land in paste headers:
/// one plain name (session ids are lowercase UUIDs), never a dot file, a
/// parent reference, or anything that could close or extend a header.
pub(super) fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_BYTES
        && !id.starts_with('.')
        && !id.contains("..")
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub(super) fn short_uuid() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_owned()
}
