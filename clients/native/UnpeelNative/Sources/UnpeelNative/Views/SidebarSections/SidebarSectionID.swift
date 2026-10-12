//
//  SidebarSectionID.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The sections the left sidebar stacks, in
//  their default top-to-bottom order. A new section is one more case here;
//  saved layouts pick it up without a migration (`SidebarSectionLayout
//  .decode` appends missing ids in their fresh-install state).
//

import CoreGraphics

enum SidebarSectionID: String, CaseIterable, Sendable {
    case projects
    case explorer
    // Fork-only: git support
    case gitHistory

    var title: String {
        switch self {
        case .projects: return "PROJECTS"
        case .explorer: return "EXPLORER"
        case .gitHistory: return "GIT HISTORY"
        }
    }

    /// Smallest content height (header excluded) a divider drag or a
    /// neighbour's growth may leave this section with.
    var minimumContentHeight: CGFloat {
        switch self {
        case .projects: return 80
        case .explorer: return 120
        case .gitHistory: return 100
        }
    }

    static var minimumContentHeights: [SidebarSectionID: CGFloat] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.minimumContentHeight) })
    }
}
