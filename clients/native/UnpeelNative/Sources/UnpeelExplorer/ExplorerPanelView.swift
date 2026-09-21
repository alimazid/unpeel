import AppKit
import SwiftUI

public struct ExplorerPanelView: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let palette: ExplorerPalette
    private let actionHandler: (any ExplorerActionHandler)?

    public init(
        viewModel: ExplorerViewModel,
        palette: ExplorerPalette,
        actionHandler: (any ExplorerActionHandler)?
    ) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
    }

    public static func title(for context: ExplorerContext) -> String {
        guard case .local(let root, _) = context else { return "EXPLORER" }
        return (root as NSString).lastPathComponent.uppercased()
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
            header
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
            Menu {
                Button("Refresh") { viewModel.refresh() }
                Button("Collapse All") { viewModel.collapseAll() }
                Divider()
                Toggle("Show Hidden Files", isOn: filterBinding(\.showHidden) {
                    VisibilityFilter(showHidden: $0, showIgnored: viewModel.filter.showIgnored)
                })
                Toggle("Show Git-Ignored Files", isOn: filterBinding(\.showIgnored) {
                    VisibilityFilter(showHidden: viewModel.filter.showHidden, showIgnored: $0)
                })
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(Color(nsColor: palette.secondaryText))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.model == nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
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
