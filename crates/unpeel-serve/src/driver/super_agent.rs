//! Fork-only: the worker's Super Agent plumbing, kept out of `driver.rs`
//! (which calls it from one-line `// Fork-only` hunks). The decisions live
//! in `crate::supervisor`; this module only wires them to the worker's
//! notifications, alerts and unread set.

use unpeel_core::activity_log::ActivityLogKind;

use super::{now_ms, HostRuntime};
use crate::sessions::SessionRow;
use crate::supervisor::{EdgeRoute, Notice, NoticeKind};

/// What the rescan's delivery loop does with one lifecycle edge.
pub(super) struct SupervisedEdge {
    /// Taken for the Router: no user notification, the row reads observed.
    pub diverted: bool,
    pub requires_notify_when_done: bool,
    /// A Finished edge's reply snippet, already taken.
    pub finished_body: Option<String>,
}

impl HostRuntime {
    /// One lifecycle edge of `row`. A Finished edge's reply is taken first,
    /// so it is consumed even when the edge goes to a Router instead.
    pub(super) fn supervise_edge(
        &mut self,
        row: &SessionRow,
        kind: ActivityLogKind,
        edge_msg: Option<&str>,
        now: u64,
    ) -> SupervisedEdge {
        let finished_body = (kind == ActivityLogKind::Finished)
            .then(|| {
                let hook_message = self.completion_messages.take(&row.id, now);
                crate::completion_snippet::finished_body(edge_msg, hook_message.as_deref())
            })
            .flatten();
        let route = self
            .supervisor
            .route_edge(row, kind, finished_body.as_deref(), now);
        let (diverted, requires_notify_when_done) = match route {
            EdgeRoute::Router => (true, true),
            EdgeRoute::User {
                requires_notify_when_done,
            } => (false, requires_notify_when_done),
        };
        SupervisedEdge {
            diverted,
            requires_notify_when_done,
            finished_body,
        }
    }

    /// A supervisor notice for the user. A Worker prompt the Router left
    /// unanswered is the "needs input" its edge was not; the rest are
    /// alerts. The edge itself was already logged as activity.
    pub(super) fn deliver_supervisor_notice(&mut self, notice: Notice) {
        if notice.kind != NoticeKind::NeedsInput {
            return self.record_alert(
                &notice.session_id,
                notice.body,
                std::time::SystemTime::now(),
            );
        }
        let Some(row) = self
            .model
            .rows
            .iter()
            .find(|row| row.id == notice.session_id)
            .cloned()
        else {
            return;
        };
        let kind = crate::notifications::NotificationKind::NeedsInput;
        if self.deliver_notification(
            &row,
            kind,
            Some(&notice.body),
            super::WhenDone::Always,
            now_ms(),
        ) {
            if let Err(error) = unpeel_core::session_ops::mark_read(&row.id) {
                crate::tracelog::trace(
                    "supervisor",
                    &format!("mark {} read after its escalation: {error}", row.id),
                );
            }
            self.unread_ids.remove(&row.id);
        } else {
            self.unread_ids.insert(row.id.clone());
        }
    }
}
