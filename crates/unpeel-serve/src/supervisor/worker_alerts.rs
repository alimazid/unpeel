//! Fork-only: a Worker's lifecycle goes to its Router, not the user
//! (§5, §16.3, §17.2/3/5/7). While the Router runs, a Worker's prompts,
//! finishes and exits become Host notices in the Router's Inbox; the user
//! hears only about a Worker prompt left unanswered for
//! `supervisor_escalate_minutes`. Edges the Router caused itself (it
//! stopped, interrupted or wrote to the Worker a moment before) produce no
//! notice. The rules-based watchdog (`watchdog.rs`) runs over the same
//! per-Session tracks, and a Host start catches the Router up on what its
//! Workers did while no supervisor was watching.
//!
//! Tracks come from two places: `step` sees every rescan's rows, and
//! `divert` sees the rescan's edges just before that step. So when an edge
//! arrives, a track still holds the status from the previous rescan — the
//! status a Worker had before it exited, and when its turn began.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use unpeel_core::activity_log::ActivityLogKind;
use unpeel_core::session_inbox::{ItemKind, NewItem, Sender, Store};
use unpeel_core::supervision::SupervisorConfig;

use super::compaction::{CompactionView, Scope};
use super::inbox_drain::{Notice, NoticeKind, CONFIRM_TIMEOUT_MS};
use super::notices::TurnCause;
use super::worker_host::{Exit, HostWorkers, WorkerHost};
use super::{notices, watchdog};
use crate::sessions::{SessionRow, Status, StatusSource};

/// A Router write, stop or keypress this recent caused the Worker's edge.
pub const SELF_CAUSED_MS: u64 = 5_000;
/// The same for an exit: the stop verb waits up to 8 s for the exited
/// manifest, and a rescan follows.
pub const SELF_CAUSED_EXIT_MS: u64 = 15_000;
/// A keystroke this long before a turn began counts as the user's start. A
/// Host paste or Router write gets `CONFIRM_TIMEOUT_MS`, the time the drain
/// itself gives a paste to start a turn.
const TYPED_CAUSE_MS: u64 = 10_000;
pub const HEARTBEAT_MS: u64 = 30_000;
/// Restart reconciliation looks back at most this far (the Inbox keeps
/// delivered notices, and so their dedupe keys, for a day).
const RECONCILE_MAX_AGE_MS: u64 = unpeel_core::session_inbox::DELIVERED_KEEP_MS;

/// What the Worker alerts read from the Inbox drain.
pub trait DrainView {
    /// The drain pasted into `session_id` at some time in `from..=to`.
    fn pasted_between(&self, session_id: &str, from: u64, to: u64) -> bool;
    /// `session_id` has undelivered Inbox items.
    fn has_pending(&self, session_id: &str) -> bool;
}

/// What the supervisor knows about one Session between rescans.
#[derive(Debug, Default)]
struct Track {
    /// The status the last step saw; `None` before any step saw the row.
    status: Option<Status>,
    running: bool,
    seen_at: u64,
    /// The current turn (Busy or waiting), while one runs.
    turn: Option<Turn>,
    /// The current wait on a prompt.
    waiting: Option<Waiting>,
    /// When the last step saw it turn Busy, or a prompt was submitted.
    busy_at: Option<u64>,
    hook_at: Option<u64>,
    prompt_at: Option<u64>,
    finished_at: Option<u64>,
    /// A turn that ended without finishing, checked one step later.
    ended_quietly: Option<(Turn, u64)>,
    /// A turn the Host may have started ended with no report: the next turn
    /// nobody prompted can carry its answer.
    follow_up_owed: bool,
    /// Watchdog episodes already reported.
    fired: HashSet<(watchdog::Rule, u64)>,
}

