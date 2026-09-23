//
//  SidebarSectionContents.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The app-specific header pieces for the
//  PROJECTS and EXPLORER sections.
//

import SwiftUI
import UnpeelExplorer

/// PROJECTS header actions: Add Project (local scopes only, same rule as
/// the footer "+") and a `…` menu.
struct ProjectsSectionActions: View {
    @ObservedObject var store: UnpeelStore

    var body: some View {
        HStack(spacing: 8) {
            if store.canPickProjectFolder {
                Button {
                    store.addProjectFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Add Project")
            }
            Menu {
                Button("Collapse All Folders") { store.collapseAllSidebarFolders() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(Theme.mutedForeground)
    }
}

/// The EXPLORER title's accessory: the tree root's folder name, dimmed.
/// Resolved from the store (not the view model) so it stays correct while
/// the tree is collapsed and unmounted.
struct ExplorerSectionTitleAccessory: View {
    @ObservedObject var store: UnpeelStore
    @ObservedObject private var selection: SessionSelectionState

    init(store: UnpeelStore) {
        self.store = store
        self.selection = store.sessionSelection
    }

    var body: some View {
        if let name = ExplorerPanelView.rootName(
            for: ExplorerPanelHost.context(store: store, sessionID: selection.sessionID)
        ) {
            Text(name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.mutedForeground.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)
        }
    }
}
