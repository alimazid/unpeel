import AppKit
import SwiftUI

/// The strip at the top of Git History: the History Branch Filter on the
/// left; on the right the Checked-out Branch's ahead/behind counts against
/// its upstream as of the last fetch (and its name, when the filter shows
/// another branch).
struct GitHistoryHeaderView: View {
    @ObservedObject var viewModel: GitHistoryViewModel
    let head: GitHead
    let palette: GitHistoryPalette

    var body: some View {
        HStack(spacing: 6) {
            GitHistoryFilterMenu(viewModel: viewModel, head: head)
            Spacer(minLength: 4)
            if viewModel.filter != .checkedOut {
                Text(head.displayName)
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("The Checked-out Branch")
            }
            if let counts = Self.countsText(for: head) {
                Text(counts)
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .fixedSize()
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

/// The History Branch Filter: "All branches", then local branches, then
/// remote-tracking branches under a separator. A detached HEAD is offered
/// as its own `detached@…` entry, the default.
struct GitHistoryFilterMenu: View {
    @ObservedObject var viewModel: GitHistoryViewModel
    let head: GitHead

    var body: some View {
        Menu {
            choice(GitHistoryFilter.allBranchesTitle, .allBranches)
            Divider()
            if head.isDetached {
                choice(head.displayName, .checkedOut)
            }
            ForEach(viewModel.localBranches) { ref in
                choice(ref.name, .branch(ref))
            }
            if !viewModel.remoteBranches.isEmpty {
                Divider()
                ForEach(viewModel.remoteBranches) { ref in
                    choice(ref.name, .branch(ref))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: head.isDetached && viewModel.filter == .checkedOut
                    ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(viewModel.filterTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("History Branch Filter: which branch's commits to list")
    }

    private func choice(_ title: String, _ filter: GitHistoryFilter) -> some View {
        Toggle(title, isOn: Binding(
            get: { viewModel.isChosen(filter) },
            set: { chosen in if chosen { viewModel.selectFilter(filter) } }
        ))
    }
}

enum GitHistoryMetrics {
    static let headerHeight: CGFloat = 26
}
