//
//  SuperAgentBadge.swift
//  UnpeelNative
//
//  Fork-only: marks the workspace's Super Agent in its PROJECTS row (next
//  to the pin) and its AGENTS row (the trailing slot). Status only, like
//  the pin indicator: the session menu holds the verbs.
//

import SwiftUI

struct SuperAgentBadge: View {
    var tint: Color = Theme.foreground.opacity(0.88)

    var body: some View {
        // Phosphor "tree-structure": the Session that runs the others.
        ChromeIconView(icon: .orchestrator, size: 12)
            .foregroundStyle(tint)
            .accessibilityLabel("Super Agent")
            .allowsHitTesting(false)
    }
}
