# PROJECTS is one flat lazy list of rows

**Status:** accepted (2026-11-07)

## Context

The Mac app's PROJECTS tree was a lazy stack of project blocks, and each
expanded block held its own lazy stack of Session and folder rows, recursing
into child groups. Builds 121–130 hung five times, for 1 s up to 7016 s, with
the main thread looping in SwiftUI's lazy-stack estimates of children that
contain lazy stacks. The 11-07 hang followed a click on a Session row
(#39). The carousel's pooled page copied the same nesting.

## Decision

PROJECTS, and the pooled carousel page, render one `LazyVStack` whose
children are rows: top-level project headers, folder headers, Sessions and
empty placeholders. One pure flattener produces those rows for both pages.
No lazy stack nests inside another. Whatever used to belong to a project
block or a group cluster is rebuilt per row from the row's ancestry: the
drop shells, the group wash, the cluster drag shift, the block gaps, the
spacing and the animations.

## Considered Options

- **An eager `VStack` inside each expanded project.** Measured and rejected
  (branch `fix/sidebar-projects-livelock`). With about 100 rows in one
  project, the main thread went from 37–48 % busy to 89 %, with DisplayList
  and CA commits about 3× higher, because every row of the block, including
  off-screen ones, was in the render tree on every update. That build also
  logged the "Geometry action is cycling" fault.
- **Keep the nested lazy stacks.** Rejected: it is the shape all five hangs
  share.

## Consequences

The per-block conveniences are gone: a block-level background, a single
transition on an expanding block's contents, a block-wide offset. Each one
has a per-row equivalent driven by the row's ancestry. Anyone who wants a
block-level container back for an animation has to measure it against both
rejected options first.
