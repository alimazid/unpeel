//! The workspace worker as the Controller write routes' `ScheduleHost`
//! (`unpeel_core::controller_schedules`): what those routes cannot do from
//! the disk alone. Triggers are checked on this Host's wall clock, Projects
//! and presets come from the catalog its Runs resolve against, and Run now
//! goes to the scheduler on the driver thread, which owns the "a Run is in
//! progress" rule (the same request `unpeel schedules run` sends).

use std::sync::{mpsc, Arc};
use std::time::Duration;

use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::controller_schedules::{NextRun, RunNowRefusal, ScheduleHost};
use unpeel_core::schedules::save::{SaveHost, TriggerRefusal};
use unpeel_core::schedules::{Schedule, ScheduleClock, ScheduleTrigger};

use super::{clock, trigger};
use crate::local_gateway::LocalControlRequest;
use crate::mobile::SharedSnapshot;

/// How long a Run now waits for the driver's answer; it answers at once
/// from its tick, so only a stalled worker reaches this.
const RUN_NOW_ANSWER: Duration = Duration::from_secs(5);

pub(crate) struct WorkerHost {
    snapshot: SharedSnapshot,
    control: mpsc::Sender<LocalControlRequest>,
}

impl WorkerHost {
    /// Serve the write routes from this worker (local socket, `/mobile`,
    /// Link) from now on.
    pub(crate) fn install(snapshot: SharedSnapshot, control: mpsc::Sender<LocalControlRequest>) {
        unpeel_core::controller_schedules::install_host(Arc::new(Self { snapshot, control }));
    }
}

impl SaveHost for WorkerHost {
    fn catalog(&self) -> Option<(Vec<HostCreateProject>, Vec<HostCreatePreset>)> {
        crate::mobile::create_catalog(&self.snapshot)
    }

    fn check_trigger(
        &self,
        trigger: &ScheduleTrigger,
        comes_due: bool,
    ) -> Result<ScheduleTrigger, TriggerRefusal> {
        trigger::for_save(trigger, comes_due, clock::now().datetime())
    }
}

impl ScheduleHost for WorkerHost {
    fn next_run(&self, schedule: &Schedule, clock_state: &ScheduleClock) -> Option<NextRun> {
        let now = clock::now();
        trigger::published_next_run(schedule, clock_state, now.time_zone())
            .map(|(at, at_ms)| NextRun { at, at_ms })
    }

    fn run_now(&self, schedule_id: &str) -> Result<String, RunNowRefusal> {
        run_now(&self.control, schedule_id)
    }
}

/// Run now through the scheduler on the driver thread: its Run id, or the
/// scheduler's refusal as it typed it. The Controller route (through
/// [`WorkerHost`]) and `unpeel schedules run`'s control path both ask here,
/// so they refuse alike.
pub(crate) fn run_now(
    control: &mpsc::Sender<LocalControlRequest>,
    schedule_id: &str,
) -> Result<String, RunNowRefusal> {
    let (reply, answer) = mpsc::sync_channel(1);
    let request = LocalControlRequest::RunScheduleNow {
        schedule_id: schedule_id.to_owned(),
        reply,
    };
    if control.send(request).is_err() {
        return Err(RunNowRefusal::Unavailable(
            "the Host's scheduler is not running".into(),
        ));
    }
    answer.recv_timeout(RUN_NOW_ANSWER).unwrap_or_else(|_| {
        Err(RunNowRefusal::NoAnswer(
            "the Host did not answer in time; the Run may still start".into(),
        ))
    })
}

