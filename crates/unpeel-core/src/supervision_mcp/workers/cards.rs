//! Fork-only: `sessions current` for the Super Agent (§17.8). The Router
//! sees a card per Worker — enough to re-orient after a compaction or a
//! Resume without reading transcripts; a Worker sees which Router it works
//! for.

use serde_json::{json, Value};

use super::{at_home, Facts, Home};
use crate::session_inbox::{ItemHeader, ItemKind, Sender};

/// The Host lifecycle `status` of a Worker's Finished notice (queued
/// `about` the Worker, with its reply in the body).
pub(crate) const FINISHED_STATUS: &str = "finished";
/// Longest card preview.
pub(super) const MAX_PREVIEW_CHARS: usize = 160;

/// Extra `sessions current` fields for `caller_id`: `inbox.pending` for
/// every caller (§9), plus Worker cards for the Router or `router_id` for a
/// Worker.
pub(crate) fn current_extras(caller_id: &str) -> Option<Value> {
    at_home(|home| current_extras_at(home, caller_id))
}

pub(super) fn current_extras_at(home: &Home, caller_id: &str) -> Option<Value> {
    let inbox = json!({ "pending": home.inbox.pending_stats(caller_id).items });
    if home.is_router(caller_id) {
        return Some(json!({
            "super_agent": true,
            "workers": worker_cards(home, caller_id),
            "inbox": inbox,
        }));
    }
    Some(match home.marker(caller_id) {
        Some(marker) => json!({ "router_id": marker.router_id, "inbox": inbox }),
        None => json!({ "inbox": inbox }),
    })
}

/// One card per Worker, stopped ones included, oldest first. The Router's
/// Inbox history is read once for all of them.
fn worker_cards(home: &Home, router_id: &str) -> Vec<Value> {
    let history = home.inbox.history(router_id).unwrap_or_default();
    home.workers(router_id)
        .into_iter()
        .filter_map(|(id, _)| {
            let facts = (home.facts)(&id)?;
            Some(card(home, router_id, &id, &facts, &history))
        })
        .collect()
}

fn card(home: &Home, router_id: &str, id: &str, facts: &Facts, history: &[ItemHeader]) -> Value {
    let from_worker = |header: &ItemHeader| header.sender == Sender::Session(id.to_owned());
    let is_report =
        |header: &ItemHeader| matches!(header.kind, ItemKind::Report | ItemKind::Handover);
    let last_report = history
        .iter()
        .rev()
        .find(|header| from_worker(header) && is_report(header));
    let last_said = history.iter().rev().find(|header| {
        (from_worker(header) && (is_report(header) || header.kind == ItemKind::Message))
            || is_finished_notice(header, id)
    });
    json!({
        "id": id,
        "label": facts.label,
        "project_id": facts.project_id,
        "group_id": facts.group_id,
        "activity_status": facts.activity_status,
        "last_report_status": last_report.and_then(|header| header.status.clone()),
        "preview": last_said.map(|header| preview(home, router_id, header)),
    })
}

fn is_finished_notice(header: &ItemHeader, worker: &str) -> bool {
    header.sender == Sender::Host
        && header.kind == ItemKind::Lifecycle
        && header.about.as_deref() == Some(worker)
        && header.status.as_deref() == Some(FINISHED_STATUS)
}

/// A report's or message's summary; a Finished notice's reply (its body).
/// One line, at most `MAX_PREVIEW_CHARS`.
fn preview(home: &Home, router_id: &str, header: &ItemHeader) -> String {
    let body = || {
        home.inbox
            .item(router_id, &header.id)
            .ok()
            .flatten()
            .map(|item| item.body)
            .unwrap_or_default()
    };
    let text = match header.sender {
        Sender::Host => Some(body()).filter(|body| !body.trim().is_empty()),
        Sender::Session(_) => Some(header.summary.clone()).filter(|text| !text.trim().is_empty()),
    }
    .unwrap_or_else(|| match header.sender {
        Sender::Host => header.summary.clone(),
        Sender::Session(_) => body(),
    });
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= MAX_PREVIEW_CHARS {
        return flat;
    }
    let mut cut: String = flat.chars().take(MAX_PREVIEW_CHARS - 1).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests;
