<!-- Split out of the repo-root AGENTS.md (2026-08-05). The root AGENTS.md holds the map, hard rules, and invariants; this file is the full detail for its topic. -->

## Built-in Unpeel MCP server

`unpeel-host __mcp__` is one MCP server named **`unpeel`**. Do not call the
whole server “Sessions MCP” or rename it “Agents MCP”: `sessions` and `agents`
are sibling domains with different identities. A Session is the Host-owned
terminal container; an agent is a recognized runtime occurrence currently
occupying one. The other domains are `workspace`, `artifacts`, `browser`,
preview `apps`, and the root `skills` registry.

**Compatibility gate:** Settings ▸ Features ▸ Sessions use
(`AppFeature.sessionsMcp`, `UNPEEL_DEV_SESSIONS_MCP=1`; shipped, no longer
listed as experimental since 2026-09-08) still owns
the saved `mcp_enabled` bit. For compatibility that one bit enables
`sessions`, `agents`, `workspace`, and `artifacts`; do not rename the persisted
field, environment variable, feature id, or provider config filenames. Existing
live Sessions keep their launch-time domain set until the runtime/MCP client is
restarted. Transcript display settings remain under Settings ▸ Transcripts.

Terminal messaging may later become channel-based — terminal↔terminal is the
default today; see the private "sessions-mcp-channels" design record. Every
`send_text` delivery carries `[message from id:<sender>, channel: terminal]`.
Route inter-session text through
`agent_send::deliver_text` (fork-only: under the draft guard, #61, #66); do
not bake “the other end is a PTY” into future channel semantics.

> **Unified surface (2026-07-18, renamed 2026-07-25):** `unpeel-host __mcp__`
> is now the single
> **`unpeel`** MCP server for all built-in capabilities (named `unpeel-mcp`
> until 2026-07-25; the old name lives on only as pruned legacy config
> entries and in the pre-rename config *file names*, which are kept so
> restart commands recorded by older sessions keep resolving): **one action-enum
> tool per domain** — `sessions`, `agents`, `workspace`, `artifacts`,
> `browser`, `apps`, and `skills` — instead of one server per domain
> with a dozen tools each. Schemas are terse (~1.5k tokens for both domains,
> enforced by a byte-ceiling test in `mcp_host.rs`); full per-action docs load
> lazily via `{"action":"help"}`. A domain is advertised only if the caller's
> saved domain grant (`mcp_enabled` / `browser_mcp_enabled`) is set — a session launched without a domain never
> pays its context cost — and
> per-call gates still apply live. Legacy per-tool names and the standalone
> `__browser_mcp__` argv keep working for sessions launched pre-unification.
> The separate `*_client_registered` fields are setup evidence: the user has
> installed that runtime's Unpeel integration on this Host
> (`~/.unpeel/integrations/<runtime>.json`), the runtime declares the domain,
> and the launch granted it. They stay false for a blank shell and for a
> runtime whose integration was never installed; a CLI configured by hand
> with `unpeel-host __mcp__` still receives only the saved grants.
> Registration is **one persistent entry per provider**, written only by the
> explicit integration install (never by a launch): every provider points at
> the same shim `~/.unpeel/bin/unpeel-mcp` (claude user-scope `~/.claude.json`,
> codex `[mcp_servers.unpeel]` in `config.toml`, Kimi Code `~/.kimi-code/
> mcp.json`, cursor `~/.cursor/mcp.json`, cline's user MCP settings, kiro
> `settings/mcp.json`, fx `~/.fx/mcp.json`, muse's plugin manifest). The shim
> runs `__mcp_gate__ unified`; the gate reads the calling Session's manifest
> grants and serves no tools outside a hosted Session, which is what makes a
> global registration safe. Persistent configs prune the Unpeel-owned
> pre-rename `unpeel-mcp`/`unpeel-sessions`/`unpeel-browser` entries.
>

- Server: `crates/unpeel-core/src/mcp_host.rs`, run as `unpeel-host __mcp__`. Speaks MCP JSON-RPC over stdio; hand-rolled, no SDK dependency. The `unpeel` CLI is a second client of the same dispatcher (`mcp_host::call_tool`, `unpeel mcp …` and the family verbs in `docs/agents/cli.md`), so an agent working from the shell gets identical identity, grants, and write approvals — including `unpeel send` from inside a Session.
- It talks directly to per-session artifacts (`manifest.json`, `output.bin`, `session.sock`) under `~/.unpeel/app-sessions/`; it does not need the app running, only the session hosts.
- Each provider/client starts its own stdio sidecar process. This is
  intentionally not embedded in the long-lived `unpeel serve` worker: MCP
  connection lifetime follows the agent client, while Host authority follows
  the workspace. Reusable implementation stays in `unpeel-core`; workspace
  policy, approvals, and semantic effects converge on the worker/capability
  adapters, while terminal data operations may remain direct to Session
  artifacts and `session.sock`.
- Caller identity is process ancestry (`session_identity`, ADR 0013): the
  hosted login shell (`manifest.pid`) is an ancestor of everything the
  session's agent spawns, and only a start-time-verified
  `PidIdentity::Matches` ancestor grants identity (fail closed on recycled
  pids and unverifiable legacy manifests). An inherited `UNPEEL_SESSION_ID`
  is a claim: it holds only when that Session is such an ancestor, and a
  process that kept the variable but left the tree (Codex's shared daemon)
  is refused, never redirected. When a launcher strips the environment from
  its MCP children (cursor-agent does), the nearest verified ancestor is the
  identity. The MCP gate also requires that every process between it and
  that ancestor share the ancestor's POSIX session; the gate itself may lead
  its own (ADR 0014). So a `setsid` helper such as a shared daemon that is
  still a Session process's child gives its servers no tools. Writing into
  the calling session's own terminal is refused.
- `agents.read_transcript` uses the shared provider transcript API in
  `crates/unpeel-core/src/transcripts/mod.rs`, so adapter/parser changes affect
  MCP and remote clients together. It refuses a transcript when the observed
  runtime occupant is not bound to the saved launch runtime.

Advertised ownership (old mixed `sessions` spellings remain decode-only):

- `sessions`: `current`, `list`, `inspect`, `read_screen`, `read_output`,
  `wait_for_text`, `send_text`, `send_keys`, `report`, plus the fork-only
  `inbox` and `stop` (Super Agent, below). This domain reports
  terminal/container state only; `inspect` no
  longer smuggles in provider transcript or agent identity.
  - Suggested input: `read_screen` and `inspect`'s screen tail bracket text
    the program drew faint (SGR 2) from the cursor onward on the cursor's row
    as `⟪suggested: …⟫`, with a `suggested_input="…"` header line saying
    nobody typed it. That is how an input box shows a proposed reply or a
    placeholder (Claude Code's prompt suggestion); typed input is drawn in
    the normal pen. Plain text would show the two identically. The Host
    finds the span while rendering the snapshot
    (`TerminalViewportSnapshot::suggested_input`, a byte range into one row;
    style runs carry `faint`), and `screen_read.rs` renders it.
    `wait_for_text` matches the unmarked rows.
  - Draft guard (fork-only, #61, ADR 0011): `send_text` and `send_keys`,
    and `report` while no Host worker runs (#66), send every write with
    `unless_typed_since` = now − 3 s and `unless_draft`, and the target's
    PTY core refuses them while the user
    typed in the last 3 s or their unsent input is on the line. Nothing is
    written, and the result says `Not sent (typing)` or `Not sent (draft)`;
    `Not submitted (typing)` means a key landed after the paste, which waits
    on the line. `send_keys` stops at the refused key ("Sent 1 of 3 keys").
    Suggested input is no draft, and a select menu takes keys over one
    (one drawn under the cursor, or anywhere while the cursor is hidden;
    output quoting a menu above the line is none, #72). A
    draft whose keys the user erased, or that a program took without Enter
    and moved on from (#65), is no draft either; one that wraps or whose
    input box moves still is. The call refuses rather than waits: send again
    once the user is done, or ask them. A target whose PTY core predates the
    guard (no `draft_guard` in its manifest) is written unchecked, and the
    result ends `(unguarded: …)`.
    PTY proof: `send_text_draft_guard`.
  - Submission (fork-only, #78): a submitted `send_text`, a pasted
    `report` and the Inbox's batch are one bracketed paste, a settle, then
    Enter twice (`session_input`), because some full-screen agent TUIs
    swallow the first. A runtime package that submits on the first declares
    `[input] enters_after_paste = 1` (Codewhale, whose second Enter opens
    the sent message's pager); the count comes from the target's recognized
    runtime, two with none. PTY proof: `paste_enters`.
- `agents`: `list`, `get`, `read_transcript`, `wait`. Every action targets one
  explicit recognized occurrence; the unreleased group-wide wait and summary
  actions were removed. `list` returns an occurrence-bound `agent_ref`
  (`session_id`, runtime id, pid/start time, runtime launch generation).
  Follow-up operations validate it so a replacement foreground process cannot
  be mistaken for the same agent. `session_id` remains a weaker compatibility
  target.
- `workspace`: `list_presets`, `list_projects`, `create_worktree`,
  `list_worktrees`, the fork-only Scheduled Tasks reads `list_schedules` and
  `list_schedule_runs` and the Super Agent's writes `create_schedule`,
  `edit_schedule`, `delete_schedule` and `run_schedule`, plus the fork-only
  Super Agent group actions `create_group`, `rename_group`, `remove_group`
  and `move_session` (Super Agent, below). Worktree creation remains opt-in
  and never launches a Session. All of them but the schedule writes are
  answered by the MCP host itself from this home's `app-state.json` and git
  (`crates/unpeel-core/src/workspace_tools.rs`, `supervision_groups.rs`,
  fork-only); no app or Host route is involved:
  - `list_presets` uses the same filter `sessions create` resolves `preset`
    against (`workspace_tools::usable_presets`): enabled, global or scoped to
    the project, project-scoped first; a group or worktree id gets its root
    Project's presets too. Each row: `id`, `label`, `command`,
    `project_id` (null = global), `quick_launch`, and `agent_preset` (an
    Agent Preset, the only kind a Scheduled Task's instructions go to).
  - `list_projects` (open to every caller) lists every Project in sidebar
    tree order: `{id, name, path, kind: root|group|worktree, parent_id?,
    worktree_branch?, sidebar}`. A group's `path` is its checkout's folder;
    `sidebar: true` marks a root's `sidebar-<root>` group. Top-level sidebar
    folders are not Projects; a Project filed in one is a `root`.
  - `create_worktree {project_id?, branch, name?, base_ref?}` resolves the
    project (or group, or worktree) to its root, adopts a registered or
    existing git worktree of that branch, else creates it in the folder
    `name` names (`worktrees::create_in_folder`, the slug of `name`), then
    registers one child project per (root, branch) through `app_state::edit`
    (`mcp-wt-<uuid>`, never `native-`; named `name`, as the Mac app names
    it; folder and sidebar name both default to the branch; `sort_order`
    after its last sibling). Returns `{path, project_id,
    branch, adopted, repo_path}`; `repo_path` is the root's checkout, which
    the Super Agent's worktree ledger records (below).
  - `list_worktrees` merges `git worktree list` of the root's checkout with
    its registered worktree projects: the main checkout carries the root's id
    (`main: true`), a registration git no longer knows is `missing: true`.
  - `create_worktree` and `list_worktrees` keep `require_worktree_access`
    (`mcp_worktree_access`, off by default; the Router passes it).
  - `list_schedules` and `list_schedule_runs` are open to every Session:
    they answer the `GET /mobile/schedules` and `GET /mobile/schedules/runs`
    bodies (`protocol/schedules-samples-v1.json`) from `app-state.json` and
    the per-task files on disk, so they work on any Host.
    `list_schedule_runs` returns the newest 10 Runs unless `limit` says
    otherwise. A Run Session's accepted `report` is also kept for its Run
    (`schedules::run_report`, #81): the Run shows it as `report`, and a
    `blocked` one as `needsAttention: true` unless the Run failed.
  - `create_schedule {name, project_id, preset, trigger, instructions?,
    enabled?, notify_when_done?}`, `edit_schedule {schedule_id, …any of
    those}` (pause and resume are `enabled`; `instructions=""` removes
    them), `delete_schedule {schedule_id}` and `run_schedule {schedule_id}`
    are the Super Agent's alone (`schedules_mcp/write.rs`): any other caller
    is refused before anything is sent, as are `unpeel schedules`' mutating
    verbs inside any other Session. Each is one request to the workspace
    worker's own write route (`POST /mobile/schedules[/edit|/delete|/run]`,
    `serve.md`) over its owner-only local socket (`local_host_call.rs`), so
    the Host checks the Trigger on its clock against its catalog, owns Run
    now's overlap rule and answers with the route's body; a refusal comes
    back as its message and `(code: …)`. `preset` resolves like `sessions
    create` (id, then label, in the task's Project, project-scoped first);
    `trigger` is the stored shape (`{"kind":"daily","time":"09:30"}`, or
    that object as JSON text). With no worker running a write is refused and
    nothing changes. The existing `spawned_by` rule keeps a task's Run
    Sessions out of `sessions close` even under Create & remove.
- `artifacts`: `add_to_gallery` for a caller-owned image artifact.

Session creation and closing remain user-only, except under the Create &
remove role and for the Super Agent (below). Stale start/delegate/close tool
calls are refused. Legacy mixed action names and per-tool names continue to
dispatch where safe for already-running/cached clients, but are absent from
the new schemas. `list_group` remains an organizational compatibility query;
`report_to_group` aliases `report` and uses the ordinary write policy. The
unreleased group-wide wait/summary spellings are intentionally not retained.

Write-approval prompts are Host-owned: the worker answers `POST
/mcp/approve-*` on its own hook port and mirrors approvals to the app
through the `approval.present` platform callback (answers return over the
Host approval verb). The native `MCPBridge.swift` compatibility adapter was
retired 2026-09-03, and with it the `list-presets`, `create-worktree` and
`list-worktrees` routes (the worker never served them; the `workspace`
actions read app-state directly, above). The route contract below is the
worker's.

- Bridge: `crates/unpeel-serve` hook port, authenticated `POST /mcp/*`
  calls: `approve-write`, `approve-browser`
  (`approve-app-open` is still served for MCP binaries older than
  2026-09-06, but current App opens need no approval and never call it);
  `start-session` remains reserved for user/controller launches. Approval routes reply asynchronously (150s bridge ceiling, ~130s
  MCP client timeout). The MCP host tries launch-time `UNPEEL_APP_PORT`, then
  `~/.unpeel/app-ports` newest-first. App-less `unpeel serve` Hosts serve the
  same routes and the same shared approval queue.
- Auth: unlike hook routes, `/mcp/*` requires the `x-unpeel-auth` header matching `<UNPEEL_HOME>/mcp/auth-token` (0600; the workspace worker mints it at start and the MCP host mints it on first use via `mcp_auth::ensure_auth_token`, so a fresh workspace home never reaches its first approval prompt without one — that gap broke every agent write in a new workspace until 2026-09-16) — the endpoints can launch arbitrary commands, and localhost is reachable by browser CSRF.
- Worktree creation uses the desktop's folder layout (`worktrees.rs`, `~/.unpeel/worktrees/<repo-slug>-<hash>/<branch-slug>`). The MCP host defaults `project_id` to the calling session's project.

> **Security scope (2026-08-14): these are cooperative controls, not
> same-UID isolation.** Hosted commands run as the user's account and are not
> sandboxed by Unpeel. The `0700` Unpeel home and `0600` MCP token protect
> against other local users and browser-origin CSRF; they do not stop code in
> a hosted session from reading same-user state or discovering local sockets.
> Consequently the Ask/Deny rules below govern agents that use
> the supported MCP surface, but must never be described as a security boundary
> against malicious shell code. A hard boundary requires a Host-owned broker
> plus OS-enforced session confinement.

Cooperative access policy — **open reads, approval-controlled writes to every
other session** (reworked 2026-08-31):

- **Reads are open across ALL sessions.** Any enabled caller can `list_sessions`/`inspect_session`/read any session in any project (`McpSecurity::permits_manifest` = caller known and not internally `Off`). The old project/worktree reach machinery was removed from the gate; `McpScope`/`mcp_default_access` survive only as decode-tolerant legacy fields (an explicit per-session `Off` override in `mcp_orchestrators` still disables a session's tools entirely).
- **Sidebar groups are organizational only.** Project roots, plain groups, and worktrees remain useful filing and layout context, but moving a session never grants or revokes authority.
- **Every write to another session goes through the app-wide write policy** stored under the compatibility key `AppState.mcp_nonchild_write_access` (`ask` default / `deny` / `allow`, `McpNonChildWriteAccess` in `state.rs`), re-read per call so changes apply live. Under `ask`, `require_session(_, Write)` first checks the persisted pair map `AppState.mcp_write_approvals` (`caller id → [target ids]`, directional); on a miss it POSTs `/mcp/approve-write` to the app with a 130s read timeout (`request_write_approval`) and the user answers the approval prompt — Allow persists the pair, Deny fails the tool call with a clear "don't retry" message. Prompts are FIFO and identical pairs coalesce; the exited-target check runs before the prompt so a dead session never asks.
- **Agent access roles (per session, sidebar right-click ▸ Agent access).** Stored as `AppState.mcp_orchestrators[<session id>] = { role, reach }` and re-read per call, so a change reaches a running agent without a restart. Roles: `read` (default, no entry), `send` (**Write** — writes to any other session skip the Ask prompt; Never allow still denies), `manage` (**Create & remove** — Write plus `sessions create` and `sessions close`). Retired lineage spellings (`write`, `orchestrator`, bare-string grants) decode as inert Read. The menu shows only for agent sessions on this Mac's own Host (the grant lives in that Host's app-state); remote Hosts have no grant verb yet.
- **Session lifecycle is user-owned by default.** Without `manage`, `create`/`close` (and the stale `start_session`/`delegate_*` names) refuse with a pointer to the role. `create` launches a preset (id or label, project-scoped first), a raw `command`, or a plain shell, in the caller's cwd and project unless given, and stamps `spawned_by = <caller id>`; `close` runs `session_ops::remove_session` only on a session whose `spawned_by` is the caller (App companions from `apps.open` qualify) and never the caller itself. Both actions are always advertised because providers cache `tools/list`; the gate is at call time. A caller replaced by Resume gets a new id, so it loses removal rights over helpers it created before. The Super Agent is the exception: it holds Create & remove by its mark, and its `close`/`stop` authority is the Worker marker alone (below), which follows a Router Resume.
- **Legacy lineage is decode-only.** `parent_session_id`, `session_parents`, and the remote protocol's `parentSessionID` remain tolerated for older manifests/controllers, but current hosts never write or enforce them and current clients render sessions flat.
- **Unified approval prompts, answerable from controllers:**
  `/mcp/approve-write|browser|computer|app-open` share one pending queue
  (`PendingMcpApproval` in `MCPApprovalCenter.swift`; route handlers keep fast
  paths). Desktop and phone both show an in-pane overlay on the Session the
  grant is about (write: the destination, otherwise the caller) plus that
  Session's attention badge — never a floating window and never
  `NSAlert.runModal()`, which stalls queued main-actor work including mobile
  bootstrap. Pending prompts ride every Controller bootstrap as
  `pendingApprovals` — the HTTP `/mobile` route sets it in the route context,
  and the framed gateway route (`host.sock`, the path a window scoped to a
  sibling local workspace uses) stamps it onto the disk-built body
  (`ApprovalHub::decorate_bootstrap`; before 0.7.3 that path could answer
  prompts but was never told about them, so a scoped workspace showed no
  prompt anywhere). Answers go through `POST /mobile/approvals/answer` /
  the live `approval.answer` gateway route; first answer wins. A prompt
  nobody answers within the Host's 125 s window resolves as `timedOut: true`
  (not a decline): the MCP host tells the agent nothing was sent and to ask
  the user, instead of "the user declined". `mcp_app_open_approvals`
  (caller Session → App ids) is a pre-2026-09-06 grant map: still decoded,
  pruned/carried with caller replacement like other Session-keyed grants, but
  no current open consults it.
- **Approval lifecycle:** pairs live in `~/.unpeel/app-state.json`; an in-place Resume Agent after the managed runtime returns to its shell keeps the same Session id and therefore needs no migration. Replacement Resume/handoff paths snapshot the map before `pruneNativeState` and re-add every pair under the new Session id (both directions), using the same read-before-prune discipline as the carried access grant.
- **No launch injection (0.7):** a launch runs the preset command as typed; `SessionHostLaunch.mcp_enabled` only records the saved Sessions-domain grant in the manifest. The MCP server reaches an agent solely through its installed integration (the shim registered in the provider's own global config) — never through a flag, an environment gate, or a per-session config file. The manifest still records `mcp_enabled` and `mcp_client_registered` as distinct facts; the latter now means "the provider's config points at the shim".
- **Native UI:** Settings ▸ Agent access (Sessions section) explains open reads and per-target
  write approval, offers the app-wide write policy and gallery toggle, and lists both approved
  Session-write pairs and approved App launches with per-entry Revoke. Changes
  apply live; nothing here drives a restart banner.
- **A running Session with no published activity (fork-only).** While a Host
  worker holds this workspace's serve lease (`supervision::host_worker_running`,
  a shared-lock probe of `serve.lock`), a running Session with no
  `activity-state.json` entry reads activity `unknown`, not `idle`
  (`mcp_host::activity_status_for_manifest` → `supervision::running_status_without_activity`),
  and an `agents wait` / `wait_for_status` for `idle` keeps waiting on
  `unknown`. Without a Host worker it reads `idle`, as upstream: nothing would
  ever publish an entry, so a wait would never end.

- **Super Agent Workers (fork-only, `supervision_mcp/workers.rs`, `workers/control.rs`, `workers/cards.rs`).** Only the Session marked in app-state `super_agent` (the Router) gets these; a plain Create & remove caller keeps the behavior above and is refused `role`/`task`/`text`/`worktree`.
  - `create` from the Router starts a Worker: `role` and `task` are plain labels (control characters stripped, trimmed, at most 120 characters, `"app-panel"` refused; never the Agent access role); `text` is the first task, queued as a waking `task` item in the Worker's own Inbox (sender: the Router) and pasted the first time the Worker is idle with no select menu up (a startup picker such as Codex's update menu holds it as `attention`; an agent that exits before delivery leaves it queued, held `no_agent_authority`, never pasted into the shell, #55; a menu a person answers by typing counts as typing, and with the Worker's empty prompt not known yet the PTY core decides, #69: the menu took the keys, so the task is pasted at the composer, while a draft typed there holds it `draft` until the user types again or the Router writes to the Worker; on an older core it stays held `draft` until a clean turn, which the user's next prompt or a Router write starts); `worktree=<branch>` (+ `base_ref`, not with `cwd`) creates or adopts the worktree through `workspace_tools::create_and_register` and launches in its child project (`mcp-wt-<uuid>`, `worktree_path`/`worktree_branch` set). With neither `preset` nor `command` the Worker runs the Router's own agent (its observed runtime, else the catalog match on its command): the first enabled preset of the target Project (a group or worktree uses its root's) whose command runs that runtime, else the runtime's plain command (its first command alias), never the Router's own launch line. A root's Sidebar group (`sidebar-<root>`) is refused. Limits, counted from the markers alone: `supervisor_max_children` running Workers (default 8) and `supervisor_max_spawns_per_minute` `sessions create` starts (default 6; Hand-overs don't count). After the spawn the Worker gets `app-sessions/<id>/supervision.json` `{router_id, since, origin: "created"}`; the result adds `worker`, `task_item_id`, `worktree` and a Router `note` (a failed marker or task write becomes `warning`).
  - `stop {session_id}` (Router only, its own Workers by marker): stamps router-touch, moves the Worker's pending Inbox items to the Router as ride-along items `about` the Worker (`session_inbox::move_pending`), then `session_ops::stop_session`. The row stays, greyed and restartable; the marker stays, so it is still a Worker for the keep limit. Returns `{session_id, stopped, was_running, returned_items}`.
  - `close` from the Router is decided by `supervision_mcp::route_close`: its Workers by marker (whoever spawned them; pending items move back first), and App panels it opened (`role == "app-panel"` and `spawned_by` = the Router). A Worker the user restarted lost its marker and is refused even though `spawned_by` still names the Router.
  - `current`: every caller gets `inbox: {pending}` (undelivered items in its own Inbox). The Router also gets `super_agent: true` and `workers[]` cards `{id, label, project_id, group_id, activity_status, last_report_status, preview}` (oldest first, stopped Workers included). `last_report_status` and `preview` come from the Router's whole Inbox history (`Store::history`): the Worker's last `report`/`handover`/`message`, or a Host `lifecycle` item `about` the Worker with status `finished` (its reply in the body), cut to 160 characters. A Worker gets `router_id`.
  - The after-compaction rule (`supervision_mcp::extend_instructions`): the unified server's `initialize` `instructions` end with "If you are this workspace's Super Agent, your instructions are skills read unpeel/router. After a compaction, call sessions current before starting anything …". Claude Code keeps server instructions in its system prompt, which a compaction does not summarize; the Router skill and its instructions item are tool results that a summary can drop. Every Session receives the rule, so it says whom it is for. Only `claude-code` declares `super_agent`, so providers that never surface server instructions (Codex, as the App routing note says) don't matter here. Nothing is queued on a compaction: `SessionStart` with `source: "compact"` stays a `HookSeen`.
  - Router waits: `agents wait`, `sessions wait_for_text` and `wait_for_status` cap `timeout_ms` at 5 000 for the Router (`cap_wait_timeout`); a capped wait that fails says why (`explain_wait`, wrapped around `run_tool`).
  - Worker → its Router (while a Host worker runs): `report` and `send_text` skip the write gate and queue in the Router's Inbox (`send_text` as a waking `message`: first line as its summary, `submit` ignored); the app-wide Deny is re-read when the supervisor drains it. A handed-over Worker's first report since its Hand-over is queued as kind `handover` (Wake). A Worker's `send_keys` into its Router follows the ordinary policy. Without a Host worker both keep upstream's paste path.
  - A Scheduled Task's Run → the Router (while a Host worker runs, ADR 0010): `report` alone skips the write gate and queues in the Router's Inbox, by the same wake rules. A Run Session is one whose `spawned_by` is `schedule:` plus a non-empty task id (`schedules::run_sessions::schedule_id`), whether or not the task still exists, and after a Resume too. Its `send_text` and `send_keys` to the Router, its writes to any other Session, and a Run Session made the Router reporting to itself follow the ordinary policy; a Run is never a Worker (no marker, card or `handover`).
  - The Super Agent's address (#82, `supervision_mcp::resolve_report_target`): `report` to `session_id: "super_agent"` (MCP, `unpeel mcp sessions report`, or `unpeel report <summary> --to super_agent`) goes to the Session marked in app-state `super_agent` when the report is sent, so a Run brief never names the Super Agent by label or by an id that the next Resume replaces. It is resolved before anything else, so the report then takes exactly the path a report by that id takes: the same write gate, the Worker and Run exceptions above, the Inbox or upstream's paste; the result's `session_id` is the resolved id. With no Super Agent marked the call fails at once with "No Super Agent in this workspace, so nothing was sent …", never an approval prompt. `sessions list` marks the Super Agent's row `super_agent: true` (left out on every other row; `supervision_mcp::mark_router_rows`, the mark read once per call). `unpeel report` without `--to` (or a `session_id` in `--json`) prints its usage.
  - router-touch: every write that passes `require_session(_, Write)` from the Router into one of its Workers, and every Router stop/close, stamps `session-inboxes/<worker>/router-touch` (unix ms; `session_inbox::router_touched_at`) for the supervisor to tell self-caused edges apart.
  - Switching the Super Agent (`session.super_agent.set` on another Session) hands the old Router's pending Inbox items to the new one as they were (`Store::hand_over_pending`), dropping the old Router's own undelivered instructions.
- **Becoming the Router: three Host verbs (fork-only, `supervision/controller.rs`).** The Mac menu items Make Super Agent / Stop Being Super Agent / Hand to Super Agent call `session.super_agent.set`, `.clear` and `.hand_over` (`POST /mobile/super-agent/{set,clear,hand-over}`, body `{sessionID}`, answer `{ok, changed}`; `changed: false` means already in effect). They are advertised on the native and headless lists in `protocol/host-capabilities-v1.json`, replay-protected, and pinned by the missing- and unknown-session conformance cases. Every refusal is decided before anything is written: 400 invalid id, 404 unknown session, 409 not running / no Super Agent / is the Super Agent / Worker limit (Hand-over), 422 the runtime cannot be the Super Agent / not an agent; only a 500 may follow a partial write.
  - `set`: a running Session whose runtime declares the `super_agent` capability in its package (`runtimes/claude-code/runtime.toml` today; the observed foreground runtime wins; with none observed, the catalog match on the command head; the Mac menu applies the same rule). One Router per workspace: app-state `super_agent: {session_id, since}`. The new Router stops being anyone's Worker, takes the previous Router's Workers (their markers' `router_id`) and pending items, and gets a waking `task` item ("You are now the Super Agent. Read your instructions with skills read unpeel/router, then call sessions current.") and, when Workers moved, a `handover` item listing what it took over. The old Router becomes an ordinary agent.
  - `clear`: a no-op for any Session but the Router. The mark is nulled (never removed: app-state refuses a write that drops a top-level key), every Worker marker is removed (running and stopped Workers become the user's ordinary Sessions; a later Router does not take them back), and the Router's undelivered instructions are dropped. Removing the Router's Session clears the mark and frees its Workers the same way (`supervision::on_session_replaced(old, None)`, which also deletes its Inbox).
  - `hand_over`: a running catalog agent that is not the Router. It gets a marker with `origin: "handed_over"` and a waking `task` item asking it to summarise its conversation into one `sessions report` to the Router (queued as kind `handover`). A Hand-over is the user's free slot: it is accepted at `supervisor_max_children` running Workers (one over the limit) and refused with 409 past that.
  - Resume (a replacement id) moves the mark, rewrites every Worker marker and renames the Inbox directory to the new id (`supervision::on_session_replaced`, delegated from `session_ops::rewrite_shared_session_references`), then queues the instructions again. A same-id Reload changes nothing. A user restart of a Worker tears its session dir down with the marker, so it is the user's.
  - Being the Router implies Create & remove (`supervision::grant_override`; its writes to any Session skip the Ask prompt, app-wide Deny still applies), `mcp_worktree_access`, and the Scheduled Task writes (`workspace create_schedule` … `run_schedule`, above; `supervision::is_router`). Bootstrap session summaries carry `superAgent: bool` and, from a Worker marker, `superAgentRouterID` (both builders: `controller_host.rs` and `unpeel-serve` `mobile_snapshot`); older Controllers ignore them.
- **The Inbox (fork-only, `session_inbox.rs`, `supervision_mcp/inbox.rs`, `unpeel-serve/src/supervisor/inbox_*.rs`).** While a Host worker runs, `sessions report` to any Session queues into the target's Inbox instead of typing: `<UNPEEL_HOME>/session-inboxes/<id>/` (`pending/`, `delivered/`, `inflight.json`, `hold.json`, `router-touch`; locks under `.locks/`), outside the session dir so Resume cannot destroy it. The result says `{queued, item_id, pending, delivery}`, `delivery` being `when_idle` or `held:<reason>`; status `done`/`blocked` or `questions` wake the target, `update`/`progress` ride along with the next wake batch, and `submit` is ignored. Ride-along items whose oldest has waited 15 minutes start a delivery as if they were a wake item (#83), counted from the stored queue time so a Host restart does not start the clock over; `UNPEEL_INBOX_RIDE_ALONG_PROMOTE_MS` (tests only, with `UNPEEL_TEST`) shortens the wait. A report's `delivery` reads the published hold (#85): with no wake item pending it is `held:ride_along` while the hold reads `ride_along` or one the drain publishes before it asks about ride-along items (`quiet`, `snapshot`, `in_flight`, `unconfirmed`, or none yet), and otherwise what a wake item would get (`when_idle`, or `held:<reason>` such as `held:exited`). Without a Host worker `report` takes the same statuses (#86) and pastes at once (`queued: false`, `delivery: immediate_legacy`), under `send_text`'s draft guard (#66): a refusal fails the call at once, with nothing written. Caps: 200 pending items or 2 MiB ("inbox full"); delivered history 200 items / 24 h; an Inbox whose session has had no manifest for 10 minutes is collected.
  - Delivery (`inbox_rules.rs`, a pure truth table): only a wake item, or ride-along items promoted by age, starts a paste, and the paste carries everything pending, oldest first, as one bracketed paste — `[unpeel inbox for id:<target> · batch <id> · N items · channel: terminal]` … `[end of inbox batch <id>]`, each item headed `[message|notice from id:<sender>, channel: terminal, via: inbox, kind: …]` (only `id:host` notices come from Unpeel; sender text that imitates a header is quoted with `│`; an item over 1 500 characters is cut with a pointer to `sessions inbox item_id=…`; a batch is at most 12 000). It needs a running, idle target that an agent owns: idle by its program's own report, or by hooks or a `done`/`error` report while a runtime is in the foreground, is confident; the screen tier, or nothing with a runtime in front, is a best guess (`supervisor_inbox_low_confidence`, default on); with no runtime in front it holds `no_agent_authority`. It also needs no select menu, mode 2004 set, no app-wide Deny, 3 s of screen quiet (10 s for a best guess), 2 s since the newest item (at most 30 s after the oldest), no draft on the input line, and at most `supervisor_max_deliveries_per_hour` (60). The draft guard (#38) reads the manifest's `last_input_at`: when a person last typed, stamped by the PTY core for `Write`s with no `origin` (the attach stream, the Mac app, the phone) that can change an input line — not mouse reports, focus in/out or terminal replies, and never `origin: "program"` writes (the Inbox paste, MCP `send_text`/`send_keys`, initial prompts, screenshot requests). A turn begins at the target's `UserPromptSubmit` or the rescan that sees it turn Busy or Starting from Idle; a menu is part of the turn around it, never its start (a Session the drain has not watched yet counts from its first rescan). With no typing since the turn began, the input line is the agent's own prompt: the drain takes it as the baseline and remembers it as the target's known-empty prompt. After typing, it pastes only once input has been quiet 3 s and the line equals the known-empty prompt; with none known yet the PTY core decides (#69, ADR 0011): on a core with `draft_guard` the paste also carries `unless_draft`, and a `draft` refusal holds `draft` until the user types again or, for a Worker, its Router writes to it (`send_text` or `send_keys` stamps `router-touch`, and the core is asked once more); an older core holds `draft` until a clean turn. Suggested input is left out of both lines, so a proposed reply is never a draft. A target whose PTY core predates `last_input_at` keeps the older guard (a baseline at the first quiet idle moment, held until the next Busy → Idle cycle once the line changes) until it is resumed on a newer build: a core of another build takes no new launches, so the resumed Session runs on the new binary. The paste's writes carry `unless_typed_since`, so the PTY core refuses them once a person types: before the paste nothing is written and the batch is released; after it, the paste stays on the line unsubmitted and confirms like any other. Pasting runs off the tick thread, one paste in flight per target. A paste counts as delivered when the target's `UserPromptSubmit` hook or 7501 Busy edge follows it; otherwise it is pasted again after 30 s marked `(redelivery)` (same batch id), and after its third paste it counts as delivered. A best-guess paste counts at once. A draft that holds items for 120 s alerts the user.
  - `sessions inbox` is the target's own pull mode, refused for anyone else's Inbox: no parameters lists pending headers, the last 20 delivered and `hold` (the current hold reason, e.g. `busy`, `no_agent_authority`, `ride_along`, `quiet`, `draft`, `unconfirmed`, `policy_deny`); `item_id` reads one item in full; `ack_through` marks every pending item up to that one consumed, so it is never pasted. A plain shell (`cat`) is held `no_agent_authority` and drains only by pulling.
- **Worker notices and the watchdog (fork-only, `unpeel-serve/src/supervisor/worker_alerts.rs`, `notices.rs`, `watchdog.rs`).** While the Router runs, its Workers' lifecycle edges become Host notices `about` the Worker in the Router's Inbox instead of user notifications (the user side is in `docs/agents/clients/session-activity.md`): NeedsInput → wake `needs_input`; Finished → `lifecycle` `finished` with the Worker's reply as the body (the shape the Worker cards read), and nothing when the Worker reported a result that turn (any report but `progress`, a mid-turn note; `reported_since`, #86). Its wording and priority follow who the turn answers to, read through to the turn's end. A Host paste or Router write from 30 s before the turn (the drain's own wait for a paste to start one) or later, or a start the supervisor did not watch, is a plain wake `finished`. Otherwise the manifest's `last_input_at` from 10 s before the turn or later is a wake "after the user talked to it directly". Otherwise it is a timer, a background task, or a prompt from outside the terminal, which rides along, except the first such turn after a plain one with no report since, which wakes with the plain wording because it may be that task's answer. `last_input_at` records user-origin input that crosses the PTY, so a prompt from a program's own remote channel (Claude Code's Remote Control) leaves it stale, and that turn counts as unprompted too. A full Inbox drops ride-along Host notices before it refuses an item; Exited → a ride-along `exited`, or a waking watchdog `exited_unexpectedly` when it exited busy, waiting, or with a failing code; Started only with `supervisor_notify_started`. A Worker only the screen tier (or nothing) speaks for never produces a Finished edge, so the end of its turn (Busy → Idle) is a `finished` notice marked "screen-detected" with no reply, once per turn, waking or riding along by the same rule. The watchdog reports, once per episode: `stalled` (Busy with no progress — hook, program report, Busy edge or durable stamp — for `supervisor_stall_minutes`, 20), `blocked` (waiting on a prompt for `supervisor_blocked_minutes`, 10), `went_quiet` (a hook or program turn ended without finishing), `long_turn` (`supervisor_max_turn_minutes`, off by default). Edges the Router caused itself (router-touch within 5 s, 15 s for an exit, and no Busy since) produce no notice. Every clock is floored at the supervisor's start; on a Host start the Router is caught up on exits and finishes since the previous supervisor's last heartbeat (`<UNPEEL_HOME>/supervision/heartbeat`), with the live notices' dedupe keys. `UNPEEL_SUPERVISOR_SECONDS=1` (tests only, with `UNPEEL_TEST`) reads every minute setting as seconds.
- **Worker compaction (fork-only, `unpeel-serve/src/supervisor/compaction.rs`, #64, ADR 0012).** While the Router runs, the Host compacts a Worker whose context is `supervisor_compact_percent` (40) full when one of its turns ends; Scheduled Runs, the Router and the user's own Sessions never. The figure is the agent's own, read from the Worker's transcript by the runtime adapter's `context_usage` reader (`transcripts::read_context`; a transcript that is one JSON document, Codewhale's, is read whole), over the model's window from the runtime package's `context.windows` (longest model-id prefix), with the package's `context.baseline_tokens` (default 0) left out of both. Claude Code: what its status line shows, the last main-chain reply's input, cache writes and cache reads, or a later `compact_boundary`'s `postTokens`. Codex (#68): what its footer shows, the newest `token_count` event's `last_token_usage.total_tokens` over the usable window (95% of the model's), less Codex's 12,000-token baseline; a `compacted` line newer than every `token_count` reads as unknown; a `model_context_window` set in Codex's config is not followed. Codewhale (#68): its local estimate of the saved session (a quarter of each block's bytes, the system prompt's conservative estimate, 12 per message plus 48); its footer shows the larger of that and the last billed prompt, which no file keeps, so the figure reads at or under the footer. A model with no window there is never compacted; the Router hears that once per model while it runs, as a ride-along `not_compacted` notice. On the Worker's Finished edge the Host reads the transcript once. At or over the threshold it types the package's `context.compact_command` (`/compact`), then Enter 100 ms later, as `origin: "program"` writes under the PTY core's typing and draft guards (ADR 0011), off the tick thread, within 5 minutes of the turn's end while the prompt cache is warm, and only while the Worker is Idle with no select menu, its PTY core has `draft_guard`, no Inbox items wait for it, neither the Router nor the drain wrote to it in the last 5 s, and "Writing to other sessions" is not Deny. A refused write tries again every 2 s while the cache is warm, and every step until then re-checks every precondition: the first one that fails, a Router write, drain paste or program turn since the turn ended, or Deny gives that turn up for good. A miss waits for the next turn end, never a cold cache. When the user types between the command and Enter, the command stays on their line unsubmitted, like a drain paste, and that turn is not tried again. Once the compaction goes busy, the Router gets a ride-along `compacted` notice ("… was at 41% of its context (412K tokens) when its turn ended, so the Host compacted it …") and the Worker is not compacted again until a reading is under the threshold; a compaction that never starts within 30 s tells nobody. The compaction is a turn of its own (7501 working, then done with the previous reply's message; no prompt-submit or Stop hook), and it produces no Finished or `went_quiet` notice and no user notification, unless the Router, the user or the drain wrote to the Worker after the command: then it may also answer that, so it is reported as usual. Its claim on that turn outlives a Router restart, but a finish while no Router runs reaches the user as any Worker's does. Codex compacts the same way (7501 working, then done; no Stop hook). A Codewhale compaction reports no busy (no `session_busy` hook; its `turn_end` is `model_backed: false`, which the hook reporter settles as Idle), so the Host never sees it start: the Router gets no `compacted` notice, nothing else is raised, and the Worker is not disarmed, so a turn that still reads over the threshold afterwards is compacted again. The Host's paste recipe leaves a Codewhale Worker on its message pager, which takes the command as a search, until #78 is fixed.
- **Groups, worktrees and the keep limit (fork-only, `supervision_groups.rs`, `supervision_worktrees.rs`).** `workspace create_group {project_id, name}` adds a sidebar group (`sa-<uuid>`) at the top of the root Project a group or worktree id resolves to; a Worker started with that `project_id` runs in the root's folder. `rename_group` and `remove_group` (empty groups only: no Session, stopped ones included, and no child groups) act only on groups the Router created (`sa-` ids); every other group (the Mac app's `native-` groups, migrated `legacy-pinned-` groups, other frontends' groups, a root's Sidebar group), Projects and worktrees are refused. `move_session {session_id, project_id}` files one of the Router's own Workers under its root (or worktree) or a group directly under it, never the Sidebar group; only the sidebar changes. A Worker's worktree goes on the ledger `<UNPEEL_HOME>/supervision/worktrees.json`; when retention removes that Worker, the worktree is removed with it only if its branch is merged (`git merge-base --is-ancestor`) and it has no uncommitted changes. Past `sidebar_stopped_limit`, stopped Workers are removed before any of the user's stopped Sessions, and a stopped Router is never removed and takes no keep slot (`supervisor::stopped_in_keep_window`, `SessionRow.is_router`). Auto-stop never stops the Router, a running Router's running Workers, or a Session with undelivered Inbox items.
- **Super Agent settings** (app-state, re-read every sweep, `supervision/config.rs`; an out-of-range value falls back to its default): `supervisor_max_children` (8, 1–32), `supervisor_max_spawns_per_minute` (6), `supervisor_escalate_minutes` (5; 0, 1, 2, 5, 10, 15, 30, 60), `supervisor_stall_minutes` (20), `supervisor_blocked_minutes` (10), `supervisor_max_turn_minutes` (0 = off), `supervisor_max_deliveries_per_hour` (60), `supervisor_notify_started` (false), `supervisor_inbox_low_confidence` (true), `supervisor_compact_percent` (40; 0, 25, 30, 40, 50, 60, 70; 0 = off; nothing lower, since the startup context comes back after a compaction). `unpeel settings get/set/list` script every one of them with exactly these value sets (`supervision::SupervisorSetting`, shared with the supervisor; `settings_cli.rs` whitelists them, so `settings.workspace.set` is unchanged). The Router's instructions are the built-in `unpeel/router` skill (`crates/unpeel-core/src/skills/router.md`).

> **Removed (2026-06-22):** the per-project MCP *block* feature (`mcp_blocked_projects`, `Project.mcp_blocked`, the Settings "Block individual projects" section, host/bridge block gates) is gone. The native `AppStateFile`/`Project` decoders still tolerate the old `mcp_blocked*` keys for backward-compatible reads, but nothing writes or enforces them.

Registration per provider (all through the explicitly installed integration,
`docs/agents/providers.md` has the per-CLI file paths):

- The shim (`integrations::install::write_mcp_shim`) is rewritten by every
  integration install and by the worker's post-upgrade refresh, so it always
  execs the current `unpeel-host`; inside a hosted shell it prefers the
  exported `UNPEEL_HOST_BIN`.
- Launchers that strip their MCP children's environment (codex, cursor-agent,
  muse) get identity from `self_session_id`'s nearest verified ancestor (for
  Codex only under `--no-daemon`: its shared daemon starts MCP servers in a
  POSIX session of its own, where the gate serves no tools (ADR 0014); see
  the Codex notes in `providers.md`); Kiro v3 passes only a declared env
  block, so its entry forwards the generic `UNPEEL_*` variables; fx and
  Claude inherit the hosted environment.
- Per-Session grants never appear in any config file: the gate reads
  `sessions_mcp_enabled()`/`browser_mcp_enabled()` from the calling Session's
  manifest per call. The older `UNPEEL_*_MCP_ENABLED` environment grants and
  the runtime-local aliases remain readable for configurations older builds
  wrote around a launch.

## The `apps` and root `skills` domains (2026-08-24)

`apps_mcp.rs` is the first landed piece of the Unpeel Apps agent contract
(the private "unpeel-apps" design record "Agent access" is authoritative). An installed
Unpeel App is an entry in `protocol/app-registry.json` whose declared
CLI resolves through the Host's search path (including its managed App bin
directory). This catalog plus search-path check is the entire
current discovery contract; **no app ever runs its own MCP server**. The `apps`
domain advertises `list`, `catalog`, `describe`, `search`, `context`, and
`open`. `catalog` includes missing official Apps, their declared file
extensions/resource kinds/defaults, and the exact user-facing installation
command. Agents cannot install software through MCP.
`context` returns agent-safe attached/project relationships plus the same
caller-relative direct-neighbor snapshot as `sessions.current`. A neighboring
App includes its ordinary readable companion Session id so “check Design on
the left” resolves to an explicit target. Each neighbor entry is a one-call
identity card (2026-08-26): kind (terminal/agent/unpeel_app), label, `cwd`,
state, activity, and for agent panes the catalog `runtime_id` plus resolved
`runtime_name`; an App entry inlines the central catalog description. Future
package tool summaries and skill references remain reserved for the declared
tool-execution slice; the current catalog publishes neither. The snapshot
comes only from this Host's durable `windows["main"]["local"]` Controller tree and exposes no
pane ids, ratios, pixel geometry, focus, zoom, or transient visibility.
Because some provider CLIs (Codex) never surface MCP *server* instructions to
the model, the routing cues that map user language onto this snapshot —
spatial words ("left", "next to me") and selection words ("the selected …",
"what I have open", for any App: a design, document, note) — must live in the
per-tool descriptions themselves (`sessions`/`apps`, 2026-08-26). Keep new
routing guidance there, not only in server instructions. A pane
currently branded as an App also carries that App's self-published **live
context**: the App writes an `app-context.json` marker beside
`app-title.json` in its session dir (`{"app": id, "context": {…app-defined…},
"updated_at": ms}`, a JSON object ≤ 16 KB), and pane-context queries read it
fresh per call and surface it verbatim as the neighbor entry's `app_context`
(`session_host::read_app_context_marker`). It is never folded into Host
state (selection-frequency updates cost no manifest churn or state-bus
pings), never exposed for a pane that is not currently App-branded — a
marker left behind by an exited App must not speak for the shell that
remains — and always framed as app-authored data, never instructions; each
App's public documentation defines its own `context` schema (the Markdown
App: current file, cursor line, selection lines). `open`
resolves only an installed catalog entry, derives caller/project/cwd Host-side,
then — with no approval prompt: installing the App was the user's consent,
and the App runs with the authority the agent already has (decided
2026-09-06) — creates or reuses the project/resource App instance,
starts its companion Session when it is missing or exited, and binds the
caller's semantic panel. This is a bounded exception to user-only
Session creation (decided 2026-09-06: agents may open files in panes); the
others are the Create & remove role and the Super Agent's Workers. MCP
never installs an App and never removes a companion; a missing App returns
exact guidance to ask the user to install it. A caller-scoped `request_id` deduplicates retries;
`reveal:false` attaches without advancing the reveal revision. The root `skills` domain provides
`list`, `search`, and `get` (fork-only: `read` is an alias of `get`, and the
built-in `unpeel/router` skill, compiled into the Host and never
overridable, is the Super Agent's instructions); future App package guidance uses namespaced ids
there rather than adding an Apps action. Every App action rechecks the Host's
resolved PATH, so a mid-session install is visible without a restart.

`apps.open` and the Controller's user-initiated `apps.open` Host effect share
the typed resolver, presentation model, and companion lifecycle in
`app_open::open_app`; the agent path is the same effect with the same
validation (App not installed, unsupported media type, relative path all fail
before any state is written). An explicit `resource` plus `media_type`
defaults to `resource_kind:file`; otherwise callers use a declared typed kind
such as `folder` or `git.working-tree`. Future kinds such as
`github.pull-request` use the same wire. The Host passes any resource as one
shell-safe argument to the resolved App executable. Cmd-click is a direct user
action and may additionally install a missing App first.

The install boundary is enforced on the supported MCP adapter, not as an
OS sandbox around arbitrary commands. A hosted process runs as the user's
account and can invoke the ordinary `unpeel` CLI; noninteractive
`unpeel apps install` requires an explicit `--yes`, but the cooperative-policy
contract still depends on agents using the MCP surface for App actions.

Presentation state is the versioned `app_presentations` envelope in
`app-state.json`: App instances are project/resource identities; bindings pair
one caller with a view/`panel` target and monotonic reveal revision. Agent MCP
open receipts never expose the backing companion Session or claim placement;
a later `sessions.current` or `apps.context` snapshot may identify it only
when it is a direct neighbor in the local durable Controller tree. Native
Controllers consume the trusted binding and project a first reveal as their
own trailing/right split. Pane ids, ratios, focus, visibility, and durable
membership remain in Controller-owned pane state. Each Controller persists a
local handled/dismissed revision, so detaching stays detached until a later
intentional `open` increments the Host revision. The validated semantic
envelope is also published as bootstrap `appPresentations`, so scoped and
remote Controllers use the same projection; do not infer it from Session role,
commands, or pane files.

Advertising: the `apps` and `skills` tools appear whenever any other domain is advertised
(`McpDomainMask.apps`; the `__mcp_gate__` unified entry grants it when any
domain grant is present) and its tool description embeds the live installed
App/skill ids, computed at server launch. Declared RoomStore tool *execution* is intentionally
absent until RoomFS/the Host worker exist — `describe` says so and points
agents at the app's standalone command and root skill reference.

Reference convention: an app can hand agents a token like
`[mcp:unpeel.app.markdown README.md LOC:12:32]`; the tool description and
server instructions teach agents to resolve it by fetching that app's
skill through `skills.get`. "Send to agent" in the shipped Apps is
`unpeel-app-kit`'s handoff: it types the reference into the neighboring
agent through `unpeel-host __mcp__` sessions `send_keys` (and therefore the
same policy as any other inter-session write), resolving the Host through
`UNPEEL_HOST_BIN`. (The earlier Unpeel Design App and its `.presence/`
bridge were removed from the catalog on 2026-09-07; nothing in core refers
to them.)

## Dual-era MCP transport (Cloudflare/MCP v2 review, 2026-08-23)

The local stdio server accepts both the shipped initialize-era protocol and
the 2026-07-28 discovery protocol described in Cloudflare's MCP v2 review:

- legacy `initialize`, `tools/list`, and `tools/call` response shapes remain
  unchanged for existing CLIs;
- modern clients start with `server/discover` and send
  `params._meta["io.modelcontextprotocol/protocolVersion"]` plus the client
  capabilities object on every request;
- unsupported versions fail with `-32022`; every modern success includes
  `resultType:"complete"` and server-info metadata;
- discovery/tool-list caching is `ttlMs:0`, `cacheScope:"private"`, because
  authorization, installed Apps, and skills are caller/Host-specific.

Do **not** advertise `io.modelcontextprotocol/ui`: Unpeel Apps are standalone
Host Apps, not MCP Apps iframe resources. Streamable-HTTP method headers and
OAuth are irrelevant to this local stdio transport. In-flight cancellation is
implemented (2026-08-23) as a reader/worker split, deliberately **not** full
concurrent dispatch: tool calls run strictly in submission order on one
worker thread, because pipelined callers depend on that ordering and one
caller's verbs must never race each other (the `apps.open` dedup proof
encodes this). The reader thread stays live to answer fast protocol methods
(`ping`, `tools/list`, discovery) and to observe `notifications/cancelled`:
cancelling a queued call skips it, cancelling the in-flight call unwinds its
poll loop within ~250ms (`mcp_cancel::bail_if_cancelled` in every wait
loop), and the response is dropped per spec. A cancellation cannot interrupt
a blocking approval-bridge read, but the approved effect is suppressed at
the post-approval boundary — an approval answered after cancellation never
types into the target or commits App state. EOF still drains the queue
completely, so piped batch callers keep exact sequential behavior. Process
proof: `crates/unpeel-host/tests/mcp_cancel_process.rs`.
MRTR/input-required should be added only for actual MCP-client elicitation,
not as a replacement for Unpeel's Host/Controller approval UI.

References: `https://blog.cloudflare.com/mcp-v2/` and the official
`https://modelcontextprotocol.io/specification/2026-07-28/server/discover` /
`basic/versioning` / `server/utilities/caching` sections.

Debugging: `mcp-host` lines in `~/.unpeel/hooks/trace.log`. Test with `printf '...' | unpeel-host __mcp__`.
