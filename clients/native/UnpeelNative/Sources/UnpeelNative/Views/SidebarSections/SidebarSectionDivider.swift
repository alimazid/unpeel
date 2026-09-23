//
//  SidebarSectionDivider.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The visible 1 pt separator between two
//  sections; when both neighbours are expanded it is also a 6 pt drag
//  handle with the vertical resize cursor.
//

import AppKit
import SwiftUI

struct SidebarSectionDivider: View {
    let isDraggable: Bool
    /// Vertical translation since the drag began (positive = down).
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? Theme.paneDividerLineHover : Theme.paneDividerLine)
            .frame(height: SidebarSectionMetrics.separatorHeight)
            .overlay {
                if isDraggable {
                    Color.clear
                        .frame(height: SidebarSectionMetrics.dividerHitHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovering = inside
                            if inside {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    dragging = true
                                    onDrag(value.translation.height)
                                }
                                .onEnded { _ in
                                    dragging = false
                                    onDragEnd()
                                }
                        )
                }
            }
    }
}
