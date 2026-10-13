# Git History — verification evidence

Date: 2026-10-12 · Branch: `feat/git-support` · Spec: alimazid/unpeel#1
(tickets #3, #6–#11) · Screenshots in `git-history/` (local only, like the
other verification screenshots).

Environment: macOS 26 (Darwin 25.6), Xcode 26.3 / Swift 6.2.4, Apple Git
2.50.1. The installed `/Applications/Unpeel.app` and the real `~/.unpeel`
were not touched.

## 1. Tests

- `clients/native/test-native.sh` at `8652cfd`: `Executed 971 tests, with 0
  failures`; after the review fixes (§4): `Executed 976 tests, with 0
  failures`; after the in-app scroll fix (§4): `Executed 977 tests, with 0
  failures`.
- New suites (`UnpeelGitTests`): `GitRunnerTests` 9, `GitReaderHeadTests` 11,
  `GitReaderLogTests` 10, `GitReaderRefsTests` 4, `GitReaderDetailTests` 8,
  `GitHistoryViewModelTests` 9, `GitHistoryCommitListTests` 11,
  `GitHistoryFilterTests` 10, `GitHistoryDetailTests` 9,
  `GitHistoryLiveTests` 13, `GitHistoryOutlineControllerTests` 14,
  `GitHistoryOutlineDetailTests` 8, `GitHistoryHeaderTests` 2. Reader tests
  run against real throwaway repositories (a local bare repository as
  `origin`), never a mocked git.
- New in other suites: `GitIgnoreCheckerTests` 1, `GitRepositoryMonitorTests`
  7 (two against real FSEvents), `GitHistoryFocusCommandTests` 6,
  `GitHistoryHostActionsTests` 1; `SidebarSectionLayoutTests` and
  `SidebarSectionStackTests` extended for GIT HISTORY. `DirectoryScannerTests`
  and the ⇧⌘E suites (`ExplorerFocusCommandTests`, `ExplorerFocusTests`) run
  unchanged.

## 2. Runtime evidence

### Offscreen, while the screen was locked

The screen was locked for the whole build (past midnight, user away), so
window screenshots and synthetic input were unavailable (`screencapture`:
"could not create image"; the accessibility tree came back empty). The
checks below therefore drove the real views and the real reader, runner and
FSEvents monitor in-process against a scratch repository (232 commits,
`main` tracking a bare `origin`, local `feature/history` and `topic`, tags
`v0.1` and annotated `v1.0`, a rename, a delete, a multi-paragraph message).

| # | Check | Result |
|---|---|---|
| 1 | Git History rendered offscreen, dark | PASS — filter shows `main ⌄`, `↑0 ↓0`; dot lane with HEAD as an accent ring; HEAD / main / origin/main and `topic` labels; `author · age` (`01-list-dark.png`) |
| 2 | Same, light | PASS — labels and lane legible (`02-list-light.png`) |
| 3 | Expand the rename commit | PASS — message, then `R guide.md  docs ← docs/notes.md` and `D log.txt` in VS Code's git colours, lane continues (`03-expanded-rename.png`) |
| 4 | Expand another commit | PASS — the first collapses; the multi-paragraph message wraps at sidebar width; `A` files (`04-expanded-message.png`) |
| 5 | History Branch Filter ▸ All branches | PASS — `feature/history`'s commit on top by date; the header names the Checked-out Branch (`main ↑0 ↓0`) while another filter is shown; the expanded commit stays (still listed) (`05-all-branches.png`) |
| 6 | Paging | PASS — first page 200 commits with more; scrolling's load-more reached all 232 |
| 7 | Live: commit from the shell | PASS — on top within 0.27 s; loaded pages and the expanded commit kept; ahead count went 3 → 4 |
| 8 | Live: branch created / deleted | PASS — in the filter within 0.28 s; gone within 0.28 s |
| 9 | Live: checkout from the shell | PASS — header and default list followed `feature/history` within 0.27 s; back to `main` within 0.23 s |
| 10 | No index lock during reads | PASS — `.git/index.lock` never present; `GitRunnerTests` proves `status` does not rewrite a stale index |

Live log (`EVIDENCE` lines from the run):

