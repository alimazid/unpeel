//! Tests for the shared provider transcript API. Extracted from
//! transcripts.rs — a submodule of `transcripts`, so `super::*` still
//! reaches every private item under test.

use super::*;
use crate::session_host::HostedSessionState;
use crate::state::{SessionInfo, TranscriptSettings};
use std::fs;

fn provider(slug: &str) -> TranscriptProvider {
    TranscriptProvider::for_legacy_slug(slug).expect("test provider is registered")
}

#[test]
fn generated_adapter_registry_matches_runtime_catalog() {
    let catalog = crate::runtime_catalog::builtin_runtime_catalog();
    let mut expected = catalog
        .current_platform_descriptors()
        .filter(|runtime| {
            runtime
                .capabilities
                .contains(&crate::runtime_catalog::RuntimeCapability::Transcript)
        })
        .map(|runtime| runtime.legacy_slug.as_str())
        .collect::<Vec<_>>();
    expected.sort_unstable();
    let mut actual = TRANSCRIPT_ADAPTERS
        .iter()
        .map(|adapter| adapter.legacy_slug)
        .collect::<Vec<_>>();
    actual.sort_unstable();
    let registered_count = actual.len();
    actual.dedup();
    assert_eq!(
        actual.len(),
        registered_count,
        "duplicate transcript adapter"
    );
    assert_eq!(actual, expected);
    assert_eq!(
        serde_json::to_value(provider("cursor-agent")).unwrap(),
        Value::String("cursor-agent".to_string()),
        "legacy provider wire identity must not change"
    );
    assert_eq!(
        transcript_status_hint(&test_manifest("opencode")),
        "planned",
        "the non-file-backed compatibility adapter preserves the shipped hint"
    );
}

fn test_manifest(command: &str) -> HostedSessionManifest {
    HostedSessionManifest {
        session: SessionInfo {
            id: "session-1".to_string(),
            project_id: "project-1".to_string(),
            label: "Test".to_string(),
            custom_title: false,
            command: command.to_string(),
            created_at: 1,
            owner_principal_id: None,
            created_by_device_id: None,
            source_preset_id: None,
            tag_id: None,
            worktree_path: None,
            worktree_branch: None,
            parent_session_id: None,
            spawned_by: None,
            role: None,
            task: None,
        },
        cwd: "/tmp/repo".to_string(),
        state: HostedSessionState::Running,
        pid: None,
        pid_started_at: None,
        host_pid: None,
        host_pid_started_at: None,
        exit_code: None,
        host_build_id: None,
        host_protocol_version: None,
        has_been_written_to: true,
        provider_session_id: None,
        provider_transcript_path: None,
        managed_storage_path: None,
        resume_failure_markers: Vec::new(),
        runtime: None,
        active_app: None,
        runtime_launch_generation: u64::from(!command.trim().is_empty()),
        runtime_launch_pending: false,
        runtime_launched_at: (!command.trim().is_empty()).then_some(1),
        runtime_launch_output_offset: 0,
        mcp_enabled: None,
        browser_mcp_enabled: None,
        computer_mcp_enabled: None,
        mcp_client_registered: false,
        browser_client_registered: false,
        computer_client_registered: false,
        menu_prompt_active: false,
        screen_activity: None,
        program_status: None,
        terminal_modes: None,
        screen_changed_at: None,
        last_input_at: None,
        draft_guard: false,
        detected_local_urls: Vec::new(),
        heartbeat_at: 0,
        updated_at: 0,
    }
}

/// A hand-typed agent in a blank terminal has no launch command naming its
/// provider; the runtime recorded at hook capture (or the live foreground
/// observation) resolves it, while a non-agent command never defers.
#[test]
fn blank_launch_resolves_provider_from_captured_or_observed_runtime() {
    let mut manifest = test_manifest("");
    manifest.session.id = "blank-1".to_string();
    assert!(transcript_provider_for_manifest(&manifest).is_none());
    assert_eq!(transcript_status_hint(&manifest), "none");

    // Live observation, nothing captured yet.
    manifest.runtime = Some(crate::session_host::HostedSessionRuntime {
        current_observation: Some(crate::runtime_observer::ActiveRuntimeObservation {
            runtime_id: "claude".into(),
            pid: 1,
            pid_started_at: None,
            process_group_id: 1,
            process_name: "claude".into(),
            argv: None,
        }),
    });
    assert_eq!(
        serde_json::to_value(transcript_provider_for_manifest(&manifest).unwrap()).unwrap(),
        Value::String("claude".into())
    );

    // The marker records the runtime that captured the conversation, merges
    // with what is already there, and is quiet when nothing changes.
    let dir = std::env::temp_dir().join(format!("unpeel-blank-provider-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    assert!(crate::session_ops::set_provider_session_at(&dir, Some("conv-1"), None, None).unwrap());
    assert_eq!(crate::session_ops::provider_session_runtime_at(&dir), None);
    assert!(
        crate::session_ops::set_provider_session_at(&dir, Some("conv-1"), None, Some("codex"))
            .unwrap()
    );
    assert_eq!(
        crate::session_ops::provider_session_runtime_at(&dir).as_deref(),
        Some("codex")
    );
    assert_eq!(
        crate::session_ops::provider_session_marker_at(&dir)
            .0
            .as_deref(),
        Some("conv-1")
    );
    assert!(!crate::session_ops::set_provider_session_at(
        &dir,
        Some("conv-1"),
        None,
        Some("codex")
    )
    .unwrap());
    assert!(
        crate::session_ops::set_provider_session_at(&dir, None, Some("/tmp/t.jsonl"), None)
            .unwrap()
    );
    assert_eq!(
        crate::session_ops::provider_session_runtime_at(&dir).as_deref(),
        Some("codex")
    );
    let _ = std::fs::remove_dir_all(&dir);

    // A non-agent launch never defers to the occupant.
    let mut script = test_manifest("./run-things.sh");
    script.session.id = "blank-1".to_string();
    assert!(transcript_provider_for_manifest(&script).is_none());
}

#[test]
fn command_parsing_detects_provider_and_resume_ids() {
    assert_eq!(
        transcript_provider_for_command("claude --dangerously-skip-permissions"),
        Some(provider("claude"))
    );
    assert_eq!(
        transcript_provider_for_command("cline"),
        Some(provider("cline"))
    );
    assert_eq!(
        transcript_provider_for_command("CLINE_SESSION_BACKEND_MODE=local cline"),
        Some(provider("cline"))
    );
    assert_eq!(
        transcript_provider_for_command("A='x y' /tmp/bin/cline --plan"),
        Some(provider("cline"))
    );
    assert_eq!(
        provider_label_for_command("DEBUG=1 ./run-things.sh"),
        "run-things.sh"
    );
    assert_eq!(
        transcript_provider_for_command("/tmp/bin/codex resume 019abc"),
        Some(provider("codex"))
    );
    assert_eq!(
        transcript_provider_for_command("cursor-agent --continue"),
        Some(provider("cursor-agent"))
    );
    assert_eq!(
        transcript_provider_for_command("gemini --resume latest"),
        Some(provider("gemini"))
    );
    assert_eq!(
        transcript_provider_for_command("grok --always-approve"),
        Some(provider("grok"))
    );
    assert_eq!(
        transcript_provider_for_command("kimi --yolo"),
        Some(provider("kimi"))
    );
    assert_eq!(
        transcript_provider_for_command("kiro-cli --v3"),
        Some(provider("kiro-cli"))
    );
    assert_eq!(
        resume_id_from_command(provider("cursor-agent"), "cursor-agent --continue"),
        None
    );
    assert_eq!(
        resume_id_from_command(provider("claude"), "claude --resume abc-123"),
        Some("abc-123".to_string())
    );
    assert_eq!(
        resume_id_from_command(provider("claude"), "claude --resume=abc-456"),
        Some("abc-456".to_string())
    );
    assert_eq!(
        resume_id_from_command(
            provider("codex"),
            "codex --dangerously-bypass-approvals-and-sandbox resume 019abc"
        ),
        Some("019abc".to_string())
    );
    assert_eq!(
        resume_id_from_command(provider("codex"), "codex resume --last"),
        None
    );
    assert_eq!(
        resume_id_from_command(provider("kimi"), "kimi --yolo --session kimi-123"),
        Some("kimi-123".to_string())
    );
    assert_eq!(
        resume_id_from_command(provider("kiro-cli"), "kiro-cli --v3 --resume-id sess_123"),
        Some("sess_123".to_string())
    );
    assert_eq!(
        resume_id_from_command(provider("cline"), "cline --id sess_cline"),
        Some("sess_cline".to_string())
    );
}

#[test]
fn cline_document_transcript_parses_messages_reasoning_tools_and_usage() {
    let raw = r#"{
  "version": 1,
  "sessionId": "sess_cline",
  "messages": [
{"id":"u1","role":"user","ts":100,"content":[{"type":"text","text":"<user_input mode=\"act\">Compare the proposals.</user_input>"}]},
{"id":"a1","role":"assistant","ts":101,"modelInfo":{"id":"claude-sonnet-4-5","provider":"anthropic"},"metrics":{"inputTokens":120,"outputTokens":32,"cost":0.002},"content":[
  {"type":"thinking","thinking":"I should read each proposal."},
  {"type":"text","text":"I’ll compare scope and risk."},
  {"type":"tool_use","id":"call-1","name":"read_files","input":{"path":"proposals/"}}]},
{"id":"u2","role":"user","ts":102,"content":[
  {"type":"tool_result","tool_use_id":"call-1","name":"read_files","content":"Three proposal files."}]}
  ]
}"#;
    let entries = collect_transcript_entries(provider("cline"), raw, true);
    assert_eq!(
        entries.first().map(|entry| entry.text.as_str()),
        Some("Compare the proposals.")
    );
    assert!(entries.iter().any(|entry| {
        entry.role == "Reasoning" && entry.text == "I should read each proposal."
    }));
    assert!(entries.iter().any(|entry| {
        entry.blocks.first().is_some_and(|block| {
            block.kind == TranscriptBlockKind::ToolCall
                && block.tool_name.as_deref() == Some("read_files")
        })
    }));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("Three proposal files.")));
    assert!(entries.iter().any(|entry| {
        entry
            .blocks
            .first()
            .is_some_and(|block| block.kind == TranscriptBlockKind::Usage)
    }));
    let value: Value = serde_json::from_str(raw).unwrap();
    assert_eq!(
        find_model_string(provider("cline"), &value),
        Some("claude-sonnet-4-5".to_string())
    );
}