impl Track {
    /// A turn nobody prompted right after one the Host may have started can
    /// be that task's answer (a background task finishing), so it wakes,
    /// once. A loop's later ticks do not.
    fn settle(&mut self, cause: TurnCause) -> TurnCause {
        match cause {
            TurnCause::HostOrUnseen => {
                self.follow_up_owed = true;
                cause
            }
            TurnCause::Unprompted if std::mem::take(&mut self.follow_up_owed) => {
                TurnCause::HostOrUnseen
            }
            TurnCause::Unprompted | TurnCause::UserTyped => cause,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Turn {
    started_at: u64,
    /// The supervisor saw it begin from idle: a turn already running when
    /// the row first appeared (a Host restart, a launch prompt) is never
    /// called the user's.
    watched: bool,
}

#[derive(Debug, Clone, Copy)]
struct Waiting {
    since: u64,
    /// Its needs-input edge went to the Router instead of the user.
    diverted: bool,
    escalated: bool,
}

/// The last step's view, for `auto_stop_rows` (which runs before the step).
#[derive(Debug, Default)]
struct View {
    router: Option<String>,
    router_running: bool,
    workers: HashSet<String>,
    /// `supervisor_compact_percent`, for the Host's compaction (#64).
    compact_percent: u8,
}

pub struct WorkerAlerts {
    store: Store,
    io: Arc<dyn WorkerHost>,
    started_at: u64,
    tracks: HashMap<String, Track>,
    view: View,
    /// The previous supervisor's last heartbeat, read on the first step.
    floor: Option<Option<u64>>,
    reconciled: bool,
    heartbeat_at: Option<u64>,
}

impl Default for WorkerAlerts {
    fn default() -> Self {
        Self::starting_at(
            Store::home(),
            Arc::new(HostWorkers),
            unpeel_core::supervision::now_ms(),
        )
    }
}

impl std::fmt::Debug for WorkerAlerts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkerAlerts")
            .field("tracks", &self.tracks)
            .finish_non_exhaustive()
    }
}

impl WorkerAlerts {
    pub fn starting_at(store: Store, io: Arc<dyn WorkerHost>, started_at: u64) -> Self {
        Self {
            store,
            io,
            started_at,
            tracks: HashMap::new(),
            view: View::default(),
            floor: None,
            reconciled: false,
            heartbeat_at: None,
        }
    }

    /// Any accepted hook event is progress; a prompt submit dates a turn.
    pub fn observe_hook(&mut self, session_id: &str, canonical_event: &str, at_ms: u64) {
        let track = self.tracks.entry(session_id.to_owned()).or_default();
        track.hook_at = track.hook_at.max(Some(at_ms));
        if canonical_event == "UserPromptSubmit" {
            track.prompt_at = track.prompt_at.max(Some(at_ms));
            track.busy_at = track.busy_at.max(Some(at_ms));
        }
    }

    /// A lifecycle edge of `row`. `true`: it belongs to a running Router's
    /// Worker, so the user is not notified (whether or not a notice was
    /// queued); `false` when it is not a Worker's, or its notice could not
    /// be queued, so the user still hears about it.
    pub fn divert(
        &mut self,
        row: &SessionRow,
        kind: ActivityLogKind,
        body: Option<&str>,
        now: u64,
        drain: &dyn DrainView,
        compaction: &dyn CompactionView,
    ) -> bool {
        if !matches!(
            kind,
            ActivityLogKind::NeedsInput
                | ActivityLogKind::Finished
                | ActivityLogKind::Exited
                | ActivityLogKind::Started
        ) {
            return false;
        }
        let (router, config) = self.io.router_and_config();
        let Some(router) = router.filter(|router| self.is_worker_of(row, router)) else {
            return false;
        };
        let touched = self.store.router_touched_at(&row.id);
        let notice = match kind {
            ActivityLogKind::NeedsInput => self.needs_input(row, touched, now),
            ActivityLogKind::Finished => {
                self.finished(row, &router, body, touched, now, drain, compaction)
            }
            ActivityLogKind::Exited => self.exited(row, touched, now),
            _ => config.notify_started.then(|| notices::started(row)),
        };
        notice.is_none_or(|notice| self.enqueue(&router, notice, now))
    }

    fn is_worker_of(&self, row: &SessionRow, router: &str) -> bool {
        row.is_worker
            && row.id != router
            && self.io.worker_router(&row.id).as_deref() == Some(router)
            && self
                .tracks
                .get(router)
                .filter(|track| track.status.is_some())
                .map_or_else(|| self.io.running(router), |track| track.running)
    }

    fn needs_input(&mut self, row: &SessionRow, touched: Option<u64>, now: u64) -> Option<NewItem> {
        let track = self.tracks.entry(row.id.clone()).or_default();
        track.waiting = Some(Waiting {
            since: now,
            diverted: true,
            escalated: false,
        });
        (!self_caused(track, touched, now, SELF_CAUSED_MS)).then(|| notices::needs_input(row))
    }

