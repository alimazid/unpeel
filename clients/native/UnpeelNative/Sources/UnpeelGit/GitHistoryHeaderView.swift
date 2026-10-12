import AppKit
import SwiftUI

/// The strip at the top of Git History: the Checked-out Branch and its
/// ahead/behind counts against the upstream as of the last fetch.
struct GitHistoryHeaderView: View {
    let head: GitHead
    let palette: GitHistoryPalette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: head.isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
            Text(head.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let counts = Self.countsText(for: head) {
                Text(counts)
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .help(Self.countsHelp(for: head) ?? "")
            }
        }
        .foregroundColor(Color(nsColor: palette.secondaryText))
        .padding(.horizontal, 10)
        .frame(height: GitHistoryMetrics.headerHeight)
    }

    /// `↑ahead ↓behind`, or nil when the branch has no usable upstream (no
    /// counts rather than zeros, so "nothing to push" is never claimed).
    static func countsText(for head: GitHead) -> String? {
        guard let ahead = head.ahead, let behind = head.behind else { return nil }
        return "↑\(ahead) ↓\(behind)"
    }

    static func countsHelp(for head: GitHead) -> String? {
        guard let ahead = head.ahead, let behind = head.behind, let upstream = head.upstream else { return nil }
        return "\(head.displayName) is \(ahead) ahead of and \(behind) behind \(upstream), as of the last fetch."
    }
}

enum GitHistoryMetrics {
    static let headerHeight: CGFloat = 26
}