#[test]
fn codex_transcript_entries_are_compact_and_deduped() {
    let raw = r#"
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix it"}]}}
{"type":"event_msg","payload":{"type":"user_message","message":"fix it"}}
{"type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"exec_command","arguments":"{\"cmd\":\"cargo test\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Process exited with code 0\nall good"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}
"#;
    let entries = collect_transcript_entries(provider("codex"), raw, true);
    assert_eq!(entries[0].role, "User");
    assert_eq!(entries[0].text, "fix it");
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("cargo test")));
    let tool_call = entries
        .iter()
        .find(|entry| entry.text.contains("cargo test"))
        .expect("tool call entry");
    assert_eq!(tool_call.blocks[0].kind, TranscriptBlockKind::ToolCall);
    assert_eq!(
        tool_call.blocks[0].tool_name.as_deref(),
        Some("exec_command")
    );
    assert_eq!(entries.last().unwrap().text, "Done.");
    assert_eq!(
        entries
            .iter()
            .filter(|entry| entry.role == "User" && entry.text == "fix it")
            .count(),
        1
    );
}

#[test]
fn codex_transcript_entries_drop_bootstrap_noise_and_hide_tools_by_default() {
    let raw = r##"
{"type":"event_msg","payload":{"type":"user_message","message":"# AGENTS.md instructions for /tmp/repo\nFollow these rules."}}
{"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>\n  <cwd>/tmp/repo</cwd>\n</environment_context>"}}
{"type":"event_msg","payload":{"type":"user_message","message":"fix the broken prompt\n\n[sent from Unpeel session_id=\"caller-1\"]"}}
{"type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"exec_command","arguments":"{\"cmd\":\"cargo test\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"test output"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"Patched."}}
"##;

    let entries = collect_transcript_entries(provider("codex"), raw, false);
    assert_eq!(entries.len(), 2);
    assert_eq!(
        (entries[0].role, entries[0].text.as_str()),
        ("User", "fix the broken prompt")
    );
    assert_eq!(
        (entries[1].role, entries[1].text.as_str()),
        ("Assistant", "Patched.")
    );

    let entries_with_tools = collect_transcript_entries(provider("codex"), raw, true);
    assert!(entries_with_tools
        .iter()
        .any(|entry| entry.role == "Tool" && entry.text.contains("cargo test")));
    assert!(!entries_with_tools
        .iter()
        .any(|entry| entry.text.contains("AGENTS.md")));
}

#[test]
fn codex_patch_apply_end_exposes_diff_blocks() {
    let raw = r#"
{"type":"response_item","payload":{"type":"patch_apply_end","call_id":"call-1","status":"success","success":true,"changes":{"src/App.swift":{"type":"modify","unified_diff":"--- a/src/App.swift\n+++ b/src/App.swift\n@@\n-old\n+new\n"}}}}
"#;
    let entries = collect_transcript_entries(provider("codex"), raw, true);
    let entry = entries
        .iter()
        .find(|entry| {
            entry
                .blocks
                .iter()
                .any(|block| block.kind == TranscriptBlockKind::Diff)
        })
        .expect("diff entry");
    let block = &entry.blocks[0];
    assert_eq!(block.kind, TranscriptBlockKind::Diff);
    assert_eq!(block.tool_name.as_deref(), Some("apply_patch"));
    assert_eq!(block.status.as_deref(), Some("success"));
    assert_eq!(
        block.metadata.get("path").map(String::as_str),
        Some("src/App.swift")
    );
    assert_eq!(
        block.metadata.get("additions").map(String::as_str),
        Some("1")
    );
    assert_eq!(
        block.metadata.get("deletions").map(String::as_str),
        Some("1")
    );
    assert!(block.text.as_deref().unwrap_or_default().contains("+new"));
}

#[test]
fn codex_update_plan_exposes_plan_update_block() {
    let raw = r#"
{"type":"response_item","payload":{"type":"function_call","call_id":"plan-1","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Inspect files\",\"status\":\"completed\"},{\"step\":\"Patch parser\",\"status\":\"in_progress\"}]}"}}
"#;
    let entries = collect_transcript_entries(provider("codex"), raw, true);
    let block = &entries[0].blocks[0];
    assert_eq!(block.kind, TranscriptBlockKind::PlanUpdate);
    assert_eq!(block.tool_name.as_deref(), Some("update_plan"));
    assert_eq!(block.metadata.get("items").map(String::as_str), Some("2"));
    assert!(block
        .text
        .as_deref()
        .unwrap_or_default()
        .contains("in_progress: Patch parser"));
}

#[test]
fn claude_transcript_entries_skip_internal_user_wrappers() {
    let raw = r#"
{"type":"user","userType":"external","message":{"role":"user","content":[{"type":"text","text":"hello claude"}]}}
{"type":"user","message":{"role":"user","content":"<local-command-stdout>noise</local-command-stdout>"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello back"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/main.rs"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file contents"}]}}
"#;
    let entries = collect_transcript_entries(provider("claude"), raw, true);
    assert!(entries.iter().any(|entry| entry.text == "hello claude"));
    assert!(!entries
        .iter()
        .any(|entry| entry.text.contains("local-command")));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("src/main.rs")));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("hello back")));
}