    #[allow(clippy::too_many_arguments)]
    fn finished(
        &mut self,
        row: &SessionRow,
        router: &str,
        reply: Option<&str>,
        touched: Option<u64>,
        now: u64,
        drain: &dyn DrainView,
        compaction: &dyn CompactionView,
    ) -> Option<NewItem> {
        let started_at = self.started_at;
        let track = self.tracks.entry(row.id.clone()).or_default();
        let previous = track.finished_at.replace(now);
        let turn = track.turn.or_else(|| {
            // A turn too short for any rescan to see Busy: its prompt
            // submit still dates it.
            let started_at = track
                .prompt_at
                .filter(|at| previous.is_none_or(|f| *at > f))?;
            Some(Turn {
                started_at,
                watched: true,
            })
        });
        let facts = TurnFacts {
            drain,
            touched,
            typed_at: self.io.last_input_at(&row.id),
        };
        let turn_start = turn.map_or(now, |turn| turn.started_at);
        if hosts_compaction(compaction, &row.id, turn_start, &facts, now) {
            return None;
        }
        // Interrupted (no reply) right after the Router wrote or pressed a
        // key: the Router knows. A reply is always the Worker's answer.
        if reply.is_none() && self_caused(track, touched, now, SELF_CAUSED_MS) {
            return None;
        }
        let since = turn
            .map(|turn| turn.started_at)
            .or(previous)
            .unwrap_or(started_at);
        if reported_since(&self.store, router, &row.id, since) {
            track.follow_up_owed = false;
            return None;
        }
        let cause = track.settle(turn_cause(&row.id, turn, &facts, now));
        Some(notices::finished(row, reply, cause, finished_stamp(row)))
    }

    fn exited(&mut self, row: &SessionRow, touched: Option<u64>, now: u64) -> Option<NewItem> {
        let track = self.tracks.entry(row.id.clone()).or_default();
        if self_caused(track, touched, now, SELF_CAUSED_EXIT_MS) {
            return None;
        }
        let exit = self.io.exit(&row.id);
        let at = exit.map_or(now, |exit| exit.at);
        Some(notices::exited(
            row,
            exit.and_then(|exit| exit.code),
            track.status,
            at,
        ))
    }

    /// Once per rescan: update every track, raise the watchdog's alarms
    /// and escalations, catch up after a Host start, keep the heartbeat.
    /// Returns notifications for the user.
    pub fn step(
        &mut self,
        rows: &[SessionRow],
        now: u64,
        drain: &dyn DrainView,
        compaction: &dyn CompactionView,
    ) -> Vec<Notice> {
        let (router, config) = self.io.router_and_config();
        let floor = *self.floor.get_or_insert_with(|| self.io.heartbeat());
        for row in rows {
            let track = self.tracks.entry(row.id.clone()).or_default();
            observe(track, row, now, self.started_at);
        }
        self.tracks
            .retain(|id, _| rows.iter().any(|row| row.id == *id));
        let router_running = router
            .as_ref()
            .is_some_and(|router| rows.iter().any(|row| row.id == *router && row.running));
        let workers: HashSet<String> = match &router {
            Some(router) => rows
                .iter()
                .filter(|row| {
                    row.is_worker
                        && row.id != *router
                        && self.io.worker_router(&row.id).as_deref() == Some(router)
                })
                .map(|row| row.id.clone())
                .collect(),
            None => HashSet::new(),
        };
        if let Some(router) = router.as_deref().filter(|_| router_running) {
            if !self.reconciled {
                self.reconcile(rows, router, &workers, floor, now);
            }
            self.watch(rows, router, &workers, &config, now, drain, compaction);
        }
        self.reconciled = true;
        // A quiet end had its one step to be reported.
        for track in self.tracks.values_mut() {
            if track
                .ended_quietly
                .is_some_and(|(_, ended_at)| ended_at < now)
            {
                track.ended_quietly = None;
            }
        }
        if router.is_some() && self.heartbeat_at.is_none_or(|at| now >= at + HEARTBEAT_MS) {
            self.heartbeat_at = Some(now);
            self.io.write_heartbeat(now);
        }
        let notices = self.escalations(rows, &config, now);
        self.view = View {
            router,
            router_running,
            workers,
            compact_percent: config.compact_percent,
        };
        notices
    }