/// Fixtures for the Run now wires' tests (here and `local_gateway`).
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::schedules::agent_run::Delivery;
    use crate::schedules::runner::{Effects, Scheduler, SessionSeen, SpawnRequest};

    /// The driver's answer to Run now (`driver.rs` `RunScheduleNow`) on its
    /// own thread, with `schedules` as the definitions it read, for the
    /// first `answers` requests.
    pub(crate) fn run_now_driver(
        root: std::path::PathBuf,
        schedules: Vec<Schedule>,
        answers: usize,
    ) -> mpsc::Sender<LocalControlRequest> {
        let (control, inbox) = mpsc::channel();
        std::thread::spawn(move || {
            let mut scheduler = Scheduler::new(root, Arc::new(NoEffects));
            for _ in 0..answers {
                let Ok(LocalControlRequest::RunScheduleNow { schedule_id, reply }) = inbox.recv()
                else {
                    return;
                };
                let _ = reply.send(scheduler.request_run_now(&schedule_id, &schedules));
            }
        });
        control
    }

    pub(crate) fn morning() -> Schedule {
        serde_json::from_value(serde_json::json!({
            "id": "sch_1",
            "name": "Morning",
            "project_id": "p",
            "preset_id": "ok",
            "trigger": { "kind": "daily", "time": "09:00" },
        }))
        .expect("a schedule")
    }

    /// Run now only reads the task's store; it never sweeps, so it never
    /// reaches the Host's Sessions or `app-state.json`.
    struct NoEffects;

    impl Effects for NoEffects {
        fn spawn(&self, _: SpawnRequest) -> Result<(), String> {
            unreachable!("Run now starts nothing")
        }
        fn deliver(&self, _: &str, _: Option<&str>) -> Delivery {
            unreachable!("Run now delivers nothing")
        }
        fn session(&self, _: &str) -> (SessionSeen, Option<i32>) {
            unreachable!("Run now observes no Session")
        }
        fn screen_reply(&self, _: &str, _: &str) -> Option<String> {
            unreachable!("Run now reads no screen")
        }
        fn run_report(&self, _: &str) -> Option<unpeel_core::schedules::RunReport> {
            unreachable!("Run now reads no report")
        }
        fn disable(&self, _: &str) -> Result<(), String> {
            unreachable!("Run now turns nothing off")
        }
        fn is_defined(&self, _: &str) -> Result<bool, String> {
            unreachable!("Run now writes no task state")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{morning, run_now_driver};
    use super::*;

    fn host(control: mpsc::Sender<LocalControlRequest>) -> WorkerHost {
        WorkerHost {
            snapshot: SharedSnapshot::default(),
            control,
        }
    }

    /// #28: a Run log that will not read is refused for its own reason, not
    /// as "a Run is still in progress".
    #[test]
    fn an_unreadable_run_log_is_refused_for_its_own_reason() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("sch_1").join("runs.jsonl")).unwrap();
        let host = host(run_now_driver(
            root.path().to_path_buf(),
            vec![morning()],
            1,
        ));
        let result = host.run_now("sch_1");
        assert!(
            matches!(&result, Err(RunNowRefusal::RunLogUnreadable(message))
                if message.contains("Morning") && message.contains("runs.jsonl")),
            "{result:?}"
        );
    }

    /// A task deleted between the route's check and the driver's answer.
    #[test]
    fn a_task_gone_by_the_time_the_driver_answers_is_unknown() {
        let root = tempfile::tempdir().unwrap();
        let host = host(run_now_driver(root.path().to_path_buf(), Vec::new(), 1));
        let result = host.run_now("sch_1");
        assert!(
            matches!(&result, Err(RunNowRefusal::UnknownTask(message)) if message.contains("sch_1")),
            "{result:?}"
        );
    }

    /// A Run really in progress (here: one already queued) still is.
    #[test]
    fn a_run_already_queued_is_in_progress() {
        let root = tempfile::tempdir().unwrap();
        let host = host(run_now_driver(
            root.path().to_path_buf(),
            vec![morning()],
            2,
        ));
        assert!(host.run_now("sch_1").unwrap().starts_with("run_"));
        let result = host.run_now("sch_1");
        assert!(
            matches!(&result, Err(RunNowRefusal::InProgress(message)) if message.contains("in progress")),
            "{result:?}"
        );
    }

    #[test]
    fn no_driver_to_ask_is_unavailable() {
        let host = host(mpsc::channel().0);
        assert!(
            matches!(host.run_now("sch_1"), Err(RunNowRefusal::Unavailable(_))),
            "the request never reached a worker"
        );
    }
}