#[test]
fn claude_and_cursor_edit_tools_expose_diff_blocks() {
    let claude_raw = r#"
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"src/main.rs","old_string":"old","new_string":"new"}}]}}
"#;
    let claude_entries = collect_transcript_entries(provider("claude"), claude_raw, true);
    let claude_block = &claude_entries[0].blocks[0];
    assert_eq!(claude_block.kind, TranscriptBlockKind::Diff);
    assert_eq!(
        claude_block.metadata.get("path").map(String::as_str),
        Some("src/main.rs")
    );
    assert!(claude_block
        .text
        .as_deref()
        .unwrap_or_default()
        .contains("-old"));

    let cursor_raw = r#"
{"role":"assistant","message":{"content":[{"type":"tool_use","id":"replace-1","name":"StrReplace","input":{"path":"Package.swift","old_string":"old","new_string":"new"}}]}}
"#;
    let cursor_entries = collect_transcript_entries(provider("cursor-agent"), cursor_raw, true);
    let cursor_block = &cursor_entries[0].blocks[0];
    assert_eq!(cursor_block.kind, TranscriptBlockKind::Diff);
    assert_eq!(cursor_block.tool_name.as_deref(), Some("StrReplace"));
    assert_eq!(
        cursor_block.metadata.get("path").map(String::as_str),
        Some("Package.swift")
    );
}

#[test]
fn cursor_transcript_entries_parse_chat_and_tools() {
    let raw = r#"
{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nhi\n</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Hello."},{"type":"tool_use","name":"Read","input":{"path":"Package.swift"}}]}}
"#;
    let entries = collect_transcript_entries(provider("cursor-agent"), raw, true);
    assert!(entries.iter().any(|entry| entry.role == "User"));
    assert!(entries.iter().any(|entry| entry.text == "Hello."));
    assert!(entries
        .iter()
        .any(|entry| entry.role == "Tool" && entry.text.contains("Package.swift")));
}

#[test]
fn gemini_json_document_entries_parse_messages() {
    let raw = r#"
{"sessionId":"abc","messages":[{"type":"user","content":[{"text":"hello"}]},{"type":"gemini","content":"hi back"}]}
"#;
    let entries = collect_transcript_entries(provider("gemini"), raw, false);
    assert_eq!(entries[0].role, "User");
    assert_eq!(entries[0].text, "hello");
    assert_eq!(entries[1].role, "Assistant");
    assert_eq!(entries[1].text, "hi back");
}

#[test]
fn grok_transcript_entries_parse_chat_history() {
    let raw = r#"
{"type":"system","content":"noise"}
{"type":"user","content":[{"type":"text","text":"hello"}]}
{"type":"assistant","content":"hi back"}
"#;
    let entries = collect_transcript_entries(provider("grok"), raw, false);
    assert_eq!(entries[0].role, "User");
    assert_eq!(entries[0].text, "hello");
    assert_eq!(entries[1].role, "Assistant");
    assert_eq!(entries[1].text, "hi back");
}

#[test]
fn grok_transcript_entries_skip_injections_and_unwrap_user_query() {
    let raw = concat!(
        r#"{"type":"system","content":"you are grok"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<user_info>\nOS Version: macos\n</user_info>"}]}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<system-reminder>\nThe following skills are available\n</system-reminder>"}],"synthetic_reason":"system_reminder"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<user_query>\nleft align the panel titles\n</user_query>"}],"prompt_index":0}"#,
        "\n",
        r#"{"type":"assistant","content":"ok"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"This session is being continued from a previous conversation that ran out of context."}],"synthetic_reason":"compaction_meta"}"#,
        "\n",
    );
    let entries = collect_transcript_entries(provider("grok"), raw, false);
    let users: Vec<&str> = entries
        .iter()
        .filter(|entry| entry.role == "User")
        .map(|entry| entry.text.as_str())
        .collect();
    assert_eq!(users, vec!["left align the panel titles"]);
    assert!(!entries
        .iter()
        .any(|entry| entry.text.contains("system-reminder")
            || entry.text.contains("user_info")
            || entry.text.contains("skills are available")));
}

#[test]
fn kimi_transcript_entries_parse_reasoning_and_tools() {
    let raw = r#"
{"role":"_system_prompt","content":"internal"}
{"role":"user","content":[{"type":"text","text":"Run the checks"}]}
{"role":"user","content":[{"type":"text","text":"<system>CHECKPOINT 0</system>"}]}
{"role":"assistant","content":[{"type":"think","think":"I should run tests"},{"type":"text","text":"Running them now."}],"tool_calls":[{"id":"call-1","function":{"name":"Shell","arguments":"{\"command\":\"cargo test\"}"}}]}
{"role":"tool","content":[{"type":"text","text":"all tests passed"}],"tool_call_id":"call-1"}
{"role":"assistant","content":[{"type":"text","text":"Everything passes."}]}
"#;
    let entries = collect_transcript_entries(provider("kimi"), raw, true);
    assert!(entries
        .iter()
        .any(|entry| entry.role == "User" && entry.text == "Run the checks"));
    assert!(!entries
        .iter()
        .any(|entry| entry.text.contains("CHECKPOINT")));
    assert!(entries
        .iter()
        .any(|entry| entry.role == "Reasoning" && entry.text == "I should run tests"));
    let tool_call = entries
        .iter()
        .find(|entry| entry.text.contains("cargo test"))
        .expect("Kimi tool call");
    assert_eq!(tool_call.blocks[0].tool_name.as_deref(), Some("Shell"));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("all tests passed")));
    assert_eq!(entries.last().unwrap().text, "Everything passes.");
}

#[test]
fn kimi_code_wire_entries_parse_messages_loop_events_and_tools() {
    let raw = r#"
{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Inspect the project"}],"origin":{"kind":"user"}}}
{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"internal reminder"}],"origin":{"kind":"injection","variant":"system_reminder"}}}
{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"I should list files"}}}
{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"I’ll inspect it."}}}
{"type":"context.append_loop_event","event":{"type":"tool.call","toolCallId":"call-2","name":"Shell","args":{"command":"find . -maxdepth 1"}}}
{"type":"context.append_loop_event","event":{"type":"tool.result","toolCallId":"call-2","result":{"output":"./Cargo.toml","isError":false}}}
{"type":"usage.record","model":"kimi-code/k2.5","usage":{"inputOther":10,"output":5}}
"#;
    let entries = collect_transcript_entries(provider("kimi"), raw, true);
    assert!(entries
        .iter()
        .any(|entry| entry.role == "User" && entry.text == "Inspect the project"));
    assert!(!entries
        .iter()
        .any(|entry| entry.text.contains("internal reminder")));
    assert!(entries
        .iter()
        .any(|entry| entry.role == "Reasoning" && entry.text == "I should list files"));
    assert!(entries
        .iter()
        .any(|entry| entry.role == "Assistant" && entry.text == "I’ll inspect it."));
    let tool_call = entries
        .iter()
        .find(|entry| entry.text.contains("find . -maxdepth 1"))
        .expect("Kimi Code tool call");
    assert_eq!(tool_call.blocks[0].tool_name.as_deref(), Some("Shell"));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("./Cargo.toml")));
}

