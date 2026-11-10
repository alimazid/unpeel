"""Fork-only: the `workspace` MCP domain is served by the MCP host itself.

`list_presets`, `list_worktrees` and `create_worktree` used to POST
`/mcp/*` to the retired Swift bridge and returned 404 on every Host; they
now read app-state and git directly. `list_projects` (new) lists the
workspace's Projects with their groups and worktrees, for a Router choosing
where a Worker runs. Driven through `unpeel mcp workspace …`, the same
dispatcher an agent's MCP server uses, with no app and no Host running.
"""

import json
import os
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, TRUST_SESSION_ENV  # noqa: E402


def git(repo, *words):
    return subprocess.run(
        ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
         "-c", "commit.gpgsign=false", *words],
        capture_output=True, text=True, timeout=30, check=True,
    )


def body(case):
    home = case.home
    repo = home.path("repo")
    os.makedirs(repo)
    git(repo, "init", "--quiet", "-b", "main")
    git(repo, "commit", "--quiet", "--allow-empty", "-m", "init")

    home.project("p", "Repo", repo)
    home.project("other", "Other", "/tmp")
    home.preset(label="cat", command="cat", preset_id="global-cat")
    state = home.state()
    state["presets"] += [
        {"id": "p-tests", "label": "Tests", "command": "true", "project_id": "p", "enabled": True},
        {"id": "off", "label": "Off", "command": "false", "project_id": None, "enabled": False},
        {"id": "elsewhere", "label": "Else", "command": "true", "project_id": "other", "enabled": True},
    ]
    state["projects"] += [
        {"id": "g", "name": "Docs", "path": "", "parent_project_id": "p", "is_folder": True, "sort_order": 1},
        {"id": "sidebar-p", "name": "Sidebar", "path": repo, "parent_project_id": "p", "is_folder": True, "sort_order": 0},
    ]
    home.write_state(state)

    caller = str(uuid.uuid4())
    home.session(caller, label="caller", command="cat", project_id="p", cwd=repo,
                 running=True, extra_manifest={"mcp_enabled": True})

    def mcp(*words):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller, **TRUST_SESSION_ENV)
        return subprocess.run(
            [BINARY, "mcp", "workspace", *words],
            capture_output=True, text=True, timeout=60, env=env, cwd=CRATES,
        )

    def parsed(result):
        try:
            return json.loads(result.stdout)
        except ValueError:
            return {}

    def detail(result):
        return (result.stderr or result.stdout)[:300]

    # 1. list_presets: no app route, the caller's project by default.
    presets = mcp("list_presets")
    ids = [row.get("id") for row in parsed(presets).get("presets", [])]
    case.check("list_presets answers without an app", presets.returncode == 0, detail(presets))
    case.check("it lists this project's presets first, then global ones", ids == ["p-tests", "global-cat"], str(ids))

    # 2. list_projects: roots with their groups, the Sidebar group flagged.
    listed = mcp("list_projects")
    rows = {row.get("id"): row for row in parsed(listed).get("projects", [])}
    case.check("list_projects answers", listed.returncode == 0, detail(listed))
    case.check("both roots are listed", rows.get("p", {}).get("kind") == "root" and rows.get("other", {}).get("kind") == "root", str(rows)[:300])
    group = rows.get("g", {})
    case.check("a group is listed under its root, in the root's folder",
               group.get("kind") == "group" and group.get("parent_id") == "p" and group.get("path") == repo, str(group))
    case.check("the root's Sidebar group is flagged",
               rows.get("sidebar-p", {}).get("sidebar") is True and group.get("sidebar") is False, str(rows.get("sidebar-p")))
    helped = mcp("help")
    case.check("help documents list_projects", "### list_projects" in helped.stdout, detail(helped))

    # 3. Worktrees stay behind the worktree-access setting.
    refused = mcp("create_worktree", "branch=feature")
    case.check("create_worktree is refused without worktree access",
               refused.returncode != 0 and "Agent access" in refused.stderr, detail(refused))
    refused = mcp("list_worktrees")
    case.check("list_worktrees is refused without worktree access", refused.returncode != 0, detail(refused))

    # The Router holds worktree access without the setting (ticket 01).
    state = home.state()
    state["super_agent"] = {"session_id": caller, "since": int(time.time() * 1000)}
    home.write_state(state)
    created = mcp("create_worktree", "branch=feature", "project_id=g", "name=Feature work")
    result = parsed(created)
    path = result.get("path", "")
    child = result.get("project_id", "")
    case.check("the Router creates a worktree from a group's checkout", created.returncode == 0 and bool(child), detail(created))
    case.check("it is a real checkout under this home's worktrees folder",
               os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(os.path.join(path, ".git")), path)
    case.check("it lands under this home", os.path.realpath(path).startswith(os.path.realpath(home.path("worktrees"))), path)
    case.check("name picks its folder, as in the Mac app", os.path.basename(path) == "feature-work", path)
    case.check("the child project id is never native-", child.startswith("mcp-wt-"), child)
    case.check("a new worktree is not adopted", result.get("adopted") is False, str(result))

    # 4. With the setting instead of the mark, a second call adopts.
    state = home.state()
    state.pop("super_agent", None)
    state["mcp_worktree_access"] = True
    home.write_state(state)
    again = parsed(mcp("create_worktree", "branch=feature"))
    case.check("a second create adopts the same worktree",
               again.get("adopted") is True and again.get("project_id") == child and again.get("path") == path, str(again))
    registered = [row for row in home.state().get("projects", []) if row.get("worktree_branch") == "feature"]
    case.check("the child project is registered once", len(registered) == 1, str(registered))
    record = registered[0] if registered else {}
    case.check("it hangs off the root with the requested name",
               record.get("parent_project_id") == "p" and record.get("name") == "Feature work", str(record))

    worktrees = mcp("list_worktrees")
    entries = parsed(worktrees).get("worktrees", [])
    feature = next((row for row in entries if row.get("branch") == "feature"), {})
    case.check("list_worktrees answers", worktrees.returncode == 0, detail(worktrees))
    case.check("list_worktrees shows the new worktree with its project",
               feature.get("project_id") == child and feature.get("managed") is True, str(entries)[:300])
    case.check("and the main checkout as the root Project",
               any(row.get("main") is True and row.get("project_id") == "p" for row in entries), str(entries)[:300])
    listed = parsed(mcp("list_projects"))
    worktree_row = next((row for row in listed.get("projects", []) if row.get("id") == child), {})
    case.check("list_projects lists the worktree under its root",
               worktree_row.get("kind") == "worktree" and worktree_row.get("worktree_branch") == "feature", str(worktree_row))

    # 5. The supervisor's settings are scriptable with `unpeel settings`.
    default = run_cli(home, ["settings", "get", "supervisor_max_children", "--json"])
    case.check("supervisor_max_children reads its default",
               default.returncode == 0 and json.loads(default.stdout or "{}").get("value") == 8, detail(default))
    changed = run_cli(home, ["settings", "set", "supervisor_max_children", "4"])
    case.check("unpeel settings sets it in app-state",
               changed.returncode == 0 and home.state().get("supervisor_max_children") == 4, detail(changed))
    refused = run_cli(home, ["settings", "set", "supervisor_stall_minutes", "7"])
    case.check("a value off the menu is refused and nothing is written",
               refused.returncode != 0 and "supervisor_stall_minutes" not in home.state(), detail(refused))
    listed_settings = run_cli(home, ["settings", "list", "--json"])
    values = json.loads(listed_settings.stdout or "{}")
    case.check("settings list shows the supervisor keys",
               values.get("supervisor_max_children") == 4 and values.get("supervisor_stall_minutes") == 20,
               listed_settings.stdout[:400])


run("super_agent_workspace", body)
