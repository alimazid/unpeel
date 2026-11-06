//! `unpeel schedules`: Scheduled Tasks from the shell.
//!
//! Definitions are edited in `app-state.json` under the flock, and
//! announced, like `unpeel presets`; the workspace Host re-reads them every
//! sweep. Run now goes through the live Host, which owns the "a Run is in
//! progress" rule. Creating, running and removing tasks is the user's:
//! those verbs refuse inside a Session (the same detection `unpeel send`
//! uses).

use serde_json::{json, Map, Value};
use unpeel_core::schedule_store::TaskStore;
use unpeel_core::schedules::{Schedule, ScheduleRun, ScheduleTrigger};
use unpeel_serve::schedules::clock;
use unpeel_serve::schedules::trigger::Trigger;

pub const HELP: &str = "\
usage: unpeel schedules [list] [--json]
       unpeel schedules add <name> --project <id|name> --preset <id|label>
                            (--once <YYYY-MM-DDTHH:MM[:SS]> | --daily <HH:MM[:SS]>)
                            [--instructions <text>] [--no-notify] [--json]
       unpeel schedules run <id|name> [--json]
       unpeel schedules history <id|name> [--json]
       unpeel schedules rm <id|name>

A Scheduled Task starts a Session from a preset in a Project each time its
Trigger comes due, on this Host's local wall clock. The Host fires it while
`unpeel serve` runs, with the app open or not; a time missed while the Host
was down runs once when it is back. `run` starts a Run now. Only the user
changes tasks: add, run and rm refuse inside a Session.

--instructions is for an Agent Preset (one that starts an agent Unpeel can
tell is ready): each Run launches it as typed, types the instructions once
the agent is ready, and follows it to done or needs you. Up to 256 KiB.";

/// Most characters a task name keeps.
const MAX_NAME_CHARS: usize = 200;

struct Args {
    positional: Vec<String>,
    values: std::collections::HashMap<String, String>,
    switches: std::collections::HashSet<String>,
}

const VALUE_FLAGS: &[&str] = &["project", "preset", "once", "daily", "instructions"];
const SWITCHES: &[&str] = &["json", "no-notify", "help"];

fn parse(args: &[String]) -> Result<Args, String> {
    let mut parsed = Args {
        positional: Vec::new(),
        values: Default::default(),
        switches: Default::default(),
    };
    let mut items = args.iter();
    while let Some(arg) = items.next() {
        match arg.strip_prefix("--") {
            Some(flag) if VALUE_FLAGS.contains(&flag) => {
                let value = items
                    .next()
                    .ok_or_else(|| format!("--{flag} needs a value"))?;
                parsed.values.insert(flag.to_string(), value.clone());
            }
            Some(flag) if SWITCHES.contains(&flag) => {
                parsed.switches.insert(flag.to_string());
            }
            Some(flag) => return Err(format!("unknown option --{flag}\n\n{HELP}")),
            None if arg == "-h" => {
                parsed.switches.insert("help".into());
            }
            None => parsed.positional.push(arg.clone()),
        }
    }
    Ok(parsed)
}

pub fn run(args: &[String]) -> Result<i32, String> {
    let args = parse(args)?;
    let verb = args
        .positional
        .first()
        .map(String::as_str)
        .unwrap_or("list");
    if args.switches.contains("help") || verb == "help" {
        println!("{HELP}");
        return Ok(0);
    }
    let json = args.switches.contains("json");
    match verb {
        "list" | "ls" => list(json),
        "add" => refuse_inside_session("add").and_then(|()| add(&args, json)),
        "run" => refuse_inside_session("run").and_then(|()| run_now(&args, json)),
        "history" => history(&args, json),
        "rm" | "remove" => refuse_inside_session("rm").and_then(|()| remove(&args)),
        _ => Err(HELP.into()),
    }
    .map(|()| 0)
}

fn refuse_inside_session(verb: &str) -> Result<(), String> {
    if crate::mcp_cli::inside_session() {
        return Err(format!(
            "unpeel schedules {verb}: Scheduled Tasks are changed by the user, not from inside a Session"
        ));
    }
    Ok(())
}

// ── list / history ──