#[test]
fn omp_transcript_entries_parse_messages_reasoning_and_tools() {
    let raw = r#"
{"type":"session","id":"01a0b32e","timestamp":"2026-09-18T06:23:12.771Z","cwd":"/private/tmp","version":"18.2.3"}
{"type":"title","title":"Summarize the grading notes","updatedAt":"2026-09-18T06:24:02.309Z","v":1}
{"type":"model_change","id":"m1","model":"openrouter/deepseek/deepseek-v4.1-flash","timestamp":"2026-09-18T06:23:13.000Z"}
{"type":"message","id":"u1","parentId":"m1","message":{"role":"user","content":[{"type":"text","text":"Read /tmp/notes.md"}],"attribution":"user"}}
{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Read the file first."},{"type":"text","text":"Reading it now."},{"type":"toolCall","id":"tool_ABC","name":"read","arguments":{"path":"/tmp/notes.md"}}]}}
{"type":"message","id":"t1","parentId":"a1","message":{"role":"toolResult","toolCallId":"tool_ABC","toolName":"read","content":[{"type":"text","text":"1:pipeline capture notes"}]}}
{"type":"message","id":"a2","parentId":"t1","message":{"role":"assistant","content":[{"type":"text","text":"It lists pipeline capture notes."}]}}
{"type":"custom","id":"c1","customType":"unpeel.test","data":{}}
"#;
    let entries = collect_transcript_entries(provider("omp"), raw, true);
    assert!(entries
        .iter()
        .any(|entry| entry.role == "User" && entry.text == "Read /tmp/notes.md"));
    assert!(entries
        .iter()
        .any(|entry| entry.role == "Reasoning" && entry.text == "Read the file first."));
    let tool_call = entries
        .iter()
        .find(|entry| entry.text.contains("/tmp/notes.md") && entry.role == "Tool")
        .expect("OMP tool call");
    assert_eq!(tool_call.blocks[0].tool_name.as_deref(), Some("read"));
    assert!(entries
        .iter()
        .any(|entry| entry.text.contains("1:pipeline capture notes")));
    assert_eq!(
        entries.last().unwrap().text,
        "It lists pipeline capture notes."
    );

    // Tool traffic is hidden unless the caller asks for it, and OMP's own
    // bookkeeping entries (title, model_change, custom) stay out of the
    // conversation either way.
    let hidden = collect_transcript_entries(provider("omp"), raw, false);
    assert!(!hidden.iter().any(|entry| entry.role == "Tool"));
    assert!(!hidden
        .iter()
        .any(|entry| entry.text.contains("Read the file first.")));
    assert!(hidden
        .iter()
        .any(|entry| entry.text == "It lists pipeline capture notes."));
}

#[test]
fn omp_transcript_titles_come_from_the_title_entry() {
    let raw = r#"
{"type":"session","id":"01a0b32e","cwd":"/private/tmp","version":"18.2.3"}
{"type":"title","title":"Summarize the grading notes","updatedAt":"2026-09-18T06:24:02.309Z","v":1}
"#;
    assert_eq!(
        transcript_title_candidate(provider("omp"), raw).as_deref(),
        Some("Summarize the grading notes")
    );
}

#[test]
fn codewhale_saved_session_parses_messages_and_tools() {
    let raw = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../runtimes/codewhale/fixtures/session.json"
    ));
    let entries = collect_transcript_entries(provider("codewhale"), raw, true);
    let users: Vec<&str> = entries
        .iter()
        .filter(|entry| entry.role == "User")
        .map(|entry| entry.text.as_str())
        .collect();
    // The `<turn_meta>` block Codewhale appends for the model is not user text.
    assert_eq!(users, ["say hello", "make a file again"]);
    let tool_call = entries
        .iter()
        .find(|entry| entry.role == "Tool" && entry.text.contains("touch made-by-fake"))
        .expect("Codewhale tool call");
    assert_eq!(tool_call.blocks[0].tool_name.as_deref(), Some("bash"));
    assert!(entries
        .iter()
        .any(|entry| entry.text.starts_with("bash result: ")));
    assert_eq!(entries.last().unwrap().text, "pong from the fake model");

    let hidden = collect_transcript_entries(provider("codewhale"), raw, false);
    assert!(!hidden.iter().any(|entry| entry.role == "Tool"));
    assert_eq!(
        hidden
            .iter()
            .filter(|entry| entry.role == "Assistant")
            .count(),
        2
    );
    let value: Value = serde_json::from_str(raw).unwrap();
    assert_eq!(
        find_model_string(provider("codewhale"), &value).as_deref(),
        Some("deepseek-flash")
    );
}

#[test]
fn kiro_v3_transcript_entries_parse_messages_and_tools() {
    let raw = r#"
{"id":"u","payload":{"type":"user","content":"Run pwd"}}
{"id":"a","payload":{"type":"assistant","content":"I will check."}}
{"id":"c","payload":{"type":"tool_call","toolCallId":"call-1","toolName":"execute_bash","args":{"command":"pwd"},"status":"completed"}}
{"id":"r","payload":{"type":"tool_result","toolCallId":"call-1","content":"Output:\n/tmp\n\nExit Code: 0","success":true}}
{"id":"noise","payload":{"type":"usage_summary","status":"success"}}
"#;
    let entries = collect_transcript_entries(provider("kiro-cli"), raw, true);
    assert_eq!(entries[0].role, "User");
    assert_eq!(entries[0].text, "Run pwd");
    assert_eq!(entries[1].role, "Assistant");
    assert!(entries.iter().any(|entry| {
        entry.blocks.first().is_some_and(|block| {
            block.kind == TranscriptBlockKind::ToolCall
                && block.tool_name.as_deref() == Some("execute_bash")
        })
    }));
    assert!(entries.iter().any(|entry| entry.text.contains("Output:")));
}

#[test]
fn kiro_v2_transcript_entries_parse_messages_and_tools() {
    let raw = r#"
{"version":"v1","kind":"Prompt","data":{"content":[{"kind":"text","data":"Run pwd"}]}}
{"version":"v1","kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"Checking."},{"kind":"toolUse","data":{"toolUseId":"call-1","name":"shell","input":{"command":"pwd"}}}]}}
{"version":"v1","kind":"ToolResults","data":{"content":[{"kind":"toolResult","data":{"toolUseId":"call-1","content":[{"kind":"json","data":{"stdout":"/tmp\n"}}],"status":"success"}}]}}
"#;
    let entries = collect_transcript_entries(provider("kiro-cli"), raw, true);
    assert_eq!(entries[0].text, "Run pwd");
    assert_eq!(entries[1].text, "Checking.");
    assert!(entries.iter().any(|entry| {
        entry.blocks.first().is_some_and(|block| {
            block.kind == TranscriptBlockKind::ToolCall
                && block.tool_name.as_deref() == Some("shell")
        })
    }));
    assert!(entries.iter().any(|entry| entry.text.contains("stdout")));
}

#[test]
fn kiro_project_dir_uses_sha256_prefix_of_canonical_cwd() {
    use sha2::{Digest, Sha256};
    let cwd = tempfile::tempdir().unwrap();
    let canonical = fs::canonicalize(cwd.path()).unwrap();
    let expected = format!(
        "{:x}",
        Sha256::digest(canonical.to_string_lossy().as_bytes())
    );
    assert_eq!(
        kiro_project_dir(cwd.path().to_string_lossy().as_ref())
            .and_then(|path| path.file_name().map(|name| name.to_owned()))
            .and_then(|name| name.to_str().map(str::to_string)),
        Some(expected[..16].to_string())
    );
}

#[test]
fn kimi_project_dir_uses_md5_of_canonical_cwd() {
    let cwd = tempfile::tempdir().unwrap();
    let canonical = fs::canonicalize(cwd.path()).unwrap();
    let expected = format!("{:x}", md5::compute(canonical.to_string_lossy().as_bytes()));
    assert_eq!(
        kimi_project_dir(cwd.path().to_string_lossy().as_ref())
            .and_then(|path| path.file_name().map(|name| name.to_owned()))
            .and_then(|name| name.to_str().map(str::to_string)),
        Some(expected)
    );
}

#[test]
fn jsonl_stream_read_handles_partial_and_truncation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    fs::write(&path, "{\"a\":1}\n{\"b\"").unwrap();
    let read = read_jsonl_lines_since(&path, 0, "", 1024).unwrap();
    assert_eq!(read.lines, vec!["{\"a\":1}"]);
    assert_eq!(read.partial, "{\"b\"");

    fs::write(&path, "{\"c\":3}\n").unwrap();
    let read = read_jsonl_lines_since(&path, read.next_offset + 10, &read.partial, 1024).unwrap();
    assert!(read.truncated);
    assert_eq!(read.lines, vec!["{\"c\":3}"]);
}

