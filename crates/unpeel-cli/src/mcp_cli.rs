//! The `unpeel` CLI as a full peer of the unified `unpeel` MCP server.
//!
//! Every verb here runs the same in-process tool dispatcher the MCP server
//! uses (`unpeel_core::mcp_host::call_tool`): the same caller identity from
//! the hosted environment, the same per-call grants, and the same
//! cooperative write policy with its approval prompt. `unpeel mcp <tool>
//! <action> key=value…` reaches every action of every domain; the family
//! verbs (`browser`, `artifacts`, `current`, `report`, `worktree`, `agents`,
//! `skills`) are positional sugar over it.

use serde_json::{json, Map, Value};

pub const HELP: &str = "\
unpeel mcp — every Unpeel MCP action from the shell

  unpeel mcp                          list the tools
  unpeel mcp <tool>                   the tool's help (same text the MCP serves)
  unpeel mcp <tool> <action> [key=value ...] [--json '{...}']

Arguments are key=value pairs; a value that parses as JSON (true, 42,
[\"down\",\"enter\"], {\"a\":1}) is passed as JSON, anything else as a string.
--json merges a whole JSON object. The call runs as the session you are in
(UNPEEL_SESSION_ID or process ancestry), with the same grants and approval
prompts an agent's MCP call gets. Outside an Unpeel session most actions
refuse, exactly like the MCP server.

Family verbs over the same dispatcher:
  unpeel browser open <url> | snapshot | click <target> | fill <target> <text>
                 | type <target> <text> | press <key> | get <what> [target]
                 | screenshot [--full] [--annotate] | scroll <direction>
                 | wait [selector=… | load=… | ms=…] | <action> [key=value ...]
  unpeel artifacts publish <image-path>
  unpeel current                      you and your pane neighbors (App context)
  unpeel report <summary> --to <id|super_agent>
                 [--status update|progress|done|blocked] [--details TEXT]
  unpeel worktree create <name> [--branch B] [--base REF] [--project ID]
  unpeel agents <action> [key=value ...]
  unpeel skills <action> [key=value ...]
  unpeel apps describe|search|context [key=value ...]
  unpeel send / unpeel keys           inside a session: sessions send_text /
                                      send_keys with the approval policy";

/// Split `words` into a JSON argument object (from `key=value` pairs and
/// `--json`) and the remaining positional words, in order.
pub fn parse_args(words: &[String]) -> Result<(Map<String, Value>, Vec<String>), String> {
    let mut arguments = Map::new();
    let mut positional = Vec::new();
    let mut iter = words.iter();
    while let Some(word) = iter.next() {
        if word == "--json" {
            let raw = iter.next().ok_or("--json needs a JSON object")?;
            let value: Value = serde_json::from_str(raw)
                .map_err(|error| format!("--json is not valid JSON: {error}"))?;
            let object = value.as_object().ok_or("--json must be a JSON object")?;
            for (key, value) in object {
                arguments.insert(key.clone(), value.clone());
            }
            continue;
        }
        if let Some((key, value)) = word.split_once('=') {
            if !key.is_empty() && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
                arguments.insert(key.to_string(), json_or_string(value));
                continue;
            }
        }
        positional.push(word.clone());
    }
    Ok((arguments, positional))
}

/// `true`, `42`, `[...]`, `{...}` and `"quoted"` are passed as JSON (a quoted
/// value lets a caller force a string such as `text="42"`); anything else
/// is the literal string.
fn json_or_string(value: &str) -> Value {
    serde_json::from_str::<Value>(value).unwrap_or_else(|_| Value::String(value.to_string()))
}

/// Run one tool call and print its text; exit 0 on success, 1 on the tool's
/// error text (printed to stderr, exactly as an MCP client would see it).
pub fn call(tool: &str, mut arguments: Map<String, Value>, action: Option<&str>) -> i32 {
    if let Some(action) = action {
        arguments.insert("action".into(), Value::String(action.to_string()));
    }
    match unpeel_core::mcp_host::call_tool(tool, &Value::Object(arguments)) {
        Ok(text) => {
            println!("{text}");
            0
        }
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}

/// `unpeel mcp …`
pub fn run(args: &[String]) -> i32 {
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-h" | "help"))
        && args.len() == 1
    {
        println!("{HELP}");
        return 0;
    }
    let (arguments, positional) = match parse_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    let words: Vec<&str> = positional.iter().map(String::as_str).collect();
    match words.as_slice() {
        [] => {
            for name in unpeel_core::mcp_host::tool_names() {
                println!("{name}");
            }
            0
        }
        [tool] => call(tool, arguments, Some("help")),
        [tool, action, rest @ ..] => {
            if !rest.is_empty() {
                eprintln!("unexpected words {rest:?}; pass arguments as key=value\n\n{HELP}");
                return 1;
            }
            call(tool, arguments, Some(action))
        }
    }
}

fn family(tool: &str, args: &[String], usage: &str) -> i32 {
    let (arguments, positional) = match parse_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    let words: Vec<&str> = positional.iter().map(String::as_str).collect();
    match words.as_slice() {
        [] | ["help"] | ["--help"] | ["-h"] => {
            println!("{usage}");
            call(tool, Map::new(), Some("help"))
        }
        [action] => call(tool, arguments, Some(action)),
        [_, rest @ ..] => {
            eprintln!("unexpected words {rest:?}; pass arguments as key=value\n\n{usage}");
            1
        }
    }
}

/// `unpeel browser …` (everything except `install`, which stays with the
/// engine verb).
pub fn browser(args: &[String]) -> i32 {
    let (mut arguments, positional) = match parse_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    let words: Vec<&str> = positional.iter().map(String::as_str).collect();
    let mut set = |key: &str, value: &str| {
        arguments.insert(key.to_string(), Value::String(value.to_string()));
    };
    let action = match words.as_slice() {
        [] | ["help"] => return call("browser", Map::new(), Some("help")),
        ["open", url] => {
            set("url", url);
            "open"
        }
        ["click", target] => {
            set("target", target);
            "click"
        }
        ["fill", target, text] => {
            set("target", target);
            set("text", text);
            "fill"
        }
        ["type", target, text] => {
            set("target", target);
            set("text", text);
            "type"
        }
        ["press", key] => {
            set("key", key);
            "press"
        }
        ["get", what] => {
            set("what", what);
            "get"
        }
        ["get", what, target] => {
            set("what", what);
            set("target", target);
            "get"
        }
        ["scroll", direction] => {
            set("direction", direction);
            "scroll"
        }
        [action] => action,
        [action, rest @ ..] => {
            eprintln!("unexpected words {rest:?} after {action}; pass arguments as key=value");
            return 1;
        }
    };
    for flag in ["full", "annotate", "gallery", "interactive", "compact"] {
        if args.iter().any(|arg| arg == &format!("--{flag}")) {
            arguments.insert(flag.into(), Value::Bool(true));
        }
    }
    call("browser", arguments, Some(action))
}

/// `unpeel artifacts publish <path>`
pub fn artifacts(args: &[String]) -> i32 {
    let (mut arguments, positional) = match parse_args(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    match positional
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["publish", path] | ["add_to_gallery", path] => {
            arguments.insert("path".into(), Value::String(path.to_string()));
            call("artifacts", arguments, Some("add_to_gallery"))
        }
        [action] => call("artifacts", arguments, Some(action)),
        _ => call("artifacts", Map::new(), Some("help")),
    }
}

/// `unpeel current`
pub fn current(args: &[String]) -> i32 {
    let (arguments, _) = parse_args(args).unwrap_or_default();
    call("sessions", arguments, Some("current"))
}

const REPORT_USAGE: &str = "usage: unpeel report <summary> --to <id|super_agent> \
[--status update|progress|done|blocked] [--details TEXT]";

/// `unpeel report <summary> --to <id|super_agent> [--status S] [--details D] [--no-submit]`
pub fn report(args: &[String]) -> i32 {
    let Some(arguments) = report_arguments(args) else {
        eprintln!("{REPORT_USAGE}");
        return 1;
    };
    call("sessions", arguments, Some("report"))
}

/// The `report` arguments in `args`; `None` without a summary or a target.
fn report_arguments(args: &[String]) -> Option<Map<String, Value>> {
    let mut arguments = Map::new();
    let mut summary: Vec<String> = Vec::new();
    let mut iter = args.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            // Fork-only (#82): the target, `super_agent` included.
            "--to" => {
                let Some(value) = iter.next() else { break };
                arguments.insert("session_id".into(), Value::String(value.clone()));
            }
            "--status" => {
                let Some(value) = iter.next() else { break };
                arguments.insert("status".into(), Value::String(value.clone()));
            }
            "--details" => {
                let Some(value) = iter.next() else { break };
                arguments.insert("details".into(), Value::String(value.clone()));
            }
            "--no-submit" => {
                arguments.insert("submit".into(), Value::Bool(false));
            }
            "--json" => {
                let Some(raw) = iter.next() else { break };
                if let Ok(Value::Object(object)) = serde_json::from_str::<Value>(raw) {
                    arguments.extend(object);
                }
            }
            other => summary.push(other.to_string()),
        }
    }
    if summary.is_empty() && !arguments.contains_key("summary") {
        return None;
    }
    if !summary.is_empty() {
        arguments.insert("summary".into(), Value::String(summary.join(" ")));
    }
    arguments.contains_key("session_id").then_some(arguments)
}

