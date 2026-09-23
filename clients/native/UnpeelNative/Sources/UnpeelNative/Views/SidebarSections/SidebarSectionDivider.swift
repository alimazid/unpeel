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
    /// Called once per drag: when it ends, is cancelled, or the handle is
    /// removed mid-drag.
    let onDragEnd: () -> Void

    /// True exactly while this divider has a resize cursor pushed, so every
    /// push is matched by one pop whatever order the events arrive in.
    @State private var hovering = false
    /// Resets on end *and* on cancellation, which `onEnded` alone misses.
    @GestureState private var dragging = false
    @State private var bandFrame: CGRect = .zero
    @State private var lastDragLocation: CGPoint?

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? Theme.paneDividerLineHover : Theme.paneDividerLine)
            .frame(height: SidebarSectionMetrics.separatorHeight)
            .overlay {
                if isDraggable {
                    handle
                }
            }
    }

    private var handle: some View {
        Color.clear
            .frame(height: SidebarSectionMetrics.dividerHitHeight)
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { bandFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { bandFrame = $0 }
                }
            )
            .onHover { inside in
                // A drag owns the cursor; the divider slides under the
                // pointer as heights change, and reacting to those
                // enter/exit edges would flicker the cursor.
                guard !dragging else { return }
                inside ? pushCursor() : popCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        lastDragLocation = value.location
                        onDrag(value.translation.height)
                    }
                    .onEnded { _ in finishDrag() }
            )
            // Cancellation path: `onEnded` never runs for a cancelled drag.
            .onChange(of: dragging) { isDragging in
                if !isDragging { finishDrag() }
            }
            .onDisappear {
                finishDrag()
                popCursor()
            }
    }

    /// Reached from `onEnded` and the gesture-state reset; only the first
    /// call for a drag does anything.
    private func finishDrag() {
        guard let location = lastDragLocation else { return }
        lastDragLocation = nil
        // Hover changes were ignored during the drag, so a pointer that left
        // the band (clamped at a minimum) still holds the pushed cursor.
        if !bandFrame.contains(location) {
            popCursor()
        }
        onDragEnd()
    }

    private func pushCursor() {
        guard !hovering else { return }
        NSCursor.resizeUpDown.push()
        hovering = true
    }

    private func popCursor() {
        guard hovering else { return }
        NSCursor.pop()
        hovering = false
    }
}