fn list(json: bool) -> Result<(), String> {
    let schedules = unpeel_core::schedule_store::load_schedules()?;
    let rows: Vec<Value> = schedules.iter().map(schedule_json).collect();
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&rows).unwrap_or_default()
        );
        return Ok(());
    }
    if schedules.is_empty() {
        println!("no Scheduled Tasks");
    }
    for (schedule, row) in schedules.iter().zip(&rows) {
        println!(
            "{}  {:24}  {:24}  {:8}  next {:19}  last {}",
            schedule.id,
            schedule.name.chars().take(24).collect::<String>(),
            trigger_label(&schedule.trigger),
            if schedule.enabled {
                "enabled"
            } else {
                "disabled"
            },
            row["next_run"].as_str().unwrap_or("-"),
            row["last_run"]["status"].as_str().unwrap_or("-"),
        );
    }
    Ok(())
}

fn schedule_json(schedule: &Schedule) -> Value {
    let store = TaskStore::for_schedule(&schedule.id).ok();
    let clock_state = store.as_ref().and_then(|store| store.clock().ok());
    let latest = store.as_ref().and_then(TaskStore::latest_run);
    let next = next_run(schedule, clock_state.as_ref());
    json!({
        "id": schedule.id,
        "name": schedule.name,
        "project_id": schedule.project_id,
        "preset_id": schedule.preset_id,
        "instructions": schedule.instructions,
        "trigger": schedule.trigger,
        "enabled": schedule.enabled,
        "notify_when_done": schedule.notify_when_done,
        "created_at_ms": schedule.created_at_ms,
        "next_run": next,
        "last_run": latest.map(|run| json!({ "run_id": run.run_id, "status": run.status })),
    })
}

/// The next occurrence the Host will fire, as local time in this Host's
/// zone.
fn next_run(
    schedule: &Schedule,
    clock_state: Option<&unpeel_core::schedules::ScheduleClock>,
) -> Option<String> {
    let trigger = Trigger::parse(&schedule.trigger).filter(|_| schedule.enabled)?;
    let after = clock_state
        .and_then(|clock_state| clock_state.last_occurrence.as_deref())
        .and_then(clock::parse_datetime)
        .or_else(|| clock::civil_at_ms(schedule.created_at_ms, &clock::system_zone()))?;
    let next = trigger.next_after(after)?;
    Some(next.strftime("%Y-%m-%d %H:%M:%S").to_string())
}

fn trigger_label(trigger: &ScheduleTrigger) -> String {
    match trigger {
        ScheduleTrigger::Once { at } => format!("once {at}"),
        ScheduleTrigger::Daily { time } => format!("daily {time}"),
        ScheduleTrigger::Unknown => "unknown (never fires)".into(),
    }
}

fn history(args: &Args, json: bool) -> Result<(), String> {
    let schedule = select(args)?;
    let mut runs = TaskStore::for_schedule(&schedule.id)?.runs();
    runs.reverse();
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&runs).unwrap_or_default()
        );
        return Ok(());
    }
    if runs.is_empty() {
        println!("no Runs of {} yet", schedule.name);
    }
    for run in &runs {
        println!("{}", run_line(run));
    }
    Ok(())
}

fn run_line(run: &ScheduleRun) -> String {
    let mut line = format!(
        "{}  {:15}  {}",
        run.run_id,
        run.status.word(),
        run.scheduled_for.as_deref().unwrap_or("run now")
    );
    if let Some(phase) = run.phase.filter(|_| run.status.is_in_progress()) {
        line.push_str(&format!("  ({})", phase.word()));
    }
    if run.late {
        line.push_str("  late");
    }
    if let Some(started) = run.started_at_ms.and_then(local_time) {
        line.push_str(&format!("  started {started}"));
    }
    if let Some(ended) = run.ended_at_ms.and_then(local_time) {
        line.push_str(&format!("  ended {ended}"));
    }
    if let Some(code) = run.exit_code {
        line.push_str(&format!("  exit {code}"));
    }
    if let Some(session) = &run.session_id {
        line.push_str(&format!("  session {session}"));
    }
    if let Some(reason) = &run.reason {
        line.push_str(&format!("  ({reason})"));
    }
    if let Some(snippet) = &run.snippet {
        line.push_str(&format!("\n    {snippet}"));
    }
    line
}

fn local_time(ms: u64) -> Option<String> {
    clock::civil_at_ms(ms, &clock::system_zone())
        .map(|civil| civil.strftime("%Y-%m-%d %H:%M:%S").to_string())
}

// ── add ──

