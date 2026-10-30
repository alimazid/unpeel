import AppKit
import SwiftUI

/// Git History's content inside its sidebar section: the header, then the
/// commit log or the empty state that explains why there is none. In an
/// Explorer Root that is not a repository (Fork-only: nested repositories)
/// the nested repository in use comes first, and the empty state offers
/// the nested repositories while none is.
public struct GitHistoryPanelView: View {
    @ObservedObject private var viewModel: GitHistoryViewModel
    private let palette: GitHistoryPalette
    private let actionHandler: (any GitHistoryActionHandler)?

    public init(viewModel: GitHistoryViewModel, palette: GitHistoryPalette, actionHandler: (any GitHistoryActionHandler)?) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
    }

    /// Fork-only: nested repositories. The nested repositories the empty
    /// state offers: only for "not a repository" while none is in use.
    static func choices(status: GitHistoryStatus, repository: GitRepositoryRootState?) -> [String] {
        guard status == .notARepository, let repository, repository.canChoose, repository.chosen == nil else {
            return []
        }
        return repository.nested
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let repository = viewModel.repository, GitRepositoryMenu.isShown(for: repository) {
                GitRepositoryMenu(viewModel: viewModel, repository: repository, palette: palette)
            }
            if let head = viewModel.head {
                GitHistoryHeaderView(viewModel: viewModel, head: head, palette: palette)
            }
            if let message = viewModel.status.message {
                emptyState(message)
            } else if viewModel.status == .ready {
                GitHistoryOutlineView(viewModel: viewModel, palette: palette, actionHandler: actionHandler)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func emptyState(_ message: String) -> some View {
        let choices = Self.choices(status: viewModel.status, repository: viewModel.repository)
        if let repository = viewModel.repository, !choices.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: palette.secondaryText))
                    GitRepositoryChoiceList(viewModel: viewModel, repository: repository, choices: choices, palette: palette)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
