//! Fork-only (#84): the worker's side of the health check
//! (`crate::health`), kept out of `driver.rs`, which calls it from one-line
//! `// Fork-only` hunks: once per rescan after the scheduler's sweep and
//! the supervisor's step, and for a failed Run's own notice no app could
//! show.

use super::{now_ms, HostRuntime, Notice, WhenDone};
use crate::health::state::KeptNotice;
use crate::health::Alert;
use crate::notifications::NotificationKind;

/// The platform-adapter capability that shows a Mac notification.
const NOTIFY_CAPABILITY: &str = "notification.deliver";

impl HostRuntime {
    /// Run the check when it is due, or when an app can show the kept
    /// notifications (so one whose problem cleared since is dropped first);
    /// then show the kept ones, oldest first, and deliver the new alerts.
    pub(super) fn check_health(&mut self) {
        let now = now_ms();
        let showing = self.health.has_kept() && self.can_notify();
        if !showing && !self.health.due(now) {
            return;
        }
        let facts = crate::health::host::facts(&self.model.rows, &crate::schedules::clock::now());
        let router = facts.router.as_ref().map(|agent| agent.session_id.clone());
        let alerts = self.health.run(&facts, now);
        self.show_kept_notices(now);
        for alert in alerts {
            self.deliver_alert(router.as_deref(), &alert, now);
        }
    }

    fn deliver_alert(&mut self, router: Option<&str>, alert: &Alert, now: u64) {
        crate::tracelog::trace("health", &alert.text);
        if let Some(router) = router.filter(|_| alert.check.to_router()) {
            if let Err(error) = crate::health::host::queue_report(router, alert, now) {
                crate::tracelog::trace(
                    "health",
                    &format!("report for {router} not queued: {error}"),
                );
            }
        }
        if alert.check.to_mac() {
            self.show_or_keep(alert.notice(now), now);
        }
    }

    /// A failed Run's own notice (`notify_run`, after its delivery) when no
    /// app could show it: none was connected, or it went away delivering
    /// it. It waits for one.
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

    /// Show `notice`, or keep it while no app can: none is connected, or
    /// the app went away delivering it (the hub drops an adapter whose call
    /// fails), so it may show twice but is never lost.
    fn show_or_keep(&mut self, notice: KeptNotice, now: u64) {
        if self.can_notify() {
            self.show(&notice, now);
            if self.can_notify() {
                return;
            }
        }
        self.health.keep(notice);
    }

    fn show_kept_notices(&mut self, now: u64) {
        if !self.health.has_kept() || !self.can_notify() {
            return;
        }
        for notice in self.health.take_kept() {
            self.show_or_keep(notice, now);
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