fn add(args: &Args, json: bool) -> Result<(), String> {
    let name = add_name(args)?;
    let trigger = add_trigger(args)?;
    let project_id = resolve_project(required(args, "project")?)?;
    let (preset_id, preset_command) = resolve_preset(required(args, "preset")?, &project_id)?;
    let instructions = add_instructions(args, &preset_id, &preset_command)?;
    let id = format!("sch_{}", uuid::Uuid::new_v4());
    let mut entry = json!({
        "id": id,
        "name": name,
        "project_id": project_id,
        "preset_id": preset_id,
        "trigger": trigger,
        "enabled": true,
        "notify_when_done": !args.switches.contains("no-notify"),
        "created_at_ms": clock::epoch_ms(&clock::now()),
    });
    if let Some(instructions) = instructions {
        entry["instructions"] = Value::String(instructions);
    }
    unpeel_core::app_state::edit(|state| {
        schedules_mut(state)?.push(entry.clone());
        Ok(())
    })?;
    if json {
        println!("{entry}");
    } else {
        println!("{id}");
    }
    if !unpeel_serve::driver::is_running() {
        eprintln!(
            "note: no Host is running for this workspace; the task fires once `unpeel serve` runs"
        );
    }
    Ok(())
}

fn add_name(args: &Args) -> Result<String, String> {
    let name = args.positional.get(1).map(|name| name.trim()).unwrap_or("");
    if name.is_empty() || args.positional.len() > 2 {
        return Err(format!("unpeel schedules add needs one name\n\n{HELP}"));
    }
    if name.chars().any(char::is_control) {
        return Err("a task name cannot contain control characters".into());
    }
    Ok(name.chars().take(MAX_NAME_CHARS).collect())
}

fn add_trigger(args: &Args) -> Result<ScheduleTrigger, String> {
    match (args.values.get("once"), args.values.get("daily")) {
        (Some(at), None) => {
            let at = clock::parse_datetime(at).ok_or_else(|| {
                format!("--once {at:?} is not a local date-time YYYY-MM-DDTHH:MM[:SS]")
            })?;
            if at <= clock::now().datetime() {
                return Err(format!(
                    "--once {} is in the past",
                    clock::format_datetime(at)
                ));
            }
            Ok(ScheduleTrigger::Once {
                at: clock::format_datetime(at),
            })
        }
        (None, Some(time)) => {
            let time = clock::parse_time(time)
                .ok_or_else(|| format!("--daily {time:?} is not a local time HH:MM[:SS]"))?;
            Ok(ScheduleTrigger::Daily {
                time: clock::format_time(time),
            })
        }
        _ => Err(format!(
            "give exactly one Trigger: --once or --daily\n\n{HELP}"
        )),
    }
}

/// `--instructions`: only an Agent Preset takes them (ADR 0005), and no more
/// than a create may type.
fn add_instructions(args: &Args, preset_id: &str, command: &str) -> Result<Option<String>, String> {
    let Some(text) = args.values.get("instructions") else {
        return Ok(None);
    };
    if text.trim().is_empty() {
        return Err("--instructions cannot be empty".into());
    }
    if text.len() > unpeel_core::initial_text::MAX_INITIAL_TEXT_BYTES {
        return Err("--instructions are longer than 256 KiB".into());
    }
    if !unpeel_core::agent_readiness::is_agent_command(command) {
        return Err(format!(
            "the preset {preset_id} is not an Agent Preset: its command ({command}) does not \
             start an agent Unpeel can tell is ready, so it cannot take --instructions"
        ));
    }
    Ok(Some(text.clone()))
}

fn required<'a>(args: &'a Args, flag: &str) -> Result<&'a str, String> {
    args.values
        .get(flag)
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("unpeel schedules add needs --{flag}\n\n{HELP}"))
}

/// A Project by id, then by unique name, from `app-state.json` and the app's
/// own projects alike.
fn resolve_project(selector: &str) -> Result<String, String> {
    let state = unpeel_serve::sessions::load_app_state();
    let overlay = unpeel_serve::overlay::load();
    let mut projects: Vec<(String, String)> = state
        .iter()
        .flat_map(|state| &state.projects)
        .map(|project| (project.id.clone(), project.name.clone()))
        .collect();
    if let Some(overlay) = &overlay {
        projects.extend(overlay.projects.iter().cloned());
    }
    pick(
        "Project",
        selector,
        projects
            .iter()
            .map(|(id, name)| (id.as_str(), name.as_str())),
    )
}

