import AppKit
import SwiftUI

/// Git History's content inside its sidebar section: the header, then the
/// commit log or the empty state that explains why there is none.
public struct GitHistoryPanelView: View {
    @ObservedObject private var viewModel: GitHistoryViewModel
    private let palette: GitHistoryPalette

    public init(viewModel: GitHistoryViewModel, palette: GitHistoryPalette) {
        self.viewModel = viewModel
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let head = viewModel.head {
                GitHistoryHeaderView(head: head, palette: palette)
            }
            if let message = viewModel.status.message {
                emptyState(message)
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
