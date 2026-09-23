//
//  SidebarSectionHeader.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. One section's header row: chevron, title,
//  optional accessory (e.g. the explorer's root name), and trailing
//  actions revealed on hover. A click anywhere outside the actions toggles
//  collapse; right-click lists every section to show or hide.
//

import SwiftUI

struct SidebarSectionHeader: View {
    struct VisibilityItem: Identifiable {
        let id: SidebarSectionID
        let isVisible: Bool
        let isEnabled: Bool
    }

    let title: String
    let isExpanded: Bool
    let accessory: AnyView
    let actions: AnyView
    let visibilityItems: [VisibilityItem]
    let onToggleCollapse: () -> Void
    let onSetVisible: (SidebarSectionID, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            accessory
            Spacer(minLength: 4)
            actions
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 10)
        .frame(height: SidebarSectionMetrics.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapse)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(visibilityItems) { item in
                Toggle(item.id.title.capitalized, isOn: Binding(
                    get: { item.isVisible },
                    set: { onSetVisible(item.id, $0) }
                ))
                .disabled(!item.isEnabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction { onToggleCollapse() }
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", onToggleCollapse)
    }
}