/// `unpeel worktree create <name> [--branch B] [--base REF] [--project ID]`
pub fn worktree(args: &[String]) -> i32 {
    let mut arguments = Map::new();
    let mut positional = Vec::new();
    let mut iter = args.iter();
    while let Some(word) = iter.next() {
        let key = match word.as_str() {
            "--branch" => "branch",
            "--base" => "base_ref",
            "--project" => "project_id",
            _ => {
                positional.push(word.clone());
                continue;
            }
        };
        if let Some(value) = iter.next() {
            arguments.insert(key.into(), Value::String(value.clone()));
        }
    }
    match positional
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["create", name] => {
            arguments.insert("name".into(), Value::String(name.to_string()));
            call("workspace", arguments, Some("create_worktree"))
        }
        [action] => call("workspace", arguments, Some(action)),
        _ => {
            println!(
                "usage: unpeel worktree create <name> [--branch B] [--base REF] [--project ID]"
            );
            call("workspace", Map::new(), Some("help"))
        }
    }
}

pub fn agents(args: &[String]) -> i32 {
    family(
        "agents",
        args,
        "usage: unpeel agents <action> [key=value ...]",
    )
}

pub fn skills(args: &[String]) -> i32 {
    family(
        "skills",
        args,
        "usage: unpeel skills <action> [key=value ...]",
    )
}

