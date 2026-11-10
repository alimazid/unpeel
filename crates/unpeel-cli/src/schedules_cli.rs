//! `unpeel schedules`: Scheduled Tasks from the shell.
//!
//! Definitions are edited in `app-state.json` under the flock, and
//! announced, like `unpeel presets`; the workspace Host re-reads them every
//! sweep. Run now goes through the live Host, which owns the "a Run is in
//! progress" rule. Creating, running and removing tasks is the user's, and
//! the Super Agent's on their behalf: those verbs refuse inside any other
//! Session (the same detection `unpeel send` uses), as the MCP `workspace`
//! writes do.

use serde_json::{json, Value};
use unpeel_core::schedule_store::TaskStore;
use unpeel_core::schedules::save::{self, SaveRefusal};
use unpeel_core::schedules::{self, Schedule, ScheduleEdit, ScheduleRun, ScheduleTrigger};
use unpeel_serve::schedules::clock;
use unpeel_serve::schedules::trigger;

mod save_host;
use save_host::CliHost;

pub const HELP: &str = "\
usage: unpeel schedules [list] [--json]
       unpeel schedules add <name> --project <id|name> --preset <id|label>
                            <trigger> [--instructions <text>] [--no-notify] [--json]
       unpeel schedules edit <id|name> [--name <name>] [--project <id|name>]
                             [--preset <id|label>] [<trigger>] [--instructions <text>]
                             [--notify | --no-notify] [--json]
       unpeel schedules pause|resume <id|name>
       unpeel schedules run <id|name> [--json]
       unpeel schedules history <id|name> [--json]
       unpeel schedules rm <id|name>

<trigger> is one of:
  --hourly <minute>                every hour at that minute (0-59)
  --daily <HH:MM[:SS]>             every day
  --weekdays <HH:MM[:SS]>          Monday to Friday
  --weekly <day> <HH:MM[:SS]>      one day a week (mon … sun)
  --once <YYYY-MM-DDTHH:MM[:SS]>   once
  --cron '<min> <hour> <day> <month> <weekday>'
                                   a 5-field cron expression (quote it)

A Scheduled Task starts a Session from a preset in a Project each time its
Trigger comes due, on this Host's local wall clock: it follows the system
time zone when the machine travels, a time skipped when clocks go forward
runs when the change ends, and a time repeated when they go back runs once,
on its first pass, for every kind of Trigger, hourly and cron included. The
Host fires it while `unpeel serve` runs, with the app open or not; a time
missed while the Host was down runs once when it is back. `pause` stops a
task firing; `resume` restarts its clock from now, so times that passed
while it was paused never run (a new Trigger counts from the edit the same
way). `run` starts a Run now. Only the user changes tasks, and the Super
Agent for them: add, edit, pause, resume, run and rm refuse inside any other
Session.

A task's Project needs a folder for its Runs to start in, whatever the preset.
A past Once time saves only on a paused task; resuming it needs a new time.

--instructions is for an Agent Preset (one that starts an agent Unpeel can
tell is ready): each Run launches it as typed, types the instructions once
the agent is ready, and follows it to done or needs you. Up to 256 KiB.
`edit --instructions ''` removes them. An Agent Preset task without
instructions is done once its agent is ready.";

struct Args {
    positional: Vec<String>,
    values: std::collections::HashMap<String, String>,
    switches: std::collections::HashSet<String>,
}

const VALUE_FLAGS: &[&str] = &[
    "project",
    "preset",
    "name",
    "hourly",
    "daily",
    "weekdays",
    "once",
    "cron",
    "instructions",
];
/// `--weekly <day> <time>`, kept as one `"<day> <time>"` value.
const WEEKLY: &str = "weekly";
const TRIGGER_FLAGS: &[&str] = &["hourly", "daily", "weekdays", WEEKLY, "once", "cron"];
const SWITCHES: &[&str] = &["json", "notify", "no-notify", "help"];

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
            Some(WEEKLY) => {
                let needs = || "--weekly needs a day and a time: --weekly fri 09:00".to_string();
                let day = items.next().ok_or_else(needs)?;
                // One quoted value (`--weekly "fri 09:00"`) or two.
                let value = if day.trim().contains(' ') {
                    day.trim().to_string()
                } else {
                    format!("{day} {}", items.next().ok_or_else(needs)?)
                };
                parsed.values.insert(WEEKLY.to_string(), value);
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
        "edit" => refuse_inside_session("edit").and_then(|()| edit(&args, json)),
        "pause" => refuse_inside_session("pause").and_then(|()| pause(&args)),
        "resume" => refuse_inside_session("resume").and_then(|()| resume(&args)),
        "run" => refuse_inside_session("run").and_then(|()| run_now(&args, json)),
        "history" => history(&args, json),
        "rm" | "remove" => refuse_inside_session("rm").and_then(|()| remove(&args)),
        _ => Err(HELP.into()),
    }
    .map(|()| 0)
}

