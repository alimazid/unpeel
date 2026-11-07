//
//  KeptOutputView.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks (ADR 0006, #36). The terminal area of a
//  stopped Run whose output the Host kept: that output as the terminal drew
//  it, read-only and scrollable, under a bar that keeps Resume offered. It
//  takes the stopped placeholder's frame, so moving between the two, or to
//  a live Session, never shifts the layout.
//

import AppKit
import SwiftUI

struct KeptOutputView: View {
    @ObservedObject var store: UnpeelStore
    let session: SessionEntry
    let backgroundColor: NSColor

    @ObservedObject private var panes: KeptOutputPanes
    @ObservedObject private var runtime: RemoteHostRuntime
    /// Re-runs the body on a terminal font change, which `pane(for:style:)`
    /// pushes to the pane as it does for remote panes.
    @ObservedObject private var terminalFont = TerminalFontModel.shared

    init(store: UnpeelStore, session: SessionEntry, backgroundColor: NSColor) {
        self.store = store
        self.session = session
        self.backgroundColor = backgroundColor
        _panes = ObservedObject(wrappedValue: store.keptOutputPanes)
        _runtime = ObservedObject(wrappedValue: store.remoteHostRuntime)
    }

    var body: some View {
        let key = KeptOutputPanes.Key(
            scopeID: store.selectedHostScope.paneScopeID,
            sessionID: session.id,
            generation: session.lifecycleAtMs
        )
        let pane = panes.pane(
            for: key,
            style: RemoteScopeTerminalMount.paneStyle(for: session, background: backgroundColor)
        )
        VStack(spacing: 0) {
            KeptOutputBar(
                background: Color(nsColor: backgroundColor),
                showsLastPart: panes.isTruncated(key),
                canResume: store.sessionCanRestart(session.id),
                isRestarting: store.restartingSessionIDs.contains(session.id),
                command: session.command,
                onResume: { store.restartSession(session.id) }
            )
            RemoteTerminalPaneHostView(pane: pane, backgroundColor: backgroundColor)
        }
        // Read again once a Host connection exists (a cold launch shows the
        // disk seed before the first bootstrap).
        .task(id: LoadTrigger(key: key, connected: runtime.snapshot != nil)) {
            let sessionID = session.id
            panes.load(key) { [runtime] in
                try await runtime.keptOutputTail(sessionID: sessionID)
            }
        }
    }

    private struct LoadTrigger: Equatable {
        let key: KeptOutputPanes.Key
        let connected: Bool
    }
}

/// The stopped Run's bar, in the slot the pane banners use: what the area
/// shows, and Resume with the placeholder's action and in-flight state.
struct KeptOutputBar: View {
    let background: Color
    /// The tail shown leaves earlier output out.
    let showsLastPart: Bool
    let canResume: Bool
    let isRestarting: Bool
    let command: String
    let onResume: () -> Void
    @State private var resumeHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Session exited")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
            Text(showsLastPart ? "Showing the last part of its kept output" : "Showing its kept output")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if canResume {
                Button(action: onResume) {
                    HStack(spacing: 5) {
                        if isRestarting {
                            BrailleSpinner(color: Theme.toolSpinnerColor(forCommand: command))
                                .frame(width: 12, height: 12)
                            Text("Resuming")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Resume")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.foreground)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.foreground.opacity(resumeHovering ? 0.13 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.foreground.opacity(0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRestarting)
                .onHover { resumeHovering = $0 }
                .accessibilityLabel("Resume this session")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.foreground.opacity(0.08))
                .frame(height: 1)
        }
    }
}