/// `unpeel apps describe|search|context …` (list/install/update/link stay
/// with the installer verb).
pub fn apps(args: &[String]) -> i32 {
    family(
        "apps",
        args,
        "usage: unpeel apps describe|search|context [key=value ...]",
    )
}

/// Whether this process runs inside a hosted Unpeel session, in which case
/// writes to other sessions must go through the cooperative policy.
pub fn inside_session() -> bool {
    unpeel_core::mcp_host::self_session_id().is_some()
}

/// `unpeel send <id> <text…> [--enter]` from inside a session: the MCP
/// `send_text` action, with its approval prompt and remembered pairs.
pub fn send_text(session_id: &str, text: &str, submit: bool) -> i32 {
    let mut arguments = Map::new();
    arguments.insert("session_id".into(), Value::String(session_id.to_string()));
    arguments.insert("text".into(), Value::String(text.to_string()));
    arguments.insert("submit".into(), Value::Bool(submit));
    call("sessions", arguments, Some("send_text"))
}

/// `unpeel keys <id> <key…>` from inside a session: the MCP `send_keys`
/// action. Keys are names (`down`, `enter`, `ctrl+c`), one per word.
pub fn send_keys(session_id: &str, keys: &[String]) -> i32 {
    let mut arguments = Map::new();
    arguments.insert("session_id".into(), Value::String(session_id.to_string()));
    arguments.insert("keys".into(), json!(keys));
    call("sessions", arguments, Some("send_keys"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_values_become_json_and_positionals_stay_ordered() {
        let words = [
            "open",
            "url=https://example.test",
            "interactive=false",
            "rows=12",
            "keys=[\"down\",\"enter\"]",
            "--json",
            "{\"extra\":1}",
            "tail",
        ]
        .map(String::from);
        let (arguments, positional) = parse_args(&words).unwrap();
        assert_eq!(positional, ["open", "tail"]);
        assert_eq!(arguments["url"], "https://example.test");
        assert_eq!(arguments["interactive"], false);
        assert_eq!(arguments["rows"], 12);
        assert_eq!(arguments["keys"], json!(["down", "enter"]));
        assert_eq!(arguments["extra"], 1);
        // A quoted JSON string stays a string, and an `=` inside a value is
        // kept once the key is taken.
        let words = ["text=a=b", "note=\"quoted\""].map(String::from);
        let (arguments, _) = parse_args(&words).unwrap();
        assert_eq!(arguments["text"], "a=b");
        assert_eq!(arguments["note"], "quoted");
        assert!(parse_args(&["--json".to_string()]).is_err());
        assert!(parse_args(&["--json".to_string(), "[1]".to_string()]).is_err());
    }

    #[test]
    fn report_takes_its_target_with_to() {
        let words = [
            "No",
            "new",
            "commits",
            "--to",
            "super_agent",
            "--status",
            "done",
        ]
        .map(String::from);
        let arguments = report_arguments(&words).unwrap();
        assert_eq!(arguments["session_id"], "super_agent");
        assert_eq!(arguments["summary"], "No new commits");
        assert_eq!(arguments["status"], "done");
        // --json still names any argument, the target included.
        let words = ["hi", "--json", "{\"session_id\":\"abc\"}"].map(String::from);
        assert_eq!(report_arguments(&words).unwrap()["session_id"], "abc");
        // A summary and a target are both required.
        assert!(report_arguments(&["--to".to_string(), "abc".to_string()]).is_none());
        assert!(report_arguments(&["hi".to_string()]).is_none());
    }
}