fn refuse_inside_session(verb: &str) -> Result<(), String> {
    let caller = unpeel_core::mcp_host::self_session_id();
    if caller.is_some() && !unpeel_core::supervision::is_router(caller.as_deref()) {
        return Err(format!(
            "unpeel schedules {verb}: Scheduled Tasks are changed by the user (or the Super \
             Agent), not from inside a Session"
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
            trigger::describe(&schedule.trigger),
            if schedule.enabled {
                "enabled"
            } else {
                "paused"
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
    let latest = match store.as_ref().map(TaskStore::current_run) {
        Some(Ok(latest)) => latest,
        Some(Err(error)) => {
            eprintln!("warning: {}: {error}", schedule.id);
            None
        }
        None => None,
    };
    let next = trigger::next_run(
        schedule,
        &clock_state.unwrap_or_default(),
        &clock::system_zone(),
    )
    .map(|next| next.strftime("%Y-%m-%d %H:%M:%S").to_string());
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

fn history(args: &Args, json: bool) -> Result<(), String> {
    let schedule = select(args)?;
    let mut runs = TaskStore::for_schedule(&schedule.id)?.runs()?;
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
    // Fork-only (#81): what the Run's own Session last reported.
    if let Some(report) = &run.report {
        line.push_str(&format!(
            "\n    reported {}: {}",
            report.status, report.summary
        ));
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
    let (flag, trigger) = trigger_flag(args)?.ok_or_else(|| {
        format!(
            "give exactly one Trigger: --hourly, --daily, --weekdays, --weekly, --once or --cron\n\n{HELP}"
        )
    })?;
    // A new task is enabled, so its Trigger must come due.
    let trigger = save::check_trigger(&CliHost, &trigger, true)
        .map_err(|refusal| flag_refusal(flag, &refusal))?;
    let notify = notify_flag(args)?.unwrap_or(true);
    let project_id = resolve_project(required(args, "project")?)?;
    let preset_id = resolve_preset(required(args, "preset")?, &project_id)?;
    let instructions = add_instructions(args)?;
    save::check_task_runs(&CliHost, &project_id, &preset_id, instructions.as_deref())
        .map_err(|refusal| refusal.to_string())?;
    let entry = save::new_entry(
        &save::NewTask {
            name: &name,
            project_id: &project_id,
            preset_id: &preset_id,
            trigger: &trigger,
            instructions: instructions.as_deref(),
            enabled: true,
            notify_when_done: notify,
        },
        clock::epoch_ms(&clock::now()),
    );
    unpeel_core::app_state::edit(|state| {
        save::schedules_list_mut(state)?.push(entry.clone());
        Ok(())
    })?;
    if json {
        println!("{entry}");
    } else {
        println!("{}", entry["id"].as_str().unwrap_or_default());
    }
    if !unpeel_serve::driver::is_running() {
        eprintln!(
            "note: no Host is running for this workspace; the task fires once `unpeel serve` runs"
        );
    }
    Ok(())
}

fn add_name(args: &Args) -> Result<String, String> {
    match args.positional.as_slice() {
        [_, name] => schedules::task_name(name),
        _ => Err(format!("unpeel schedules add needs one name\n\n{HELP}")),
    }
}

/// `--notify` or `--no-notify`, if either is given.
fn notify_flag(args: &Args) -> Result<Option<bool>, String> {
    match (
        args.switches.contains("notify"),
        args.switches.contains("no-notify"),
    ) {
        (true, true) => Err("give --notify or --no-notify, not both".into()),
        (on, off) => Ok((on || off).then_some(on)),
    }
}

/// `--instructions`, checked with the rest of the task (`save::check_runnable`:
/// only an Agent Preset takes them, ADR 0005, and no more than a create may
/// type).
fn add_instructions(args: &Args) -> Result<Option<String>, String> {
    let Some(text) = args.values.get("instructions") else {
        return Ok(None);
    };
    if text.trim().is_empty() {
        return Err("--instructions cannot be empty".into());
    }
    Ok(Some(text.clone()))
}

/// The Trigger flag given and its Trigger in the stored form, not yet
/// checked: `add` and `edit` check it by the save rules every writer runs
/// (on this machine's clock, the Host's). `None` when no Trigger flag is
/// given.
fn trigger_flag(args: &Args) -> Result<Option<(&'static str, ScheduleTrigger)>, String> {
    let given: Vec<&str> = TRIGGER_FLAGS
        .iter()
        .copied()
        .filter(|flag| args.values.contains_key(*flag))
        .collect();
    let flag = match given.as_slice() {
        [] => return Ok(None),
        [flag] => *flag,
        _ => {
            let named: Vec<String> = given.iter().map(|flag| format!("--{flag}")).collect();
            return Err(format!(
                "give exactly one Trigger, not {}\n\n{HELP}",
                named.join(" and ")
            ));
        }
    };
    let value = args.values.get(flag).map(String::as_str).unwrap_or("");
    Ok(Some((flag, stored_trigger(flag, value)?)))
}

/// What is wrong with a Trigger flag's value, without the "invalid
/// Trigger" prefix the flag's own name already gives.
fn flag_refusal(flag: &str, refusal: &SaveRefusal) -> String {
    let detail = match refusal {
        SaveRefusal::InvalidTrigger(detail) | SaveRefusal::TriggerInPast(detail) => detail.clone(),
        other => other.to_string(),
    };
    format!("--{flag}: {detail}")
}

/// A Trigger flag's value in the stored form: times and dates without
/// zero seconds, a weekday's full name, a cron expression's fields
/// single-spaced. A value that does not read is passed on as typed, for
/// the save check to say what is wrong with it.
fn stored_trigger(flag: &str, value: &str) -> Result<ScheduleTrigger, String> {
    let time = |raw: &str| {
        clock::parse_time(raw)
            .map(clock::format_time)
            .unwrap_or_else(|| raw.to_string())
    };
    Ok(match flag {
        "hourly" => ScheduleTrigger::Hourly {
            minute: value
                .trim()
                .parse()
                .map_err(|_| format!("--hourly {value:?} is not a minute 0-59"))?,
        },
        "daily" => ScheduleTrigger::Daily { time: time(value) },
        "weekdays" => ScheduleTrigger::Weekdays { time: time(value) },
        WEEKLY => {
            let (day, at) = value.split_once(' ').unwrap_or((value, ""));
            ScheduleTrigger::Weekly {
                weekday: clock::weekday_from_input(day)
                    .map(clock::weekday_name)
                    .map(str::to_string)
                    .unwrap_or_else(|| day.to_string()),
                time: time(at.trim()),
            }
        }
        "once" => ScheduleTrigger::Once {
            at: clock::parse_datetime(value)
                .map(clock::format_datetime)
                .unwrap_or_else(|| value.to_string()),
        },
        "cron" => ScheduleTrigger::Cron {
            expr: value.split_whitespace().collect::<Vec<_>>().join(" "),
        },
        _ => return Err(format!("--{flag} is not a Trigger")),
    })
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
/// global ones, the catalog a Run resolves against.
fn resolve_preset(selector: &str, project_id: &str) -> Result<String, String> {
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
        presets.extend(
            overlay.presets.iter().map(|(label, command)| {
                (format!("overlay-{label}"), label.clone(), command.clone())
            }),
        );
    }
    pick(
        "preset",
        selector,
        presets
            .iter()
            .map(|(id, label, _)| (id.as_str(), label.as_str())),
    )
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

// ── edit / pause / resume ──

fn edit(args: &Args, json: bool) -> Result<(), String> {
    let schedule = select(args)?;
    // Judged by the flags given (every value flag edits a field): the
    // stored Trigger sent back changes nothing, yet is an edit, as on the
    // write routes.
    let edits = !args.values.is_empty()
        || args.switches.contains("notify")
        || args.switches.contains("no-notify");
    if !edits {
        return Err(format!(
            "nothing to change: give --name, --project, --preset, a Trigger, --instructions, \
             --notify or --no-notify\n\n{HELP}"
        ));
    }
    let change = edit_change(args, &schedule)?;
    check_edit_runs(&schedule, &change)?;
    let edited = save_edit(&schedule.id, &change)?;
    if json {
        println!("{}", schedule_json(&edited));
    } else {
        println!("edited {}", display_name(&edited));
    }
    if !edited.enabled {
        eprintln!(
            "note: {} is paused; `unpeel schedules resume {}` runs it again",
            display_name(&edited),
            edited.id
        );
    }
    Ok(())
}

/// What `edit`'s flags change. A new Trigger must still come due while the
/// task is enabled ([`edited_trigger`]); a new preset is looked up in the
/// Project the task will have.
fn edit_change(args: &Args, schedule: &Schedule) -> Result<ScheduleEdit, String> {
    let project_id = args
        .values
        .get("project")
        .map(|selector| resolve_project(selector))
        .transpose()?;
    let in_project = project_id.as_deref().unwrap_or(&schedule.project_id);
    let preset_id = args
        .values
        .get("preset")
        .map(|selector| resolve_preset(selector, in_project))
        .transpose()?;
    Ok(ScheduleEdit {
        name: args
            .values
            .get("name")
            .map(|name| schedules::task_name(name))
            .transpose()?,
        project_id,
        preset_id,
        trigger: edited_trigger(args, schedule)?,
        enabled: None,
        notify_when_done: notify_flag(args)?,
        // Absent: unchanged; empty: removed; text: set.
        instructions: args
            .values
            .get("instructions")
            .map(|text| (!text.trim().is_empty()).then(|| text.clone())),
    })
}

/// `edit`'s Trigger by the save rule the write routes run
/// (`save::check_edited_trigger`): the one the task stores, sent back, is
/// no change and is not checked again; a different one must come due while
/// the task is enabled (`edit` never resumes it).
fn edited_trigger(args: &Args, schedule: &Schedule) -> Result<Option<ScheduleTrigger>, String> {
    let Some((flag, trigger)) = trigger_flag(args)? else {
        return Ok(None);
    };
    let given = serde_json::to_value(&trigger).map_err(|error| error.to_string())?;
    let stored = stored_trigger_value(&schedule.id)?;
    save::check_edited_trigger(&CliHost, Some(&given), stored.as_ref(), schedule.enabled)
        .map_err(|refusal| flag_refusal(flag, &refusal))
}

/// The task's Trigger as `app-state.json` stores it, the form an edit's
/// Trigger is compared in. Read before the edit takes the flock, as the
/// write routes read it: the edit itself is applied under it.
fn stored_trigger_value(schedule_id: &str) -> Result<Option<Value>, String> {
    let state = unpeel_core::app_state::load()?;
    let list = state.get("schedules").and_then(Value::as_array);
    Ok(save::entry(list.map_or(&[], Vec::as_slice), schedule_id)
        .and_then(|entry| entry.get("trigger"))
        .cloned())
}

/// A new Project, preset or instructions must still make a task the Host
/// would run (`save::check_runnable`), as the write routes check it.
fn check_edit_runs(schedule: &Schedule, change: &ScheduleEdit) -> Result<(), String> {
    let changes_the_run = change.project_id.is_some()
        || change.preset_id.is_some()
        || matches!(change.instructions, Some(Some(_)));
    if !changes_the_run {
        return Ok(());
    }
    let instructions = match &change.instructions {
        Some(given) => given.as_deref(),
        None => schedule.instructions.as_deref(),
    };
    save::check_task_runs(
        &CliHost,
        change.project_id.as_deref().unwrap_or(&schedule.project_id),
        change.preset_id.as_deref().unwrap_or(&schedule.preset_id),
        instructions,
    )
    .map_err(|refusal| match (&refusal, &change.instructions) {
        (SaveRefusal::NotAgentPreset(_), None) => {
            format!("{refusal}; the task has instructions: remove them with --instructions ''")
        }
        _ => refusal.to_string(),
    })
}

fn pause(args: &Args) -> Result<(), String> {
    let schedule = select(args)?;
    if !schedule.enabled {
        println!("{} is already paused", display_name(&schedule));
        return Ok(());
    }
    let paused = save_edit(&schedule.id, &enabled(false))?;
    println!("paused {}", display_name(&paused));
    Ok(())
}

/// Resume restarts the task's clock from now: what fell while it was
/// paused never runs. The Trigger it keeps must still come due
/// (`save::check_resume`): a Once time that has passed needs a new one.
fn resume(args: &Args) -> Result<(), String> {
    let schedule = select(args)?;
    if schedule.enabled {
        println!("{} is not paused", display_name(&schedule));
        return Ok(());
    }
    match save::check_resume(&CliHost, &schedule.trigger) {
        Ok(()) => {}
        Err(refusal @ SaveRefusal::ResumeInPast(_)) => {
            return Err(format!(
                "cannot resume {}: {refusal} with `unpeel schedules edit {} --once …`",
                display_name(&schedule),
                schedule.id
            ))
        }
        Err(refusal) => return Err(format!("cannot resume: {refusal}")),
    }
    let resumed = save_edit(&schedule.id, &enabled(true))?;
    let next = schedule_json(&resumed)["next_run"]
        .as_str()
        .map(|next| format!("; next run {next}"))
        .unwrap_or_default();
    println!("resumed {}{next}", display_name(&resumed));
    Ok(())
}

fn enabled(enabled: bool) -> ScheduleEdit {
    ScheduleEdit {
        enabled: Some(enabled),
        ..ScheduleEdit::default()
    }
}

/// Apply `change` to the task's entry under the `app-state.json` flock
/// (announced, so the Host re-reads it), and return the task as saved.
fn save_edit(schedule_id: &str, change: &ScheduleEdit) -> Result<Schedule, String> {
    let now_ms = clock::epoch_ms(&clock::now());
    let saved = unpeel_core::app_state::edit(|state| {
        let list = save::schedules_list_mut(state)?;
        let entry = save::entry_mut(list, schedule_id)
            .ok_or_else(|| format!("no Scheduled Task {schedule_id}; it was removed"))?;
        *entry = schedules::apply_edit(entry, change, now_ms);
        Ok(Value::Object(entry.clone()))
    })?;
    schedules::schedules_from_value(Some(&Value::Array(vec![saved])))
        .pop()
        .ok_or_else(|| format!("Scheduled Task {schedule_id} no longer reads"))
}

fn display_name(schedule: &Schedule) -> &str {
    if schedule.name.trim().is_empty() {
        &schedule.id
    } else {
        &schedule.name
    }
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
        save::schedules_list_mut(state)?
            .retain(|entry| entry.get("id").and_then(Value::as_str) != Some(schedule.id.as_str()));
        Ok(())
    })?;
    TaskStore::for_schedule(&schedule.id)?.remove()?;
    println!("removed {}", schedule.name);
    Ok(())
}

#[cfg(test)]
mod tests {
    /// The help is a compile-time string; this keeps its cap the one the
    /// save rules enforce.
    #[test]
    fn the_help_states_the_instructions_cap() {
        let limit = unpeel_core::schedules::save::instructions_limit();
        assert!(super::HELP.contains(&format!("Up to {limit}.")), "{limit}");
    }

    /// The two save rules every writer runs (`save` module docs), a line
    /// each.
    #[test]
    fn the_help_states_the_save_rules() {
        let lines: Vec<&str> = super::HELP.lines().collect();
        for rule in [
            ["needs a folder", "whatever the preset"],
            ["past Once", "paused task"],
        ] {
            assert!(
                lines
                    .iter()
                    .any(|line| rule.iter().all(|words| line.contains(words))),
                "{rule:?}"
            );
        }
    }

    /// ADR 0007: one rule for every kind on the night clocks go back, and
    /// the spring-forward rule beside it. The help wraps lines, so match
    /// with whitespace collapsed.
    #[test]
    fn the_help_states_the_clock_change_rules() {
        let help = super::HELP.split_whitespace().collect::<Vec<_>>().join(" ");
        for rule in [
            "a time skipped when clocks go forward runs when the change ends",
            "a time repeated when they go back runs once, on its first pass, \
             for every kind of Trigger, hourly and cron included",
        ] {
            assert!(help.contains(rule), "{rule:?} in {help:?}");
        }
    }
}
