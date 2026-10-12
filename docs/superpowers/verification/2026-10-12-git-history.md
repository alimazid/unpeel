# Git History — verification evidence

Date: 2026-10-12 · Branch: `feat/git-support` · Spec: alimazid/unpeel#1
(tickets #3, #6–#11) · Screenshots in `git-history/` (local only, like the
other verification screenshots).

Environment: macOS 26 (Darwin 25.6), Xcode 26.3 / Swift 6.2.4, Apple Git
2.50.1. The installed `/Applications/Unpeel.app` and the real `~/.unpeel`
were not touched.

## 1. Tests

- `clients/native/test-native.sh` at `8652cfd`: `Executed 971 tests, with 0
  failures`.
- New suites (`UnpeelGitTests`): `GitRunnerTests` 9, `GitReaderHeadTests` 11,
  `GitReaderLogTests` 10, `GitReaderRefsTests` 4, `GitReaderDetailTests` 8,
  `GitHistoryViewModelTests` 9, `GitHistoryCommitListTests` 11,
  `GitHistoryFilterTests` 10, `GitHistoryDetailTests` 9,
  `GitHistoryLiveTests` 13, `GitHistoryOutlineControllerTests` 13,
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

The screen was locked for the whole run (past midnight, user away), so
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

## 3. Not yet exercised in the running app

Pending an unlocked screen. The dev build is built from `8652cfd` and was
left running against `UNPEEL_HOME=~/udgh` with the scratch repository as a
Project and one shell Session; its saved sidebar layout was seeded with a
pre-Git-History record (PROJECTS 0.35 / EXPLORER 0.65).

- GIT HISTORY appended collapsed under EXPLORER on that pre-existing layout;
  collapse / expand / resize / hide like the other sections.
- Each empty state in the sidebar: no Session, remote Host, not a
  repository, no commits.
- ⌃⇧G from every state, including while a terminal has focus; the View
  menu title.
- Clicking a changed file: reveal in the EXPLORER and open (Markdown in the
  preview pane, a source file through Open With).
- The History Branch Filter menu itself (its rendering as a popup), and
  scroll position held while commits land on top (covered by
  `GitHistoryOutlineControllerTests`).