    /// The running Router's Workers and the compaction setting, as the
    /// last step saw them (#64).
    pub fn compaction_scope(&self) -> Option<Scope<'_>> {
        let router = self
            .view
            .router
            .as_deref()
            .filter(|_| self.view.router_running)?;
        Some(Scope {
            router,
            workers: &self.view.workers,
            percent: self.view.compact_percent,
        })
    }

    /// The watchdog over the running Router's Workers.
    #[allow(clippy::too_many_arguments)]
    fn watch(
        &mut self,
        rows: &[SessionRow],
        router: &str,
        workers: &HashSet<String>,
        config: &SupervisorConfig,
        now: u64,
        drain: &dyn DrainView,
        compaction: &dyn CompactionView,
    ) {
        let mut alarms = Vec::new();
        for row in rows.iter().filter(|row| workers.contains(&row.id)) {
            let durable = if row.status == Status::Busy {
                self.io.durable_progress(row)
            } else {
                None
            };
            let touched = self.store.router_touched_at(&row.id);
            let Some(track) = self.tracks.get_mut(&row.id) else {
                continue;
            };
            let mut due =
                watchdog::due(&evidence(track, row, durable, self.started_at), config, now);
            let facts = TurnFacts {
                drain,
                touched,
                typed_at: track
                    .ended_quietly
                    .and_then(|_| self.io.last_input_at(&row.id)),
            };
            match quiet_end(&self.store, router, track, row, &facts, compaction, now) {
                Some(QuietEnd::WentQuiet(alarm)) => due.push(alarm),
                Some(QuietEnd::ScreenFinished(notice)) => alarms.push(notice),
                None => {}
            }
            for alarm in due {
                if track.fired.insert((alarm.rule, alarm.episode)) {
                    alarms.push(notices::alarm(row, &alarm));
                }
            }
        }
        for alarm in alarms {
            self.enqueue(router, alarm, now);
        }
    }

    /// A diverted Worker prompt left unanswered for the escalation time
    /// notifies the user, once per wait.
    fn escalations(
        &mut self,
        rows: &[SessionRow],
        config: &SupervisorConfig,
        now: u64,
    ) -> Vec<Notice> {
        if config.escalate_ms == 0 {
            return Vec::new();
        }
        let mut notices = Vec::new();
        for row in rows {
            let Some(waiting) = self
                .tracks
                .get_mut(&row.id)
                .and_then(|track| track.waiting.as_mut())
            else {
                continue;
            };
            if waiting.diverted
                && !waiting.escalated
                && now.saturating_sub(waiting.since) >= config.escalate_ms
            {
                waiting.escalated = true;
                notices.push(Notice {
                    session_id: row.id.clone(),
                    body: format!(
                        "Waiting for your input for {}; the Super Agent has not answered.",
                        notices::duration(config.escalate_ms)
                    ),
                    kind: NoticeKind::NeedsInput,
                });
            }
        }
        notices
    }

    /// The first step: what the Router's Workers did after the previous
    /// supervisor's last heartbeat (exits, finished turns) is queued with
    /// the same dedupe keys the live notices use, so nothing the Router
    /// already has comes twice. No heartbeat: no earlier supervisor, nothing
    /// to catch up on.
    fn reconcile(
        &mut self,
        rows: &[SessionRow],
        router: &str,
        workers: &HashSet<String>,
        floor: Option<u64>,
        now: u64,
    ) {
        let Some(floor) = floor.map(|floor| floor.max(now.saturating_sub(RECONCILE_MAX_AGE_MS)))
        else {
            return;
        };
        let mut caught_up = Vec::new();
        for row in rows.iter().filter(|row| workers.contains(&row.id)) {
            if !row.running {
                let Some(Exit { code, at }) = self.io.exit(&row.id) else {
                    continue;
                };
                let by_router = self
                    .store
                    .router_touched_at(&row.id)
                    .is_some_and(|touched| touched <= at && touched + SELF_CAUSED_EXIT_MS >= at);
                if at > floor && !by_router {
                    caught_up.push(notices::exited(row, code, None, at));
                }
            } else if let Some(stamp) = finished_stamp(row).filter(|stamp| *stamp > floor) {
                if row.status == Status::Idle {
                    let reply = row.program_status.as_ref().and_then(|p| p.msg.as_deref());
                    let cause = TurnCause::HostOrUnseen;
                    caught_up.push(notices::finished(row, reply, cause, Some(stamp)));
                }
            }
        }
        for notice in caught_up {
            self.enqueue(router, notice, now);
        }
    }