#[test]
fn jsonl_stream_read_reports_when_max_window_skips_forward() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    fs::write(&path, "old\nmiddle\nnew\n").unwrap();

    let read = read_jsonl_lines_since(&path, 0, "", 8).unwrap();

    assert!(read.truncated);
    assert!(read.offset > 0);
    assert_eq!(read.lines, vec!["new"]);
}

#[test]
fn jsonl_history_read_returns_complete_bounded_tail_lines() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    fs::write(&path, "old\nmiddle\nnew\n").unwrap();

    let read = read_jsonl_lines_before(&path, None, 8).unwrap();

    assert!(read.truncated);
    assert!(read.offset > 0);
    assert_eq!(read.next_offset, fs::metadata(&path).unwrap().len());
    assert_eq!(
        read.lines,
        vec![("old\nmiddle\n".len() as u64, "new".to_string())]
    );
}

#[test]
fn jsonl_history_read_pages_before_requested_offset() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    fs::write(&path, "old\nmiddle\nnew\n").unwrap();
    let before_new = "old\nmiddle\n".len() as u64;

    let read = read_jsonl_lines_before(&path, Some(before_new), 128).unwrap();

    assert!(!read.truncated);
    assert_eq!(read.offset, 0);
    assert_eq!(read.next_offset, before_new);
    assert_eq!(
        read.lines,
        vec![(0, "old".to_string()), (4, "middle".to_string())]
    );
}

#[test]
fn jsonl_history_read_clamps_before_offset_past_eof() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("session.jsonl");
    fs::write(&path, "one\ntwo\n").unwrap();

    let read = read_jsonl_lines_before(&path, Some(99_999), 128).unwrap();

    assert_eq!(read.next_offset, fs::metadata(&path).unwrap().len());
    assert_eq!(
        read.lines,
        vec![(0, "one".to_string()), (4, "two".to_string())]
    );
}

#[test]
fn transcript_window_collection_returns_offset_for_first_retained_entry() {
    let lines = vec![
        (
            0,
            r#"{"type":"user","content":[{"type":"text","text":"old"}]}"#.to_string(),
        ),
        (50, r#"{"type":"assistant","content":"middle"}"#.to_string()),
        (100, r#"{"type":"assistant","content":"new"}"#.to_string()),
    ];

    let (entries, offset) =
        collect_transcript_entries_from_window(provider("grok"), &lines, false, 2);

    assert_eq!(offset, 50);
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].text, "middle");
    assert_eq!(entries[1].text, "new");
}

#[test]
fn opencode_is_detected_but_not_file_backed_yet() {
    let manifest = test_manifest("opencode");
    let error = resolve_provider_transcript(&manifest).unwrap_err();
    assert!(error.contains("outside JSONL"));
}

fn markdown_test_snapshot() -> TranscriptSnapshot {
    let mut entries: Vec<TranscriptEntry> = Vec::new();
    push_user_transcript_entry(&mut entries, "hello there");
    push_transcript_entry(&mut entries, "Reasoning", "thinking hard".to_string());
    push_transcript_entry(&mut entries, "Assistant", "here is my answer".to_string());
    push_tool_call_entry(
        &mut entries,
        Some("t1"),
        "Bash",
        "ls -la".to_string(),
        HashMap::new(),
    );
    push_file_change_entry(
        &mut entries,
        Some("f1".to_string()),
        Some("Edit".to_string()),
        Some("src/main.rs".to_string()),
        "edit",
        Some("--- a/src/main.rs\n+++ b/src/main.rs\n@@\n-old\n+new".to_string()),
        None,
        HashMap::new(),
    );
    TranscriptSnapshot {
        session_id: "s".to_string(),
        provider: "claude".to_string(),
        source: "test".to_string(),
        provider_session_id: None,
        path: "/tmp/x.jsonl".to_string(),
        start_offset: 0,
        entries,
        next_offset: 0,
        updated_at: 0,
        model: None,
    }
}

