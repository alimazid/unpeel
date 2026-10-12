import AppKit
import SwiftUI

/// Git History's content inside its sidebar section: the header, then the
/// commit log or the empty state that explains why there is none.
public struct GitHistoryPanelView: View {
    @ObservedObject private var viewModel: GitHistoryViewModel
    private let palette: GitHistoryPalette
    private let actionHandler: (any GitHistoryActionHandler)?

    public init(viewModel: GitHistoryViewModel, palette: GitHistoryPalette, actionHandler: (any GitHistoryActionHandler)?) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(Color(nsColor: palette.secondaryText))
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