    /// The rows the auto-stop sweep may consider: never the Router, a
    /// running Router's running Workers, or a Session with undelivered
    /// Inbox items. From the last step's view (the sweep runs first; the
    /// sweeper's own start floor covers the first one).
    pub fn auto_stop_rows<'a>(
        &self,
        rows: &'a [SessionRow],
        drain: &dyn DrainView,
    ) -> Cow<'a, [SessionRow]> {
        let exempt = |row: &SessionRow| {
            self.view.router.as_deref() == Some(row.id.as_str())
                || (self.view.router_running && row.running && self.view.workers.contains(&row.id))
                || drain.has_pending(&row.id)
        };
        if !rows.iter().any(exempt) {
            return Cow::Borrowed(rows);
        }
        Cow::Owned(rows.iter().filter(|row| !exempt(row)).cloned().collect())
    }

    /// `false` when the notice could not be queued.
    fn enqueue(&self, router: &str, notice: NewItem, now: u64) -> bool {
        match self.store.enqueue(router, notice, now) {
            Ok(_) => {
                self.io.announce();
                true
            }
            Err(error) => {
                crate::tracelog::trace(
                    "supervisor",
                    &format!("Worker notice for Router {router} not queued: {error}"),
                );
                false
            }
        }
    }
}

/// One step's row: turns begin and end, waits start and stop.
fn observe(track: &mut Track, row: &SessionRow, now: u64, started_at: u64) {
    let active = |status: Status| matches!(status, Status::Busy | Status::Attention);
    let before = track.status;
    let was_active = before.is_some_and(active);
    if active(row.status) && !was_active {
        // A prompt submitted since the last step dates the turn exactly.
        let started = track
            .prompt_at
            .filter(|at| *at > track.seen_at && *at <= now)
            .unwrap_or(now);
        track.turn = Some(Turn {
            started_at: started.max(started_at),
            watched: before == Some(Status::Idle),
        });
        track.ended_quietly = None;
    }
    if row.status == Status::Busy && before != Some(Status::Busy) {
        track.busy_at = track.busy_at.max(Some(now));
    }
    if !active(row.status) && was_active {
        if let Some(turn) = track.turn.take() {
            let finished = track.finished_at.is_some_and(|at| at >= turn.started_at);
            if row.status == Status::Idle && !finished {
                track.ended_quietly = Some((turn, now));
            }
        }
    }
    if row.status == Status::Attention {
        track.waiting.get_or_insert(Waiting {
            since: now.max(started_at),
            diverted: false,
            escalated: false,
        });
    } else {
        track.waiting = None;
    }
    track.status = Some(row.status);
    track.running = row.running;
    track.seen_at = now;
}

/// What a turn that ended without finishing becomes.
enum QuietEnd {
    WentQuiet(watchdog::Alarm),
    ScreenFinished(NewItem),
}

/// A turn that ended without a Finished edge, checked a step after it
/// ended so an edge one rescan late still counts. Nothing when it did
/// finish, the Router interrupted it, or it is no longer idle. A Worker only
/// its screen (or nothing) speaks for never gets that edge, so its Busy →
/// Idle is a best-guess finish (unless it reported this turn); any other
/// Worker went quiet.
fn quiet_end(
    store: &Store,
    router: &str,
    track: &mut Track,
    row: &SessionRow,
    facts: &TurnFacts,
    compaction: &dyn CompactionView,
    now: u64,
) -> Option<QuietEnd> {
    let (turn, ended_at) = track.ended_quietly.filter(|(_, at)| *at < now)?;
    track.ended_quietly = None;
    let finished = track.finished_at.is_some_and(|at| at >= turn.started_at);
    let interrupted_by_router = facts.touched.is_some_and(|touched| {
        touched <= ended_at && touched + SELF_CAUSED_MS >= ended_at && turn.started_at <= touched
    });
    if finished
        || interrupted_by_router
        || row.status != Status::Idle
        || hosts_compaction(compaction, &row.id, turn.started_at, facts, ended_at)
    {
        return None;
    }
    if !matches!(row.status_source, StatusSource::Screen | StatusSource::None) {
        return Some(QuietEnd::WentQuiet(watchdog::went_quiet(
            turn.started_at,
            ended_at,
        )));
    }
    track.finished_at = Some(ended_at);
    if reported_since(store, router, &row.id, turn.started_at) {
        track.follow_up_owed = false;
        return None;
    }
    let cause = track.settle(turn_cause(&row.id, Some(turn), facts, ended_at));
    Some(QuietEnd::ScreenFinished(notices::screen_finished(
        row,
        turn.started_at,
        cause,
    )))
}