#[test]
fn model_detection_finds_provider_model_fields() {
    // Claude: nested under message; last line wins.
    let claude = [
        r#"{"type":"assistant","message":{"model":"claude-opus-4-6","content":[]}}"#,
        r#"{"type":"user","message":{"content":"hi"}}"#,
        r#"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[]}}"#,
    ];
    assert_eq!(
        detect_model_in_lines(provider("claude"), claude.iter().copied()),
        Some("claude-opus-4-8".to_string())
    );
    // Codex: turn-context payload.
    let codex = [r#"{"type":"turn_context","payload":{"model":"gpt-5-codex"}}"#];
    assert_eq!(
        detect_model_in_lines(provider("codex"), codex.iter().copied()),
        Some("gpt-5-codex".to_string())
    );
    // Sentences/paths under a `model` key are not model names.
    let noise = [
        r#"{"model":"a plain sentence, not a model id"}"#,
        "not json",
    ];
    assert_eq!(
        detect_model_in_lines(provider("claude"), noise.iter().copied()),
        None
    );
}

#[test]
fn session_info_header_lists_id_cli_model_and_command() {
    let session = crate::state::SessionInfo {
        id: "sess-123".to_string(),
        project_id: "p".to_string(),
        label: "Fix login flow".to_string(),
        custom_title: false,
        command: "claude --dangerously-skip-permissions".to_string(),
        created_at: 0,
        owner_principal_id: None,
        created_by_device_id: None,
        source_preset_id: None,
        tag_id: None,
        worktree_path: None,
        worktree_branch: None,
        parent_session_id: None,
        spawned_by: None,
        role: None,
        task: None,
    };
    let mut snapshot = markdown_test_snapshot();
    snapshot.model = Some("claude-opus-4-8".to_string());
    let header = session_info_header(&session, &snapshot);
    assert!(header.starts_with("# Fix login flow\n"));
    assert!(header.contains("`sess-123`"));
    assert!(header.contains("Unpeel MCP sessions tool"));
    assert!(header.contains("- CLI: claude\n"));
    assert!(header.contains("- Model: claude-opus-4-8\n"));
    assert!(header.contains("- Command: `claude --dangerously-skip-permissions`\n"));

    // No model detected → the line is omitted rather than "unknown".
    snapshot.model = None;
    assert!(!session_info_header(&session, &snapshot).contains("- Model:"));
}

#[test]
fn markdown_defaults_include_user_assistant_and_file_changes_only() {
    let snapshot = markdown_test_snapshot();
    let md = format_transcript_markdown(&snapshot, &TranscriptSettings::default());
    assert!(md.contains("## User"));
    assert!(md.contains("hello there"));
    assert!(md.contains("## Assistant"));
    // File changes on by default.
    assert!(md.contains("Edited src/main.rs"));
    assert!(md.contains("```diff"));
    // Reasoning and tool calls off by default.
    assert!(!md.contains("### Reasoning"));
    assert!(!md.contains("### Tool: Bash"));
}

#[test]
fn markdown_toggles_control_each_content_type() {
    let snapshot = markdown_test_snapshot();
    let opts = TranscriptSettings {
        include_user: false,
        include_assistant: true,
        include_reasoning: true,
        include_tools: true,
        include_file_changes: false,
        include_plan_updates: true,
        include_session_info: true,
        max_entries: 0,
    };
    let md = format_transcript_markdown(&snapshot, &opts);
    assert!(!md.contains("## User"));
    assert!(md.contains("### Reasoning"));
    assert!(md.contains("thinking hard"));
    assert!(md.contains("### Tool: Bash"));
    // File changes disabled.
    assert!(!md.contains("Edited src/main.rs"));
    assert!(!md.contains("```diff"));
}

#[test]
fn muse_command_maps_to_provider_and_resume_ids() {
    assert_eq!(
        transcript_provider_for_command("muse --yolo"),
        Some(provider("muse"))
    );
    assert_eq!(
        resume_id_from_command(provider("muse"), "muse resume 12345678-aaaa --yolo"),
        Some("12345678-aaaa".to_string())
    );
    assert_eq!(
        resume_id_from_command(provider("muse"), "muse resume --last"),
        None
    );
}

#[test]
fn muse_entries_cover_prompt_text_reasoning_and_tools() {
    // Shapes captured live from Muse Code 0.1.0 session.jsonl (event-sourced
    // envelopes with the conversation in `payload.event`).
    let raw = concat!(
        r#"{"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"/tmp/repo","provider_id":"meta"}}}"#,
        "\n",
        r#"{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"started","prompt":"hello muse"}}}"#,
        "\n",
        r#"{"payload_type":"run.model.configured","payload":{"kind":"run_model","record":{"provider_id":"meta","model_id":"muse-spark-1.2"}}}"#,
        "\n",
        r#"{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"reasoning_committed","message_id":"m0","text":"pondering"}}}"#,
        "\n",
        r#"{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"assistant_tool_calls_committed","message_id":"m1","tool_calls":[{"id":"fc1","call_id":"c1","name":"read_file","args":"{\"path\":\"src/main.rs\"}"}]}}}"#,
        "\n",
        r#"{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"tool_result_batch_committed","batch_id":"m1","results":[{"tool_call_index":0,"tool_call_id":"c1","text":"fn main() {}"}]}}}"#,
        "\n",
        r#"{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"assistant_message_committed","message_id":"m2","text":"done reading"}}}"#,
        "\n",
    );

    let entries = collect_transcript_entries(provider("muse"), raw, true);
    let roles: Vec<&str> = entries.iter().map(|entry| entry.role).collect();
    assert_eq!(roles, ["User", "Reasoning", "Tool", "Tool", "Assistant"]);
    assert_eq!(entries[0].text, "hello muse");
    assert!(entries[2].text.contains("read_file"));
    assert!(entries[3].text.contains("fn main() {}"));
    assert_eq!(
        entries[3].blocks[0].tool_name.as_deref(),
        Some("read_file"),
        "result resolves the tool name through its call id"
    );
    assert_eq!(entries[4].text, "done reading");

    // Without tools, only the conversation text survives.
    let compact = collect_transcript_entries(provider("muse"), raw, false);
    let roles: Vec<&str> = compact.iter().map(|entry| entry.role).collect();
    assert_eq!(roles, ["User", "Assistant"]);

    // Muse's package adapter owns its `model_id` field and placeholder rule.
    assert_eq!(
        detect_model_in_lines(provider("muse"), raw.lines()),
        Some("muse-spark-1.2".to_string())
    );
}

#[test]
fn transcript_title_candidate_prefers_claude_summary() {
    let raw = concat!(
        r#"{"type":"summary","summary":"Fixing the auth token refresh flow","leafUuid":"leaf-1"}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"the login page loops after token expiry"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#,
        "\n",
    );
    assert_eq!(
        transcript_title_candidate(provider("claude"), raw),
        Some("Fixing the auth token refresh flow".to_string())
    );
}

#[test]
fn transcript_title_candidate_falls_back_to_first_user_prompt() {
    let raw = concat!(
        r#"{"type":"user","message":{"role":"user","content":"the login page loops after token expiry"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"second prompt"}}"#,
        "\n",
    );
    assert_eq!(
        transcript_title_candidate(provider("claude"), raw),
        Some("the login page loops after token expiry".to_string())
    );
}

#[test]
fn transcript_title_candidate_skips_untitleable_user_entries() {
    // Slash commands, compact-continuation preambles, and command wrappers
    // fall through to the first real prompt.
    let raw = concat!(
        r#"{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"<command-name>/resume</command-name>"}}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"/model opus"}}"#,
        "\n",
        r#"{"type":"user","message":{"role":"user","content":"now fix the header bug"}}"#,
        "\n",
    );
    assert_eq!(
        transcript_title_candidate(provider("claude"), raw),
        Some("now fix the header bug".to_string())
    );

    // Nothing titleable → None, so apply_manifest_auto_title never runs.
    let raw = r#"{"type":"user","message":{"role":"user","content":"/resume"}}"#;
    assert_eq!(transcript_title_candidate(provider("claude"), raw), None);
}

#[test]
fn transcript_title_candidate_skips_grok_injections() {
    // SessionStart writes the skills reminder before the user types. Auto-title
    // must no-op so the later first prompt (PTY or transcript) can win.
    let reminder_only = concat!(
        r#"{"type":"system","content":"you are grok"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<system-reminder>\nThe following skills are available\n</system-reminder>"}],"synthetic_reason":"system_reminder"}"#,
        "\n",
    );
    assert_eq!(
        transcript_title_candidate(provider("grok"), reminder_only),
        None
    );

    let with_prompt = concat!(
        r#"{"type":"system","content":"you are grok"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<user_info>\nOS Version: macos\n</user_info>"}]}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<system-reminder>\nThe following skills are available\n</system-reminder>"}],"synthetic_reason":"system_reminder"}"#,
        "\n",
        r#"{"type":"user","content":[{"type":"text","text":"<user_query>\nleft align the panel titles\n</user_query>"}],"prompt_index":0}"#,
        "\n",
    );
    assert_eq!(
        transcript_title_candidate(provider("grok"), with_prompt),
        Some("left align the panel titles".to_string())
    );
}

#[test]
fn transcript_title_candidate_ignores_truncated_tail_line() {
    // A head-window read can cut the last JSONL line mid-record; it must be
    // skipped, not break the scan.
    let raw = concat!(
        r#"{"type":"user","message":{"role":"user","content":"profile the slow query"}}"#,
        "\n",
        r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"te"#,
    );
    assert_eq!(
        transcript_title_candidate(provider("claude"), raw),
        Some("profile the slow query".to_string())
    );
}

/// Fork-only (#64): a Claude line with this usage, as Claude Code writes it.
fn claude_reply(model: &str, sidechain: bool, input: u64, created: u64, read: u64) -> String {
    serde_json::json!({
        "type": "assistant",
        "isSidechain": sidechain,
        "message": {
            "model": model,
            "role": "assistant",
            "content": [{ "type": "text", "text": "done" }],
            "usage": {
                "input_tokens": input,
                "cache_creation_input_tokens": created,
                "cache_read_input_tokens": read,
                "output_tokens": 1576,
            },
        },
    })
    .to_string()
}

fn claude_compact_boundary(post_tokens: u64) -> String {
    serde_json::json!({
        "type": "system",
        "subtype": "compact_boundary",
        "content": "Conversation compacted",
        "compactMetadata": { "trigger": "manual", "preTokens": 566_116, "postTokens": post_tokens },
    })
    .to_string()
}

fn context_in(lines: &[String]) -> Option<ContextUsage> {
    let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
    context_usage_in_lines(provider("claude"), &lines)
}

/// Claude Code's own figure: the latest main-chain request's input, cache
/// writes and cache reads. Its output, subagents' requests and synthetic
/// replies are not context.
#[test]
fn claude_context_is_the_latest_main_chain_requests_input() {
    let user = r#"{"type":"user","message":{"role":"user","content":"go"}}"#.to_owned();
    let lines = [
        claude_reply("claude-opus-5-5", false, 3, 1_000, 90_000),
        user.clone(),
        claude_reply("claude-opus-5-5", false, 2, 2_393, 148_826),
        claude_reply("claude-sonnet-5-5", true, 9, 9_000, 400_000),
        claude_reply("<synthetic>", false, 0, 0, 0),
        r#"{"type":"system","subtype":"stop_hook_summary"}"#.to_owned(),
        "not json".to_owned(),
    ];
    assert_eq!(
        context_in(&lines),
        Some(ContextUsage {
            tokens: 151_221,
            model: Some("claude-opus-5-5".into()),
        })
    );
    assert_eq!(context_in(&[user]), None, "no reply yet");
}

/// A compaction leaves its `postTokens` until the next reply; the model is
/// still the last reply's.
#[test]
fn claude_context_after_a_compaction_is_what_it_left() {
    let before = claude_reply("claude-opus-5-5", false, 1, 6_000, 560_000);
    let compacted = [before.clone(), claude_compact_boundary(23_026)];
    assert_eq!(
        context_in(&compacted),
        Some(ContextUsage {
            tokens: 23_026,
            model: Some("claude-opus-5-5".into()),
        })
    );
    let next = [
        before,
        claude_compact_boundary(23_026),
        claude_reply("claude-opus-5-5", false, 5, 4_000, 26_000),
    ];
    assert_eq!(context_in(&next).map(|usage| usage.tokens), Some(30_005));
}

/// A compaction record without what it left: the context is unknown, not
/// empty.
#[test]
fn claude_context_after_a_compaction_of_unknown_size_is_unknown() {
    let boundary = serde_json::json!({
        "type": "system",
        "subtype": "compact_boundary",
        "compactMetadata": { "trigger": "manual" },
    })
    .to_string();
    let lines = [
        claude_reply("claude-opus-5-5", false, 1, 6_000, 560_000),
        boundary,
    ];
    assert_eq!(context_in(&lines), None);
}

/// Claude Code 2.1.312's own transcript of a turn and a `/compact` after it
/// (paths and signatures removed).
#[test]
fn claude_context_reads_a_real_transcript() {
    let raw = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../runtimes/claude-code/fixtures/context-compaction.jsonl"
    ))
    .expect("fixture");
    let lines: Vec<String> = raw.lines().map(str::to_owned).collect();
    let boundary = lines
        .iter()
        .position(|line| line.contains("\"compact_boundary\""))
        .expect("a compaction");
    let haiku = Some("claude-haiku-4-5-20251001".to_owned());
    assert_eq!(
        context_in(&lines[..boundary]),
        Some(ContextUsage {
            tokens: 48_745,
            model: haiku.clone(),
        })
    );
    assert_eq!(
        context_in(&lines),
        Some(ContextUsage {
            tokens: 13_307,
            model: haiku,
        })
    );
}

