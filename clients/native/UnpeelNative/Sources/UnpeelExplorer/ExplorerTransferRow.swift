import AppKit
import SwiftUI

/// Fork-only: explorer operations. A Transfer's progress row at the top of
/// the EXPLORER: what it copies, items and bytes, and Cancel. Nothing
/// until the Transfer has run for a moment, so a quick one never flashes.
struct ExplorerTransferRow: View {
    @ObservedObject var transfer: ExplorerTransfer
    let palette: ExplorerPalette

    var body: some View {
        if transfer.isShown {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transfer.isCancelling ? "Cancelling…" : transfer.title)
                        .foregroundColor(Color(nsColor: palette.text))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        transfer.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(nsColor: palette.secondaryText))
                    }
                    .buttonStyle(.borderless)
                    .disabled(transfer.isCancelling)
                    .help("Cancel")
                    .accessibilityLabel("Cancel")
                }
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text(transfer.detail)
                    .foregroundColor(Color(nsColor: palette.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(transfer.title)
        }
    }
}
