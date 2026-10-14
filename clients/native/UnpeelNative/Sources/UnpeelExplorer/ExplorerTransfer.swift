import Foundation

/// Fork-only: explorer operations. A Transfer: a large paste or drop while
/// it copies — what the EXPLORER's progress row shows, and its Cancel.
@MainActor
public final class ExplorerTransfer: ObservableObject, Identifiable {
    /// A copy that ends within this (a clone on one volume is instant)
    /// never shows a row, so it cannot flash.
    static let showDelay: Duration = .milliseconds(300)
    static let refreshInterval: Duration = .milliseconds(100)

    public let id = UUID()
    /// The Explorer Root it copies into; its row shows only there.
    public let root: String
    public let title: String
    public let total: TransferSize
    @Published public private(set) var done = TransferSize.zero
    @Published public private(set) var isShown = false
    @Published public private(set) var isCancelling = false
    nonisolated let progress = TransferProgress()

    init(root: String, plan: TransferPlan) {
        self.root = root
        total = plan.copySize
        title = Self.heading(for: plan)
    }

    public func cancel() {
        isCancelling = true
        progress.cancel()
    }

    /// 0…1, by bytes when there are any, else by items.
    public var fraction: Double {
        if total.bytes > 0 { return min(1, Double(done.bytes) / Double(total.bytes)) }
        return total.items > 0 ? min(1, Double(done.items) / Double(total.items)) : 0
    }

    /// "120 of 1,034 items — 1.2 GB of 5.4 GB".
    public var detail: String {
        let items = "\(Self.count(min(done.items, total.items))) of \(Self.count(total.items)) items"
        guard total.bytes > 0 else { return items }
        return "\(items) — \(Self.bytes(min(done.bytes, total.bytes))) of \(Self.bytes(total.bytes))"
    }

    /// Shows the row after `showDelay`, then follows the copy until the
    /// returned task is cancelled.
    func follow() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.showDelay)
            while let self, !Task.isCancelled {
                self.isShown = true
                self.done = self.progress.done
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private static func heading(for plan: TransferPlan) -> String {
        let verb = plan.kind == .move ? "Moving" : "Copying"
        guard plan.itemCount == 1, let item = plan.entries.first?.item else {
            return "\(verb) \(count(plan.itemCount)) items"
        }
        return "\(verb) “\((item as NSString).lastPathComponent)”"
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
