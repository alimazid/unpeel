//! Fork-only (#84): the worker's side of the health check
//! (`crate::health`), kept out of `driver.rs`, which calls it from one-line
//! `// Fork-only` hunks: once per rescan after the scheduler's sweep and
//! the supervisor's step, and for a failed Run's own notice no app was
//! connected to show.

use super::{now_ms, HostRuntime, Notice, WhenDone};
use crate::health::state::KeptNotice;
use crate::health::Alert;
use crate::notifications::NotificationKind;

/// The platform-adapter capability that shows a Mac notification.
const NOTIFY_CAPABILITY: &str = "notification.deliver";

impl HostRuntime {
    /// Show the notifications kept for an app, then run the check when it
    /// is due and deliver its alerts.
    pub(super) fn check_health(&mut self) {
        let now = now_ms();
        self.show_kept_notices(now);
        if !self.health.due(now) {
            return;
        }
        let facts = crate::health::host::facts(&self.model.rows, &crate::schedules::clock::now());
        let super_agent = facts
            .super_agent
            .as_ref()
            .map(|agent| agent.session_id.clone());
        for alert in self.health.run(&facts, now) {
            crate::tracelog::trace("health", &alert.text);
            if let Some(super_agent) = super_agent
                .as_deref()
                .filter(|_| alert.check.to_super_agent())
            {
                if let Err(error) = crate::health::host::queue_report(super_agent, &alert, now) {
                    crate::tracelog::trace(
                        "health",
                        &format!("report for {super_agent} not queued: {error}"),
                    );
                }
            }
            if alert.check.to_mac() {
                self.notify_health(&alert, now);
            }
        }
    }

    /// A failed Run's own notice (`notify_run`) when no app can show it: it
    /// waits for one.
    pub(super) fn keep_run_failure(
        &mut self,
        schedule_id: &str,
        session_id: Option<&str>,
        notice: &crate::schedules::notice::RunNotice,
        now: u64,
    ) {
        if notice.kind != NotificationKind::Alert || self.can_notify() {
            return;
        }
        self.health.keep(KeptNotice {
            problem: None,
            session_id: session_id.unwrap_or_default().to_owned(),
            schedule_id: Some(schedule_id.to_owned()),
            title: notice.title.clone(),
            body: notice.body.clone(),
            at: now,
        });
    }

    fn notify_health(&mut self, alert: &Alert, now: u64) {
        let notice = alert.notice(now);
        if self.can_notify() {
            self.show(&notice, now);
        } else {
            self.health.keep(notice);
        }
    }

    fn show_kept_notices(&mut self, now: u64) {
        if !self.health.has_kept() || !self.can_notify() {
            return;
        }
        for notice in self.health.take_kept() {
            self.show(&notice, now);
        }
    }

    fn can_notify(&self) -> bool {
        self.platform_adapters.supports(NOTIFY_CAPABILITY)
    }

    /// An alert banner: it leaves nothing unread, like a Run's failure.
    fn show(&self, notice: &KeptNotice, now: u64) {
        self.deliver_notice(
            Notice {
                session_id: &notice.session_id,
                title: &notice.title,
                kind: NotificationKind::Alert,
                body: Some(&notice.body),
                when_done: WhenDone::Always,
                schedule_id: notice.schedule_id.as_deref(),
            },
            now,
        );
    }
}
