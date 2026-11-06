//! The workspace worker as the Controller write routes' `ScheduleHost`
//! (`unpeel_core::controller_schedules`): what those routes cannot do from
//! the disk alone. Triggers are checked on this Host's wall clock, Projects
//! and presets come from the catalog its Runs resolve against, and Run now
//! goes to the scheduler on the driver thread, which owns the "a Run is in
//! progress" rule (the same request `unpeel schedules run` sends).

use std::sync::{mpsc, Arc};
use std::time::Duration;

use unpeel_core::controller_api::{HostCreatePreset, HostCreateProject};
use unpeel_core::controller_schedules::{RunNowRefusal, ScheduleHost};
use unpeel_core::schedules::save::{SaveHost, TriggerRefusal};
use unpeel_core::schedules::ScheduleTrigger;

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
    fn run_now(&self, schedule_id: &str) -> Result<String, RunNowRefusal> {
        let (reply, answer) = mpsc::sync_channel(1);
        let request = LocalControlRequest::RunScheduleNow {
            schedule_id: schedule_id.to_owned(),
            reply,
        };
        if self.control.send(request).is_err() {
            return Err(RunNowRefusal::Unavailable(
                "the Host's scheduler is not running".into(),
            ));
        }
        match answer.recv_timeout(RUN_NOW_ANSWER) {
            Ok(Ok(started)) => started
                .get("runID")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| RunNowRefusal::NoAnswer("the Host omitted the Run id".into())),
            Ok(Err(refused)) => Err(RunNowRefusal::InProgress(refused)),
            Err(_) => Err(RunNowRefusal::NoAnswer(
                "the Host did not answer in time; the Run may still start".into(),
            )),
        }
    }
}