```
before: commits=235 top=agent: live commit 1791779010 head=main ahead=3
external commit on top: ok after 0.27s
after commit: commits=236 expanded=true ahead=4
new branch in filter: ok after 0.28s
external checkout: ok after 0.27s
after checkout: filterTitle=feature/history top=feat: feature branch work
checkout back: ok after 0.23s
deleted branch leaves filter: ok after 0.28s
index.lock exists: false
```

### In the running app

Later the same morning, with the screen unlocked: the dev build (`Unpeel
Dev`, built from `9608770`, then rebuilt with the §4 scroll fix) against
`UNPEEL_HOME=~/udgh`, its saved sidebar layout seeded with a pre-Git-History
record (PROJECTS 0.35 / EXPLORER 0.65). Driven with synthetic clicks and
keys, read back through window screenshots and the accessibility tree
(focused element, scroller value, View menu titles). Projects: the scratch
repository, a plain folder (`notrepo`) and a `git init`-ed folder with no
commits (`emptyrepo`), each with a Terminal Session. Screenshots are the
`app-*.png` files.

| # | Check | Result |
|---|---|---|
| 11 | Pre-existing layout | PASS — GIT HISTORY appended collapsed under EXPLORER; nothing above it moved (`app-01-start.png`) |
| 12 | Collapse / expand / resize / hide | PASS — header click expands; divider drag resizes; the header menu hides it (✓ Projects / Explorer / Git History); layout (expanded, weights) survives a quit and relaunch (`app-06-resized.png`, `app-21-header-menu.png`, `app-38-after-relaunch.png`) |
| 13 | Empty states | PASS — no Session: "Select a session to browse its history."; plain folder: "This folder is not a git repository."; empty repository: "No commits yet." with a plain `main` label and no filter menu (`app-03…`, `app-32…`, `app-34…`) |
| 14 | Header | PASS — `main ⌄  ↑4 ↓0` matches `git status -sb`; `feature/history` (no upstream) shows no counts (`app-05-session.png`, `app-29-switched.png`) |
| 15 | History Branch Filter popup | PASS — feature/history, ✓ main, topic │ origin/main │ All branches; `topic` lists its own history while the header keeps `main ↑4 ↓0`; All branches puts `feature/history`'s commit in date order (`app-07…`, `app-08…`, `app-10…`) |
| 16 | Commit detail | PASS — a click expands in place (message wraps; `A`/`R`/`D` in VS Code colours; `docs ← docs/notes.md`); clicking another commit collapses the first (`app-12…`, `app-13…`, `app-43…`) |
| 17 | Changed file → Markdown | PASS — `README.md` selected in the EXPLORER and opened in the preview pane (`app-14-readme.png`) |
| 18 | Changed file → source | PASS — `src` expanded, `main.swift` selected in the EXPLORER, opened through Open With in the preferred editor (VS Code) (`app-15-mainswift.png`) |
| 19 | Changed file no longer on disk | PASS — `docs/notes.md` (since renamed): row selects, nothing opens, no error (`app-16…`) |
| 20 | Changed file with EXPLORER collapsed | As decided — `guide.md` opens in the preview pane; EXPLORER stays collapsed and, re-expanded, shows its own last selection, not `guide.md` (`app-44…`, `app-45…`). **Superseded:** the reveal is now kept and applied when the EXPLORER next opens (#9; `2026-10-12-git-decorations.md` §2 row 8) |
| 21 | ⌃⇧G, Git History focused | PASS — collapses; focus goes to the terminal; View menu read "Hide Git History" before, "Show Git History" after (`app-17…`) |
| 22 | ⌃⇧G, collapsed, terminal focused | PASS — expands and focuses the list; nothing typed into the terminal (`app-18…`) |
| 23 | ⌃⇧G, expanded, EXPLORER focused | PASS — focuses the list, stays expanded; menu "Hide Explorer, Show Git History" → "Show Explorer, Hide Git History" |
| 24 | ⌃⇧G, expanded, terminal focused | PASS — focuses the list |
| 25 | ⌃⇧G, sidebar hidden (section collapsed) | PASS — sidebar shown, section expanded and focused (`app-19…`, `app-20…`) |
| 26 | ⌃⇧G, section hidden | PASS — shown again at its old size, expanded, focused (`app-22…`, `app-23…`) |
| 27 | Keyboard and menus | PASS — ↓↓ Return expands the second commit; ⌘C copies its full SHA; the context menu's Copy SHA / Copy Subject put the exact values on the pasteboard (`app-24…`, `app-25…`) |
| 28 | Live: commit typed in the Session, list scrolled down | PASS — `↑4` → `↑5`; the rows in view stay put; at the top, the new commit is there with HEAD/main and the expanded commit still open (`app-26…`, `app-27…`, `app-28…`) |
| 29 | Live: `git switch` in the Session | PASS — header and list follow `feature/history` and back (`app-29…`) |
| 30 | Live: commit loop (6 commits, 0.4 s apart) | PASS after the §4 fix — counts track the loop; at the top the new commits come into view, scrolled down the rows stay put (`app-51…`, `app-56…`, `app-58…`). Before the fix: FAIL, see §4 |
| 31 | Live: first commit in an empty repository | PASS — "No commits yet." becomes the commit, and the label becomes the filter menu (`app-35…`) |
| 32 | Live: `git init` + commit in a plain folder | FAIL at the time — stays "This folder is not a git repository." until the Session is reselected (`app-33…`, `app-36…`); see §4. **Fixed** in Phase A (#5; `2026-10-12-git-decorations.md` §2 row 5) |

One false negative while testing: clicks that selected a commit without
expanding it were traced to the test harness leaving Command latched after
a synthetic ⌘C (⌘-click is deliberately ignored, as in the EXPLORER); with
the modifier released, clicks expand.

## 3. Not exercised in the running app

Not reachable in this throwaway home; covered by the view-model tests.

- Remote Host empty state (no paired remote Host).
- git not found (would mean removing git from this Mac).

## 4. Review

Two-axis review (standards, spec) of `main...HEAD`. Fixed, each with a test
that failed first:

- An empty repository's "All branches" turned the "No commits yet" state
  into `fatal: bad revision 'HEAD'` and stopped live updates — the filter now
  has no choices until there are commits (the header shows a plain label).
- A chosen branch became "follow HEAD" once an agent checked it out, so it
  was lost when HEAD moved on — the choice is no longer rewritten on refresh.
- A failed branch listing reset a chosen branch — the last listing and the
  choice are kept, and the failure is logged.
- Keypad Enter (numeric-pad flag) did not toggle a commit.
- git now runs with `LC_ALL=C`, so "not a git repository" is recognised
  under any locale.

Also: swallowed read failures are logged; the section focus lookup is one
per-section table instead of repeated `if` cascades in `AppDelegate`; branch
ref parsing and the gutter constraints have one home each; the
non-monitoring `GitHistoryServices.live` default and an unused property were
removed. The History Branch Filter now lists local branches first, then
remote-tracking ones, then "All branches".

Kept by decision: a changed file is revealed in the EXPLORER only while its
tree is showing (a collapsed EXPLORER is not expanded — **superseded**, see
§2 row 20); GIT HISTORY also
starts collapsed on a fresh install; Return toggles a commit and ⌘C copies
its SHA.

Found in the running app (§2):

- **Fixed — new commits hidden at the top.** After a section resize or a
  scroll back up, the list can rest a fraction of a point below the top
  (scroller value 1.8e-5 and 8.5e-5 in the app). Landing commits treated
  that as "scrolled down" and kept the old rows in view, so new commits
  arrived out of sight. "At the top" now allows up to one point
  (`GitHistoryOutlineController.atTopTolerance`), with a test that sets a
  0.3 pt offset and failed first; re-checked in the rebuilt app at an
  8.5e-5 offset (`app-56…`) and scrolled down (`app-58…`).
- **Open at the time, fixed in Phase A (#5)** — a folder that becomes a
  repository. "Not a git repository"
  stops watching (there is no git directory to watch), so an agent's
  `git init` in the Session's folder is not noticed until the Session is
  reselected or the section re-expanded. Natural home: the shared
  repository-change signal Phase A (#5) introduces, which could also watch
  a non-repository root for a `.git` appearing.
- **By design, noted** — collapsing or hiding GIT HISTORY stops its reads
  and watching; re-expanding reloads, so the expanded commit and scroll
  position are not kept. The EXPLORER, which persists its own state, keeps
  them. **Superseded** (#10): collapsing now keeps the expanded commit and
  scroll position, still without reads while collapsed
  (`2026-10-12-git-decorations.md` §2 row 7).
