# Git Status Decorations and the shared repository signal — verification evidence

Date: 2026-10-12 · Branch: `feat/git-support` · Spec: alimazid/unpeel#1
(tickets #2, #4, #5, and the rest of #9 and #10) · Screenshots in
`git-decorations/` (local only, like the other verification screenshots).

Environment: macOS 26 (Darwin 25.6), Xcode 26.3 / Swift 6.2.4, Apple Git
2.50.1. The installed `/Applications/Unpeel.app` and the real `~/.unpeel`
were not touched.

## Decisions taken before building (the user, 2026-10-12)

- **Precedence (#4):** conflict > deleted > modified > type change (letter
  `T`, modified colour) > renamed > copied > added > untracked. A file
  renamed or added and then edited shows `M`.
- **Reveal while the EXPLORER is collapsed (#9):** the file opens at once;
  the reveal is kept and applied the next time the EXPLORER opens. The
  layout does not move.
- **Collapsing GIT HISTORY (#10):** keeps the expanded commit and the scroll
  position; while collapsed nothing is read or watched; expanding again
  catches up in place.
- Implementer's call: a folder shows VS Code's dot `•` in the colour of the
  strongest state beneath it, not a letter.

## 1. Tests

- `clients/native/test-native.sh` after the review fixes (`55e4f48`):
  `Executed 1053 tests, with 0 failures` (XCTest) and `38 tests in 9 suites
  passed` (Swift Testing). Before this work: 977.
- New suites: `GitReaderStatusTests` 14 (real repositories: every state, a
  real merge conflict, staged + unstaged precedence, renames and copies with
  their original path, a type change, paths with spaces, quotes, tabs and
  newlines, a subfolder root, an empty repository, not a repository, no
  git), `GitRepositoryHubTests` 13, `RefreshCoalescerTests` 3,
  `GitDecorationsTests` 6, `ExplorerDecorationTests` 9,
  `ExplorerDecorationRenderingTests` 7, `ExplorerRepositoryChangeTests` 7
  (real FSEvents: an external commit, a checkout, a linked worktree, `git
  init`, a repository removed and recreated), `ExplorerReloadTests` 6,
  `SharedRepositoryReadTests` 1 (one repository change = one status read and
  one log-head read across both views).
- Extended: `ExplorerViewModelTests`, `FileTreeModelTests`,
  `GitRepositoryMonitorTests`, `GitHistoryLiveTests` (+5),
  `GitHistoryOutlineControllerTests` (+1), `ExplorerSectionModelTests` (+2).

## 2. Runtime evidence — the dev app

`Unpeel Dev` built from this tree (`clients/native/dev-blank.sh`,
`UNPEEL_HOME=~/udgh`), driven with synthetic clicks, a socket write into each
Session's PTY (what typing does), and window screenshots. Projects: `deco`
(a scratch repository), `deco-wt` (a linked worktree of it on `feature`),
`plain` (a folder that was not a repository), each with a Terminal Session.

| # | Check | Result |
|---|---|---|
| 1 | Decorations (#4) | PASS — typed in the `deco` Session: an edit, a new file, a delete, a `git mv`, an untracked folder, a staged file, an ignored log. `README.md M`, `staged.txt A`; folders `docs` (deleted), `fresh` (untracked) and `src` (renamed) carry a dot in their strongest colour; inside, `helpers.swift R`, `new.swift U`, everything in `fresh/` untracked; the ignored log stays hidden/dimmed (`app-08…`, `app-09…`) |
| 2 | Live edit | PASS — `echo x >> src/main.swift`: `main.swift M` within a second and `src` turns to the modified colour, the strongest beneath it (`app-10…`) |
| 3 | Commit from the Session (#5) | PASS — `git add -A && git commit`: every letter clears (`app-11…`) |
| 4 | Linked worktree (#5) | PASS — `README.md M` in `deco-wt`; staging in the main checkout leaves it alone; `git commit -am` in the worktree clears it. The worktree's git directory is outside its folder, so the EXPLORER's own watcher never saw that commit: the repository signal did (`app-13…`, `app-14…`) |
| 5 | `git init` + commit in a plain folder (#5, the gap from Git History's verification §2 row 32) | PASS — without reselecting the Session: GIT HISTORY goes from "This folder is not a git repository." to the new commit with HEAD/main, the EXPLORER shows `todo.md U`, the project row shows `main` (`app-15…`, `app-16…`) |
| 6 | Both views update together (#10) | PASS — a commit loop (6 commits, 1.2 s apart) and a later "edit, pause, commit": the EXPLORER shows `main.swift M` between edit and commit, and the commit clears it as it lands on top of GIT HISTORY (`app-21…`, `app-22…`) |
| 7 | Collapse GIT HISTORY keeps its place (#10) | PASS — `agent: loop 4` expanded and the list scrolled down; collapsed; a commit made meanwhile; expanded again: same rows in view, `loop 4` still expanded; at the top the new commit is there (`app-23…`, `app-25…`, `app-26…`) |
| 8 | Reveal with the EXPLORER collapsed (#9) | PASS — clicking `docs/guide.md` in an expanded commit opens the preview pane and the EXPLORER stays collapsed; expanding it shows `docs` expanded and `guide.md` selected (`app-29…`, `app-30…`) |
| 9 | Bursts under an expanded folder (#2) | PASS — 3,000 new files plus 1,500 rewrites in 0.2 s, then a sustained burst (30 rounds of 400 writes over ~3 s) into an expanded `gen/` that ends at 9,001 entries. The app's main thread, timed by an accessibility round trip every 50 ms: median 0.2 ms, p95 80.6 ms, max 212 ms during the sustained burst (max 75.8 ms in the first), CPU 10–13 % afterwards. The tree ends correct: `gen/` lists `n30-200.txt` last, all untracked (`app-32…`, `app-34…`) |

Not re-checked in the app: the review fixes in §3 (each has a test that
failed first). By the time the fixed build was up the user was at the
machine (HID idle 0 s with no synthetic input), so driving the UI stopped.

## 3. Review

Two-axis review (standards, spec) of `0dabd31...HEAD`. Fixed, each with a
test that failed first:

- **Stale decorations on reopening the EXPLORER.** While it was collapsed,
  Git History kept following the root and its last read; reopening served
  that read, so edits made meanwhile did not show. A view that starts
  following a root now reads afresh.
- **A late read moved the watch back.** A "not a repository" read from
  before `git init`, finishing after a newer read, pointed the hub's watch
  back at the folder. Only the newest read steers the watch. (The hub test's
  fake first answered with the state when the read *finished*; it now
  answers with the state when it started, as git does — that is what made
  the race visible.)
- **Decorations on a failed root.** A status read finishing after the root
  failed to load still showed decorations; reads now apply only to the
  follow they were made for.
- **Collapsing GIT HISTORY** now also drops a refresh still waiting out its
  debounce.

Also: one `RefreshCoalescer` serves the decorations' and Git History's
change loops (they were copies); dirty submodules show as `git status`
reports them (the status read no longer passes
`--ignore-submodules=dirty`); `ExplorerOutlineController.apply` is split;
the EXPLORER view-model tests are split (`ExplorerReloadTests`) on a shared
`ExplorerViewModelTestCase`.

Found while testing, fixed (`dbc511d`): a watcher batch arriving while a
folder was scanned for the first time made `open` and `expand` return with
the folder still loading — saved expansions were silently dropped and a
reveal selected nothing. Reproduced deterministically before the fix; it
predates this work.

Kept: the shared status read limits itself to the Explorer Root's subtree
(`-- .`), and `GitHistoryViewModel.repositoryDidChange()` stays as the entry
point for "something outside says the repository changed" (it reports to
the hub, so every view re-reads once).