/// An enabled preset by id, then by unique label: the Project's own and the
/// global ones, the catalog a Run resolves against. Its id and command.
fn resolve_preset(selector: &str, project_id: &str) -> Result<(String, String), String> {
    let state = unpeel_serve::sessions::load_app_state();
    let mut stored: Vec<_> = state
        .iter()
        .flat_map(|state| &state.presets)
        .filter(|preset| {
            preset.enabled
                && preset
                    .project_id
                    .as_deref()
                    .is_none_or(|id| id == project_id)
        })
        .collect();
    // The Project's own preset comes first, as when a Run resolves it.
    stored.sort_by_key(|preset| preset.project_id.is_none());
    // (id, label, command)
    let mut presets: Vec<(String, String, String)> = stored
        .into_iter()
        .map(|preset| {
            (
                preset.id.clone(),
                preset.label.clone(),
                preset.command.clone(),
            )
        })
        .collect();
    if let Some(overlay) = unpeel_serve::overlay::load() {
        presets.extend(overlay.presets.iter().map(|(label, command)| {
            (format!("overlay-{label}"), label.clone(), command.clone())
        }));
    }
    let id = pick(
        "preset",
        selector,
        presets
            .iter()
            .map(|(id, label, _)| (id.as_str(), label.as_str())),
    )?;
    let command = presets
        .iter()
        .find(|(candidate, _, _)| *candidate == id)
        .map(|(_, _, command)| command.clone())
        .unwrap_or_default();
    Ok((id, command))
}

/// The id `selector` names: an exact id first, then a unique name.
fn pick<'a>(
    what: &str,
    selector: &str,
    candidates: impl Iterator<Item = (&'a str, &'a str)> + Clone,
) -> Result<String, String> {
    if let Some((id, _)) = candidates.clone().find(|(id, _)| *id == selector) {
        return Ok(id.to_string());
    }
    let named: Vec<&str> = candidates
        .filter(|(_, name)| *name == selector)
        .map(|(id, _)| id)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    match named.as_slice() {
        [id] => Ok(id.to_string()),
        [] => Err(format!("no {what} with id or name {selector:?}")),
        _ => Err(format!(
            "more than one {what} is named {selector:?}; use its id"
        )),
    }
}

fn schedules_mut(state: &mut Map<String, Value>) -> Result<&mut Vec<Value>, String> {
    state
        .entry("schedules")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or_else(|| "app-state.json schedules is not a list; not changing it".to_string())
}

// ── run / rm ──

/// The task a verb names: its id, or its unique name.
fn select(args: &Args) -> Result<Schedule, String> {
    let selector = match args.positional.as_slice() {
        [_, selector] => selector.as_str(),
        _ => return Err(format!("name one task by id or name\n\n{HELP}")),
    };
    let schedules = unpeel_core::schedule_store::load_schedules()?;
    let id = pick(
        "Scheduled Task",
        selector,
        schedules
            .iter()
            .map(|schedule| (schedule.id.as_str(), schedule.name.as_str())),
    )?;
    schedules
        .into_iter()
        .find(|schedule| schedule.id == id)
        .ok_or_else(|| format!("no Scheduled Task {selector:?}"))
}

fn run_now(args: &Args, json: bool) -> Result<(), String> {
    let schedule = select(args)?;
    if !unpeel_serve::driver::is_running() {
        return Err(
            "no Host is running for this workspace; start it with `unpeel serve` and retry".into(),
        );
    }
    let home = unpeel_core::app_paths::unpeel_home();
    let run_id = unpeel_serve::local_gateway::run_schedule_now(&home, &schedule.id)?;
    if json {
        println!(
            "{}",
            json!({ "schedule_id": schedule.id, "run_id": run_id })
        );
    } else {
        println!("{run_id}");
    }
    Ok(())
}

/// Delete the task and its history. Its Run Sessions stay where they are.
fn remove(args: &Args) -> Result<(), String> {
    let schedule = select(args)?;
    unpeel_core::app_state::edit(|state| {
        schedules_mut(state)?
            .retain(|entry| entry.get("id").and_then(Value::as_str) != Some(schedule.id.as_str()));
        Ok(())
    })?;
    TaskStore::for_schedule(&schedule.id)?.remove()?;
    println!("removed {}", schedule.name);
    Ok(())
}