#[test]
fn context_percent_rounds_like_claude_codes_status_line() {
    let reading = |tokens, window| ContextReading {
        tokens,
        model: None,
        window,
        compact_command: None,
        baseline: 0,
    };
    assert_eq!(reading(151_221, Some(1_000_000)).percent(), Some(15));
    assert_eq!(reading(395_000, Some(1_000_000)).percent(), Some(40));
    assert_eq!(reading(394_999, Some(1_000_000)).percent(), Some(39));
    assert_eq!(reading(250_000, Some(200_000)).percent(), Some(100));
    assert_eq!(reading(1, None).percent(), None, "unknown window");
}

/// Fork-only (#68): Codex's footer counts the window above a 12,000-token
/// baseline (`tui/src/token_usage.rs` at rust-v0.167.0), so 40% used is
/// 110,560 of a 258,400 window, "60% context left".
#[test]
fn context_percent_leaves_the_baseline_out_of_tokens_and_window() {
    let reading = |tokens| ContextReading {
        tokens,
        model: None,
        window: Some(258_400),
        compact_command: None,
        baseline: 12_000,
    };
    assert_eq!(reading(110_560).percent(), Some(40));
    assert_eq!(
        reading(103_360).percent(),
        Some(37),
        "40% of the raw window"
    );
    assert_eq!(reading(9_000).percent(), Some(0), "under the baseline");
    let no_room = ContextReading {
        window: Some(12_000),
        ..reading(20_000)
    };
    assert_eq!(
        no_room.percent(),
        None,
        "a window no larger than the baseline"
    );
}

#[test]
fn claude_context_windows_come_from_its_runtime_package() {
    let claude = provider("claude");
    for (model, window) in [
        ("claude-opus-5-5", Some(1_000_000)),
        ("claude-opus-5-5[1m]", Some(1_000_000)),
        ("claude-sonnet-5-5", Some(1_000_000)),
        ("claude-fable-5-1", Some(1_000_000)),
        ("claude-haiku-5-5", Some(1_000_000)),
        ("claude-opus-4-8", Some(1_000_000)),
        ("claude-sonnet-4-6", Some(1_000_000)),
        ("claude-haiku-4-5-20251001", Some(200_000)),
        ("claude-opus-4-5", None),
        ("gpt-5", None),
    ] {
        assert_eq!(context_window(claude, model), window, "{model}");
    }
    assert_eq!(context_window(provider("codex"), "claude-opus-5-5"), None);
    assert_eq!(compact_command(claude).as_deref(), Some("/compact"));
    assert_eq!(compact_command(provider("cline")), None);
    assert_eq!(context_baseline(claude), 0);
}

/// Fork-only (#68): Codex lines as rust-v0.167.0 writes them.
fn codex_token_count(last_total: u64) -> String {
    serde_json::json!({
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": { "input_tokens": 900_000, "total_tokens": 950_000 },
                "last_token_usage": {
                    "input_tokens": last_total - 2_000,
                    "cached_input_tokens": 90_000,
                    "cache_write_input_tokens": 0,
                    "output_tokens": 2_000,
                    "reasoning_output_tokens": 500,
                    "total_tokens": last_total,
                },
                "model_context_window": 258_400,
            },
            "rate_limits": null,
        },
    })
    .to_string()
}

fn codex_turn_context(model: &str) -> String {
    serde_json::json!({
        "type": "turn_context",
        "payload": { "turn_id": "turn-1", "cwd": "/tmp/p", "model": model },
    })
    .to_string()
}

fn codex_context_in(lines: &[String]) -> Option<ContextUsage> {
    let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
    context_usage_in_lines(provider("codex"), &lines)
}

