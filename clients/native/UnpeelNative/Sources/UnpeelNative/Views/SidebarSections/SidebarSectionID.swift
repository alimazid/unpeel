//
//  SidebarSectionID.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The sections the left sidebar stacks, in
//  their default top-to-bottom order. A new section is a case here plus
//  its default weight (`SidebarSectionLayout.defaultWeights`), its list
//  type if it takes focus (`SidebarSectionFocus.listType`), its view in
//  `SidebarView`, and, for a shortcut, a View-menu item in `AppDelegate`.
//  Saved layouts pick it up without a migration (`SidebarSectionLayout
//  .decode` inserts missing ids at their default place, in their
//  fresh-install state).
//

import CoreGraphics

enum SidebarSectionID: String, CaseIterable, Sendable {
    case projects
    // Fork-only: the activity dropdown as a section
    case agents
    // Fork-only: Scheduled Tasks
    case scheduled
    case explorer
    // Fork-only: git support
    case gitHistory

    var title: String {
        switch self {
        case .projects: return "PROJECTS"
        case .agents: return "AGENTS"
        case .scheduled: return "SCHEDULED"
        case .explorer: return "EXPLORER"
        case .gitHistory: return "GIT HISTORY"
        }
    }

    /// Smallest content height (header excluded) a divider drag or a
    /// neighbour's growth may leave this section with.
    var minimumContentHeight: CGFloat {
        switch self {
        case .projects: return 80
        case .agents: return 80
        case .scheduled: return 60
        case .explorer: return 120
        case .gitHistory: return 100
        }
    }

    static var minimumContentHeights: [SidebarSectionID: CGFloat] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.minimumContentHeight) })
    }
}
