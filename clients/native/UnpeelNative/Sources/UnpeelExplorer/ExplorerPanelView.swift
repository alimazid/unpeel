import AppKit
import SwiftUI

public struct ExplorerPanelView: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let palette: ExplorerPalette
    private let actionHandler: (any ExplorerActionHandler)?
    /// False when a host draws the title and `ExplorerPanelMenu` in its own
    /// chrome (the app's sidebar section header).
    private let showsHeader: Bool

    public init(
        viewModel: ExplorerViewModel,
        palette: ExplorerPalette,
        actionHandler: (any ExplorerActionHandler)?,
        showsHeader: Bool = true
    ) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
        self.showsHeader = showsHeader
    }

    public static func title(for context: ExplorerContext) -> String {
        rootName(for: context)?.uppercased() ?? "EXPLORER"
    }

    /// The browsing root's folder name as it appears on disk, or nil when
    /// there is no local tree.
    public static func rootName(for context: ExplorerContext) -> String? {
        guard case .local(let root, _) = context else { return nil }
        return (root as NSString).lastPathComponent
    }

    public static func message(for context: ExplorerContext, rootError: String?) -> String? {
        switch context {
        case .none: return "Select a session to browse its files."
        case .remote: return "The explorer is available for sessions running on this Mac."
        case .local: return rootError
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
            }
            if let message = Self.message(for: viewModel.context, rootError: viewModel.rootError) {
                emptyState(message)
            } else {
                ExplorerOutlineView(viewModel: viewModel, palette: palette, actionHandler: actionHandler)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(Self.title(for: viewModel.context))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            ExplorerPanelMenu(viewModel: viewModel, tint: palette.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .multilineTextAlignment(.center)
            if viewModel.rootError != nil {
                Button("Retry") { viewModel.retry() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The explorer's `…` menu — refresh, collapse, and visibility filters.
/// Public so a host that draws its own header shows the same menu.
public struct ExplorerPanelMenu: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let tint: NSColor

    public static let itemTitles = ["Refresh", "Collapse All", "Show Hidden Files", "Show Git-Ignored Files"]

    public init(viewModel: ExplorerViewModel, tint: NSColor) {
        self.viewModel = viewModel
        self.tint = tint
    }

    public var body: some View {
        Menu {
            Button(Self.itemTitles[0]) { viewModel.refresh() }
            Button(Self.itemTitles[1]) { viewModel.collapseAll() }
            Divider()
            Toggle(Self.itemTitles[2], isOn: filterBinding(\.showHidden) {
                VisibilityFilter(showHidden: $0, showIgnored: viewModel.filter.showIgnored)
            })
            Toggle(Self.itemTitles[3], isOn: filterBinding(\.showIgnored) {
                VisibilityFilter(showHidden: viewModel.filter.showHidden, showIgnored: $0)
            })
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(Color(nsColor: tint))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.model == nil)
    }

    private func filterBinding(
        _ keyPath: KeyPath<VisibilityFilter, Bool>,
        _ make: @escaping (Bool) -> VisibilityFilter
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.filter[keyPath: keyPath] },
            set: { viewModel.setFilter(make($0)) }
        )
    }
}
