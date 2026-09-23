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

    /// The divider drag in progress, applied on top of the committed
    /// layout while rendering and persisted only when the drag ends.
    @State private var drag: DividerDrag?

    private var layout: SidebarSectionLayout {
        guard let drag, drag.isCurrent(for: layoutStore.layout) else { return layoutStore.layout }
        return drag.applied(to: layoutStore.layout, minimums: minimums)
    }

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
            // Headers alone can exceed a very short sidebar.
            .clipped()
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
        guard let current = drag else {
            drag = DividerDrag(upper: upper, lower: lower, startedOn: layoutStore.layout, translation: delta, space: space)
            return
        }
        // A drag overtaken by a collapse or hide stays dropped until it ends.
        guard current.isCurrent(for: layoutStore.layout) else { return }
        drag = current.moved(to: delta, space: space)
    }

    /// Applies only the resize to the layout as it is now, so a collapse or
    /// hide made during the drag is never written back over.
    private func commitDrag() {
        guard let finished = drag else { return }
        drag = nil
        guard finished.isCurrent(for: layoutStore.layout) else { return }
        layoutStore.update { finished.applied(to: $0, minimums: minimums) }
    }
}

/// One divider drag: the pair it resizes, how far it has moved, and the
/// collapse/hide state it started under (a change to either drops it).
private struct DividerDrag {
    let upper: SidebarSectionID
    let lower: SidebarSectionID
    let collapsed: Set<SidebarSectionID>
    let hidden: Set<SidebarSectionID>
    let translation: CGFloat
    let space: CGFloat

    init(
        upper: SidebarSectionID,
        lower: SidebarSectionID,
        startedOn layout: SidebarSectionLayout,
        translation: CGFloat,
        space: CGFloat
    ) {
        self.init(
            upper: upper,
            lower: lower,
            collapsed: layout.collapsed,
            hidden: layout.hidden,
            translation: translation,
            space: space
        )
    }

    private init(
        upper: SidebarSectionID,
        lower: SidebarSectionID,
        collapsed: Set<SidebarSectionID>,
        hidden: Set<SidebarSectionID>,
        translation: CGFloat,
        space: CGFloat
    ) {
        self.upper = upper
        self.lower = lower
        self.collapsed = collapsed
        self.hidden = hidden
        self.translation = translation
        self.space = space
    }

    func isCurrent(for layout: SidebarSectionLayout) -> Bool {
        layout.collapsed == collapsed && layout.hidden == hidden
    }

    func moved(to translation: CGFloat, space: CGFloat) -> DividerDrag {
        DividerDrag(upper: upper, lower: lower, collapsed: collapsed, hidden: hidden, translation: translation, space: space)
    }

    func applied(to layout: SidebarSectionLayout, minimums: [SidebarSectionID: CGFloat]) -> SidebarSectionLayout {
        layout.resizing(upper: upper, lower: lower, by: translation, space: space, minimums: minimums)
    }
}
