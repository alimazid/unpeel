//! Scheduled Tasks in the Host: each workspace worker fires its own
//! workspace's tasks from its tick, app open or not (ADR 0004).

pub mod clock;
pub mod step;
pub mod trigger;