fn evidence(
    track: &Track,
    row: &SessionRow,
    durable: Option<u64>,
    started_at: u64,
) -> watchdog::Evidence {
    let program = row
        .program_status
        .as_ref()
        .map(|program| program.changed_at);
    let progress_at = [track.busy_at, track.hook_at, program, durable]
        .into_iter()
        .flatten()
        .fold(started_at, u64::max);
    watchdog::Evidence {
        status: row.status,
        turn_started_at: track.turn.map(|turn| turn.started_at.max(started_at)),
        waiting_since: track.waiting.map(|waiting| waiting.since.max(started_at)),
        progress_at,
    }
}

/// The Router touched the Worker within `window` before `now`, and the
/// Worker has not gone Busy since: the edge is the Router's own doing.
fn self_caused(track: &Track, touched: Option<u64>, now: u64, window: u64) -> bool {
    touched.is_some_and(|touched| {
        touched <= now
            && touched + window >= now
            && track.busy_at.is_none_or(|busy| busy <= touched)
    })
}

/// What shows who a Worker's turn answers to.
struct TurnFacts<'a> {
    drain: &'a dyn DrainView,
    /// The Router's last write, keypress or stop.
    touched: Option<u64>,
    /// The user's last keystroke, the manifest's `last_input_at`.
    typed_at: Option<u64>,
}

/// The turn is the Host's own compaction (#64) and nobody wrote to the
/// Worker since: its finish or quiet end is nothing to report. Once someone
/// did, the turn may also be their answer (a message queued behind the
/// compaction), so it is reported as usual.
fn hosts_compaction(
    compaction: &dyn CompactionView,
    worker: &str,
    started_at: u64,
    facts: &TurnFacts,
    now: u64,
) -> bool {
    compaction
        .compaction_sent_at(worker, started_at)
        .is_some_and(|sent| {
            !facts.drain.pasted_between(worker, sent, now)
                && facts.touched.is_none_or(|at| at < sent)
                && facts.typed_at.is_none_or(|at| at < sent)
        })
}

/// Who a turn ending at `now` answers to, read through to its end: a Router
/// write the program queued mid-turn is answered by this same turn. The Host
/// comes first, so a reply it may be waiting for never loses its wake to a
/// keystroke.
fn turn_cause(worker: &str, turn: Option<Turn>, facts: &TurnFacts, now: u64) -> TurnCause {
    let Some(turn) = turn.filter(|turn| turn.watched) else {
        return TurnCause::HostOrUnseen;
    };
    let host_from = turn.started_at.saturating_sub(CONFIRM_TIMEOUT_MS);
    let typed_from = turn.started_at.saturating_sub(TYPED_CAUSE_MS);
    if facts.drain.pasted_between(worker, host_from, now)
        || facts
            .touched
            .is_some_and(|at| (host_from..=now).contains(&at))
    {
        TurnCause::HostOrUnseen
    } else if facts
        .typed_at
        .is_some_and(|at| (typed_from..=now).contains(&at))
    {
        TurnCause::UserTyped
    } else {
        TurnCause::Unprompted
    }
}

/// The Worker reported to its Router (a result, not progress) at or after
/// `since`.
fn reported_since(store: &Store, router: &str, worker: &str, since: u64) -> bool {
    store.history(router).is_ok_and(|history| {
        history.iter().any(|header| {
            header.sender == Sender::Session(worker.to_owned())
                && matches!(header.kind, ItemKind::Report | ItemKind::Handover)
                && header.status.as_deref() != Some("progress")
                && header.at >= since
        })
    })
}

/// The program's own finish stamp: stable across Host restarts, so the
/// live notice and a restart's catch-up share one dedupe key.
fn finished_stamp(row: &SessionRow) -> Option<u64> {
    let program = row.program_status.as_ref()?;
    let finished = program.last_finished_at?;
    (program.state.is_finished() || program.last_non_idle_at.is_none_or(|at| finished >= at))
        .then_some(finished)
}

#[cfg(test)]
mod tests;