/// Codex's own figure: the newest `token_count`'s `last_token_usage`, not
/// billing records or rate-limit-only lines; the model is the newest
/// `turn_context`'s.
#[test]
fn codex_context_is_the_latest_responses_last_token_usage() {
    let rate_limits_only =
        r#"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#;
    let billing = r#"{"type":"token_usage_record","payload":{"usage":{"total_tokens":700000}}}"#;
    let lines = [
        codex_turn_context("gpt-5.5"),
        codex_token_count(90_000),
        codex_turn_context("gpt-5.6-sol"),
        codex_token_count(131_234),
        rate_limits_only.to_owned(),
        billing.to_owned(),
        r#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#.to_owned(),
        "not json".to_owned(),
    ];
    assert_eq!(
        codex_context_in(&lines),
        Some(ContextUsage {
            tokens: 131_234,
            model: Some("gpt-5.6-sol".into()),
        })
    );
    assert_eq!(
        codex_context_in(&[codex_turn_context("gpt-5.5")]),
        None,
        "no response yet"
    );
    assert_eq!(
        codex_context_in(&[codex_token_count(5_000)]),
        Some(ContextUsage {
            tokens: 5_000,
            model: None,
        }),
        "no turn_context in the tail"
    );
}

/// A `compacted` line newer than every `token_count` is a compaction whose
/// estimate is not written yet: unknown, not the old figure.
#[test]
fn codex_context_during_a_compaction_is_unknown() {
    let compacted = r#"{"type":"compacted","payload":{"message":"summary"}}"#.to_owned();
    let lines = [
        codex_turn_context("gpt-5.6-sol"),
        codex_token_count(200_000),
        compacted.clone(),
    ];
    assert_eq!(codex_context_in(&lines), None);
    let after = [
        codex_turn_context("gpt-5.6-sol"),
        codex_token_count(200_000),
        compacted,
        codex_turn_context("gpt-5.6-sol"),
        codex_token_count(18_000),
    ];
    assert_eq!(
        codex_context_in(&after).map(|usage| usage.tokens),
        Some(18_000)
    );
}

/// A rollout constructed from rust-v0.167.0's own line shapes (no real
/// rollout is read for this fork): a turn, then a `/compact`, whose
/// `token_count` after the `compacted` line holds Codex's estimate.
#[test]
fn codex_context_reads_a_constructed_rollout() {
    let raw = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../runtimes/codex/fixtures/context-compaction-constructed.jsonl"
    ))
    .expect("fixture");
    let lines: Vec<String> = raw.lines().map(str::to_owned).collect();
    let compacted = lines
        .iter()
        .position(|line| line.contains("\"type\":\"compacted\""))
        .expect("a compaction");
    let sol = Some("gpt-5.6-sol".to_owned());
    assert_eq!(
        codex_context_in(&lines[..compacted]),
        Some(ContextUsage {
            tokens: 131_234,
            model: sol.clone(),
        })
    );
    assert_eq!(codex_context_in(&lines[..=compacted]), None);
    assert_eq!(
        codex_context_in(&lines),
        Some(ContextUsage {
            tokens: 18_532,
            model: sol,
        })
    );
}

#[test]
fn codex_context_windows_and_command_come_from_its_runtime_package() {
    let codex = provider("codex");
    for (model, window) in [
        ("gpt-6-astra", Some(258_400)),
        ("gpt-6-sol", Some(258_400)),
        ("gpt-6.1-sol", Some(258_400)),
        ("gpt-6.1-terra", Some(475_000)),
        ("gpt-5.6-luna", Some(258_400)),
        ("gpt-5.5", Some(258_400)),
        ("gpt-daybreak-red-latest", Some(353_400)),
        ("codex-auto-review", Some(258_400)),
        ("gpt-5", None),
        ("o3", None),
        ("claude-opus-5-5", None),
    ] {
        assert_eq!(context_window(codex, model), window, "{model}");
    }
    assert_eq!(compact_command(codex).as_deref(), Some("/compact"));
    assert_eq!(context_baseline(codex), 12_000);
    let reading = ContextReading {
        tokens: 131_234,
        model: Some("gpt-5.6-sol".into()),
        window: context_window(codex, "gpt-5.6-sol"),
        compact_command: compact_command(codex),
        baseline: context_baseline(codex),
    };
    // Codex's footer: 52% context left.
    assert_eq!(reading.percent(), Some(48));
}

fn codewhale_fixture(name: &str) -> String {
    std::fs::read_to_string(format!(
        "{}/../../runtimes/codewhale/fixtures/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .expect("fixture")
}

/// Real Codewhale 0.10.2 saved sessions (a turn against a local stub model,
/// then `/compact`; paths replaced by ones of the same length). Codewhale's
/// own estimate for them is in its "Made room: 2 → 4 messages (0 removed),
/// ~6236 → ~6634 tokens" note.
#[test]
fn codewhale_context_is_its_own_estimate_of_a_real_session() {
    let codewhale = provider("codewhale");
    let flash = Some("deepseek-flash".to_owned());
    let before = codewhale_fixture("context-before-compact.json");
    assert_eq!(
        context_usage_in_lines(codewhale, &[before.as_str()]),
        Some(ContextUsage {
            tokens: 6_236,
            model: flash.clone(),
        })
    );
    let after = codewhale_fixture("context-after-compact.json");
    assert_eq!(
        context_usage_in_lines(codewhale, &[after.as_str()]),
        Some(ContextUsage {
            tokens: 6_634,
            model: flash,
        })
    );
}

/// Each block's estimate: a quarter of its text's bytes, a tool call's
/// compact JSON, a tool result's content plus 1,000 per image; the system
/// prompt's conservative estimate per saved block; 12 per message plus 48.
#[test]
fn codewhale_context_counts_blocks_like_codewhale() {
    let document = serde_json::json!({
        "metadata": { "model": "auto" },
        "last_auto_route": { "model": "deepseek-v4-pro" },
        "system_prompt": "abcdefghi\n\n---\n\nééé",
        "messages": [
            { "role": "user", "content": [{ "type": "text", "text": "12345678" }] },
            { "role": "assistant", "content": [
                { "type": "thinking", "thinking": "1234" },
                { "type": "tool_use", "id": "t", "name": "bash", "input": { "a": 1 } },
            ] },
            { "role": "user", "content": [
                { "type": "tool_result", "tool_use_id": "t", "content": "12345678",
                  "content_blocks": [{ "type": "image" }, { "type": "text" }] },
                { "type": "image_url", "image_url": { "url": "x" } },
            ] },
        ],
    })
    .to_string();
    // text 2, thinking 1, tool_use `{"a":1}` 1, tool_result 2 + 1000,
    // image 1000; system 3 + max(1, 2); framing 36 + 48.
    assert_eq!(
        context_usage_in_lines(provider("codewhale"), &[document.as_str()]),
        Some(ContextUsage {
            tokens: 2 + 1 + 1 + 1_002 + 1_000 + 5 + 84,
            model: Some("deepseek-v4-pro".into()),
        })
    );
    let empty = r#"{"metadata":{"model":"deepseek-flash"},"messages":[]}"#;
    assert_eq!(
        context_usage_in_lines(provider("codewhale"), &[empty]),
        None,
        "no conversation yet"
    );
}

#[test]
fn codewhale_context_windows_and_command_come_from_its_runtime_package() {
    let codewhale = provider("codewhale");
    for (model, window) in [
        ("deepseek-flash", Some(1_000_000)),
        ("deepseek-v4-pro", Some(1_000_000)),
        ("deepseek-v4-flash", Some(1_000_000)),
        ("deepseek-reasoner", Some(1_000_000)),
        ("deepseek-ai/deepseek-v4-pro", Some(1_000_000)),
        ("deepseek-coder", None),
        ("gpt-5.5", None),
    ] {
        assert_eq!(context_window(codewhale, model), window, "{model}");
    }
    assert_eq!(compact_command(codewhale).as_deref(), Some("/compact"));
    assert_eq!(context_baseline(codewhale), 0);
}
