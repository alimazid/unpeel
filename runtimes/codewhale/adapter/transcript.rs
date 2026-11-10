use super::*;

pub(super) const ADAPTER: TranscriptAdapter = TranscriptAdapter {
    legacy_slug: "codewhale",
    file_backed: true,
    collect_document: Some(collect_document),
    collect_line,
    resume_id_from_command,
    trusted_roots,
    path_matches,
    find_by_id,
    find_best,
    title_candidate: None,
    model_from_value: None,
    context_usage: Some(context_usage),
};

/// Codewhale appends this block to every user message for the model; it is
/// not something the user typed.
const TURN_META_PREFIX: &str = "<turn_meta>";
/// Saved sessions are compact JSON with `metadata` first, so its
/// `workspace` sits well inside this prefix.
const SESSION_HEAD_BYTES: u64 = 16 * 1024;

fn resume_id_from_command(command: &str) -> Option<String> {
    let words = shell_words(command);
    if words.get(1).is_some_and(|word| word == "resume") {
        return words.get(2).filter(|id| !id.starts_with('-')).cloned();
    }
    flag_value(&words, &["--resume", "-r", "--session-id"])
}

/// `$CODEWHALE_HOME/sessions`, else `~/.codewhale/sessions` — where every
/// Codewhale build since the rename writes new sessions.
fn codewhale_sessions_root() -> Option<PathBuf> {
    let home = std::env::var_os("CODEWHALE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| Some(user_home_dir()?.join(".codewhale")))?;
    Some(home.join("sessions"))
}

fn trusted_roots() -> Vec<PathBuf> {
    codewhale_sessions_root().into_iter().collect()
}

fn path_matches(path: &Path) -> bool {
    has_extension(path, &["json"])
}

fn find_by_id(_cwd: &str, provider_id: &str) -> Option<PathBuf> {
    if provider_id.is_empty()
        || !provider_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return None;
    }
    let direct = codewhale_sessions_root()?.join(format!("{provider_id}.json"));
    direct.is_file().then_some(direct)
}

