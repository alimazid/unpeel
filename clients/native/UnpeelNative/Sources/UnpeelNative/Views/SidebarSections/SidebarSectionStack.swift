//
//  SidebarSectionStack.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. A VS Code-style vertical stack of
//  collapsible, resizable sections. Generic: it knows section ids, headers
//  and heights, never what a section shows. All height maths is in
//  `SidebarSectionLayout`.
//

import SwiftUI

struct SidebarSectionDescriptor: Identifiable {
    let id: SidebarSectionID
    /// Shown right after the title (e.g. the explorer's root folder name).
    let accessory: AnyView
    /// Trailing header controls, revealed on hover.
    let actions: AnyView
    /// Built only while the section is expanded, so a collapsed or hidden
    /// section's content is unmounted.
    let content: () -> AnyView
}

struct SidebarSectionStack: View {
    @ObservedObject var layoutStore: SidebarSectionLayoutStore
    let sections: [SidebarSectionDescriptor]

    /// The committed layout when the current divider drag began.
    @State private var dragBase: SidebarSectionLayout?
    /// The live layout while a divider is being dragged (never persisted
    /// until the drag ends).
    @State private var liveLayout: SidebarSectionLayout?

    private var layout: SidebarSectionLayout { liveLayout ?? layoutStore.layout }
    private let minimums = SidebarSectionID.minimumContentHeights

    var body: some View {
        GeometryReader { geometry in
            let layout = self.layout
            let space = layout.contentSpace(
                available: geometry.size.height,
                headerHeight: SidebarSectionMetrics.headerHeight,
                separatorHeight: SidebarSectionMetrics.separatorHeight
            )
            let heights = layout.contentHeights(space: space, minimums: minimums)
            let shown = layout.visible.compactMap { id in sections.first { $0.id == id } }

            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        let upper = shown[index - 1].id
                        SidebarSectionDivider(
                            isDraggable: layout.isExpanded(upper) && layout.isExpanded(section.id),
                            onDrag: { dy in
                                resize(upper: upper, lower: section.id, by: dy, space: space)
                            },
                            onDragEnd: commitDrag
                        )
                        .zIndex(1)
                    }
                    SidebarSectionHeader(
                        title: section.id.title,
                        isExpanded: layout.isExpanded(section.id),
                        accessory: section.accessory,
                        actions: section.actions,
                        visibilityItems: visibilityItems(in: layout),
                        onToggleCollapse: {
                            layoutStore.update { $0.togglingCollapse(section.id) }
                        },
                        onSetVisible: { id, visible in
                            layoutStore.update { $0.settingHidden(id, !visible) }
                        }
                    )
                    if layout.isExpanded(section.id) {
                        section.content()
                            .frame(height: heights[section.id] ?? 0)
                            .clipped()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        // Implicit, keyed on collapse/hide only: header clicks and menu
        // toggles animate; divider drags (weights) track the pointer
        // directly. Scoped to this subtree — never a window transaction.
        .animation(SidebarSectionMetrics.collapseAnimation, value: layoutStore.layout.collapsed)
        .animation(SidebarSectionMetrics.collapseAnimation, value: layoutStore.layout.hidden)
    }

    private func visibilityItems(in layout: SidebarSectionLayout) -> [SidebarSectionHeader.VisibilityItem] {
        layout.order.map { id in
            let isVisible = layout.isVisible(id)
            return SidebarSectionHeader.VisibilityItem(
                id: id,
                isVisible: isVisible,
                isEnabled: !(isVisible && layout.visible.count == 1)
            )
        }
    }

    private func resize(upper: SidebarSectionID, lower: SidebarSectionID, by delta: CGFloat, space: CGFloat) {
        let base = dragBase ?? layoutStore.layout
        dragBase = base
        liveLayout = base.resizing(upper: upper, lower: lower, by: delta, space: space, minimums: minimums)
    }

    private func commitDrag() {
        if let final = liveLayout {
            layoutStore.update { _ in final }
        }
        dragBase = nil
        liveLayout = nil
    }
}
