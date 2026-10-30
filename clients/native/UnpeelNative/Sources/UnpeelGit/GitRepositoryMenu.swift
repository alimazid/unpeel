import AppKit
import SwiftUI

/// Fork-only: nested repositories. The strip above Git History's header in
/// an Explorer Root that is not a repository: which nested repository the
/// history and the EXPLORER's git colours follow, and the menu to pick
/// another, or none.
struct GitRepositoryMenu: View {
    static let noneTitle = "No repository"
    static let noneChoice = "None"

    @ObservedObject var viewModel: GitHistoryViewModel
    let repository: GitRepositoryRootState
    let palette: GitHistoryPalette

    /// Only a folder that is not a repository, with nested ones to offer.
    static func isShown(for repository: GitRepositoryRootState?) -> Bool {
        guard let repository else { return false }
        return repository.canChoose && !repository.nested.isEmpty
    }

    static func title(for repository: GitRepositoryRootState) -> String {
        repository.chosen.map(repository.name(of:)) ?? noneTitle
    }

    var body: some View {
        Menu {
            ForEach(repository.nested, id: \.self) { path in
                choice(repository.name(of: path), path)
            }
            Divider()
            choice(Self.noneChoice, nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(Self.title(for: repository))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("The repository in this folder that Git History and the EXPLORER's git colours follow")
        .foregroundColor(Color(nsColor: palette.secondaryText))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: GitHistoryMetrics.headerHeight)
    }

    private func choice(_ title: String, _ path: String?) -> some View {
        Toggle(title, isOn: Binding(
            get: { repository.chosen == path },
            set: { chosen in if chosen { viewModel.chooseRepository(path) } }
        ))
    }
}

/// Fork-only: nested repositories. The nested repositories offered under
/// "This folder is not a git repository.", one button each.
struct GitRepositoryChoiceList: View {
    @ObservedObject var viewModel: GitHistoryViewModel
    let repository: GitRepositoryRootState
    let choices: [String]
    let palette: GitHistoryPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Show the history of a repository in it:")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .padding(.bottom, 4)
            ForEach(choices, id: \.self) { path in
                Button {
                    viewModel.chooseRepository(path)
                } label: {
                    Label(repository.name(of: path), systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: palette.text))
                .padding(.vertical, 2)
            }
        }
    }
}