/// `metadata.workspace` from the head of a saved session, without parsing a
/// conversation that may be megabytes long.
fn session_workspace(path: &Path) -> Option<String> {
    let head = read_head_utf8(path, SESSION_HEAD_BYTES).ok()?;
    let key = head.find("\"workspace\"")?;
    let rest = head[key + "\"workspace\"".len()..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let mut deserializer = serde_json::Deserializer::from_str(rest);
    serde::Deserialize::deserialize(&mut deserializer).ok()
}

/// Codewhale may record the workspace through a different spelling of the
/// same directory (macOS `/tmp` is `/private/tmp`), so compare real paths.
fn same_directory(left: &str, right: &str) -> bool {
    let real = |path: &str| fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    left == right || real(left) == real(right)
}

fn find_best(manifest: &HostedSessionManifest) -> Option<PathBuf> {
    best_file_for_session(
        list_files_with_extensions(&codewhale_sessions_root()?, &["json"])
            .into_iter()
            .filter(|path| {
                session_workspace(path)
                    .is_some_and(|workspace| same_directory(&workspace, &manifest.cwd))
            })
            .collect(),
        manifest.session.created_at,
    )
}

fn typed_text(block: &Value) -> Option<&str> {
    block.get("text").and_then(Value::as_str)
}

fn user_text(content: &[Value]) -> Option<String> {
    let text = content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(typed_text)
        .filter(|text| !text.trim_start().starts_with(TURN_META_PREFIX))
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then_some(text)
}

fn tool_result_text(block: &Value) -> Option<String> {
    match block.get("content") {
        Some(Value::String(text)) => Some(text.clone()),
        Some(content @ Value::Array(_)) => text_from_content(Some(content)),
        _ => None,
    }
}

fn collect_document(value: &Value, include_tools: bool) -> Vec<TranscriptEntry> {
    let mut entries = Vec::new();
    let mut tool_names: HashMap<String, String> = HashMap::new();
    let Some(messages) = value.get("messages").and_then(Value::as_array) else {
        return entries;
    };
    for message in messages {
        let Some(content) = message.get("content").and_then(Value::as_array) else {
            continue;
        };
        match message.get("role").and_then(Value::as_str) {
            Some("user") => {
                if let Some(text) = user_text(content) {
                    push_user_transcript_entry(&mut entries, &text);
                }
                if include_tools {
                    for block in content {
                        if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                            continue;
                        }
                        let call_id = block.get("tool_use_id").and_then(Value::as_str);
                        let name = call_id
                            .and_then(|id| tool_names.get(id))
                            .map(String::as_str)
                            .unwrap_or("tool");
                        let failed = block.get("is_error").and_then(Value::as_bool) == Some(true);
                        if let Some(output) = tool_result_text(block) {
                            push_tool_result_entry(
                                &mut entries,
                                call_id,
                                name,
                                &output,
                                failed.then(|| "error".to_string()),
                                HashMap::new(),
                            );
                        }
                    }
                }
            }
            Some("assistant") => {
                for block in content {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(text) = typed_text(block) {
                                push_transcript_entry(&mut entries, "Assistant", text.to_string());
                            }
                        }
                        Some("thinking") if include_tools => {
                            if let Some(text) = block.get("thinking").and_then(Value::as_str) {
                                push_transcript_entry(&mut entries, "Reasoning", text.to_string());
                            }
                        }
                        Some("tool_use") => {
                            let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
                            let call_id = block.get("id").and_then(Value::as_str);
                            if let Some(id) = call_id {
                                tool_names.insert(id.to_string(), name.to_string());
                            }
                            if include_tools {
                                let input = block.get("input").cloned().unwrap_or(Value::Null);
                                push_tool_call_entry(
                                    &mut entries,
                                    call_id,
                                    name,
                                    summarize_tool_input(name, &input),
                                    metadata_from_tool_input(&input, &["command", "path"]),
                                );
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    entries
}

/// Saved sessions are single JSON documents; a line never holds a message.
fn collect_line(_value: &Value, _include_tools: bool, _state: &mut TranscriptParseState) {}

/// Fork-only (#68): Codewhale's own local estimate of its context, from the
/// saved session (handed over whole, as the one line). Its footer shows
/// `max(estimate, last billed prompt)`, but the billed half lives only in
/// memory and the saved session keeps no per-request usage, so this reads at
/// or under the footer, and equals it right after a compaction. The rules
/// are v0.10.2's (`estimated_context_tokens`, `crates/tui/src/tui/ui/frame.rs`,
/// and `estimate_tokens_for_message`, `crates/tui/src/compaction.rs`, at
/// ff466b2): every block's estimate, the system prompt's conservative one,
/// and 12 tokens per message plus 48 of framing. The model is `metadata.model`,
/// or the auto router's last pick.
fn context_usage(lines: &[&str]) -> Option<ContextUsage> {
    let document = serde_json::from_str::<Value>(lines.last()?).ok()?;
    let messages = document
        .get("messages")
        .and_then(Value::as_array)
        .filter(|messages| !messages.is_empty())?;
    let message_tokens: u64 = messages
        .iter()
        .filter_map(|message| message.get("content").and_then(Value::as_array))
        .flatten()
        .map(block_tokens)
        .sum();
    let framing = MESSAGE_FRAMING_TOKENS * messages.len() as u64 + REQUEST_FRAMING_TOKENS;
    let model = document
        .pointer("/metadata/model")
        .and_then(Value::as_str)
        .filter(|model| *model != "auto")
        .or_else(|| {
            document
                .pointer("/last_auto_route/model")
                .and_then(Value::as_str)
        })
        .filter(|model| !model.is_empty())
        .map(str::to_owned);
    Some(ContextUsage {
        tokens: message_tokens + system_prompt_tokens(document.get("system_prompt")) + framing,
        model,
    })
}

/// Codewhale's rough rule: a token per 4 bytes of text or JSON.
const BYTES_PER_TOKEN: u64 = 4;
/// The system prompt's conservative rule also counts a token per 3 chars.
const CHARS_PER_TOKEN_CONSERVATIVE: usize = 3;
/// Framing Codewhale adds per message and once per request.
const MESSAGE_FRAMING_TOKENS: u64 = 12;
const REQUEST_FRAMING_TOKENS: u64 = 48;
/// Images Codewhale counts at a flat 1,000 tokens each.
const IMAGE_TOKENS: u64 = 1_000;
/// How a saved session joins a block-structured system prompt.
const SYSTEM_BLOCK_SEPARATOR: &str = "\n\n---\n\n";

fn block_tokens(block: &Value) -> u64 {
    let quarter_bytes = |text: Option<&str>| text.map_or(0, str::len) as u64 / BYTES_PER_TOKEN;
    let quarter_json = |value: Option<&Value>| {
        serde_json::to_string(value.unwrap_or(&Value::Null)).map_or(0, |json| json.len()) as u64
            / BYTES_PER_TOKEN
    };
    match block.get("type").and_then(Value::as_str) {
        Some("text") => quarter_bytes(typed_text(block)),
        Some("thinking") => quarter_bytes(block.get("thinking").and_then(Value::as_str)),
        Some("tool_use" | "server_tool_use") => quarter_json(block.get("input")),
        Some("tool_result") => {
            let images = block
                .get("content_blocks")
                .and_then(Value::as_array)
                .map_or(0, |blocks| {
                    blocks
                        .iter()
                        .filter(|inner| inner.get("type").and_then(Value::as_str) == Some("image"))
                        .count()
                });
            quarter_bytes(block.get("content").and_then(Value::as_str))
                + images as u64 * IMAGE_TOKENS
        }
        Some("image_url") => IMAGE_TOKENS,
        Some("tool_search_tool_result" | "code_execution_tool_result") => {
            quarter_json(block.get("content"))
        }
        _ => 0,
    }
}

/// The conservative estimate of each system prompt block: a third of its
/// characters, never under a quarter of its bytes. A saved session joins
/// the blocks into one string, so it is split again.
fn system_prompt_tokens(prompt: Option<&Value>) -> u64 {
    let conservative = |text: &str| {
        let bytes = text.len().div_ceil(BYTES_PER_TOKEN as usize);
        text.chars().count().div_ceil(CHARS_PER_TOKEN_CONSERVATIVE).max(bytes) as u64
    };
    match prompt {
        Some(Value::String(text)) => text.split(SYSTEM_BLOCK_SEPARATOR).map(conservative).sum(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(typed_text)
            .map(conservative)
            .sum(),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_comes_from_the_session_head() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("528c609b-4571-4550-9deb-454c46fa9871.json");
        fs::write(
            &path,
            r#"{"schema_version":1,"metadata":{"id":"528c609b","runtime_store":{"data_dir":"/x"},"workspace":"/tmp/my \"repo\""},"messages":[]}"#,
        )
        .unwrap();
        assert_eq!(
            session_workspace(&path).as_deref(),
            Some("/tmp/my \"repo\"")
        );
        let owners = dir.path().join("session_boot_owners.json");
        fs::write(&owners, r#"{"528c609b":"boot_8c634426"}"#).unwrap();
        assert_eq!(session_workspace(&owners), None);
    }

    #[test]
    fn ids_and_commands_resolve_only_saved_session_names() {
        assert_eq!(find_by_id("/tmp", "../escape"), None);
        assert_eq!(find_by_id("/tmp", ""), None);
        assert_eq!(
            resume_id_from_command("codewhale resume 528c609b").as_deref(),
            Some("528c609b")
        );
        assert_eq!(
            resume_id_from_command("codew --resume abc --model flash").as_deref(),
            Some("abc")
        );
        assert_eq!(resume_id_from_command("codewhale --continue"), None);
    }
}
