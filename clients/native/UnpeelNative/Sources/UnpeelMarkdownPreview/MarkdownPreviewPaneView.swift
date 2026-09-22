import SwiftUI
// Fork-only: markdown preview pane
import os

/// Pane body: a slim toolbar (file name, Edit) above the rendered document.
/// The pane header itself belongs to the app; this view owns only what is
/// specific to previews. Reloads on disk changes; shows a notice once the
/// file is gone (the app drops the pane on its next validation).
public struct MarkdownPreviewPaneView: View {
    // Fork-only: markdown preview pane
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "preview-pane")

    public let path: String
    public let projectRoot: String
    public let onEdit: () -> Void
    public let onActivate: () -> Void
    public let onEscape: () -> Void
    public let onOpenMarkdown: (String) -> Void

    @State private var reloadToken = 0
    @State private var observer: MarkdownFileObserver?
    @State private var missing = false

    public init(
        path: String,
        projectRoot: String,
        onEdit: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onOpenMarkdown: @escaping (String) -> Void
    ) {
        self.path = path
        self.projectRoot = projectRoot
        self.onEdit = onEdit
        self.onActivate = onActivate
        self.onEscape = onEscape
        self.onOpenMarkdown = onOpenMarkdown
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit", action: onEdit)
                    .controlSize(.small)
                    .help("Open in the Markdown plugin")
                    .accessibilityIdentifier("markdown-preview-edit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            if missing {
                Text("\((path as NSString).lastPathComponent) is no longer available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPreviewWebView(
                    path: path,
                    projectRoot: projectRoot,
                    reloadToken: reloadToken,
                    onActivate: onActivate,
                    onEscape: onEscape,
                    onOpenMarkdown: handleOpenMarkdown
                )
            }
        }
        .onAppear(perform: startObserving)
        .onDisappear { observer?.stop(); observer = nil }
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = MarkdownFileObserver(path: path) {
            if FileManager.default.fileExists(atPath: path) {
                missing = false
                reloadToken += 1
            } else {
                missing = true
            }
        }
        observer.start()
        self.observer = observer
    }

    // Fork-only: markdown preview pane — I2: confine the web view's link
    // target to the project root before it ever reaches the app's pane
    // model; a nil result means the link resolved outside the root, to a
    // non-markdown resource, or to a directory, and is silently ignored.
    private func handleOpenMarkdown(_ requestPath: String) {
        guard let target = PreviewResourcePolicy(projectRoot: projectRoot).documentPath(for: requestPath) else {
            Self.logger.info("in-page markdown link refused \(requestPath, privacy: .private)")
            return
        }
        onOpenMarkdown(target)
    }
}
