import Combine
import Foundation

/// Git History's state for one Explorer Root: the header (Checked-out
/// Branch, upstream counts) and why there is nothing to show when there is
/// not. Shaped like `ExplorerViewModel`: `setContext` follows the selected
/// Session, every git read runs off the main thread, and a generation
/// counter discards results that belong to a root no longer shown.
@MainActor
public final class GitHistoryViewModel: ObservableObject {
    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var status: GitHistoryStatus = .noSession
    @Published public private(set) var head: GitHead?

    private let services: GitHistoryServices
    /// Bumped on every context change; a read that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private var generation = 0

    public init(services: GitHistoryServices = .live) {
        self.services = services
    }

    /// The Explorer Root git reads run in, when there is one.
    public var root: String? {
        guard case .local(let root, _) = context else { return nil }
        return root
    }

    // MARK: - Context

    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return Task {} }
        generation += 1
        context = next
        head = nil
        status = Self.initialStatus(for: next)
        let current = generation
        return Task { await self.load(generation: current) }
    }

    /// Re-reads everything for the current root, keeping what is shown
    /// until the new results arrive.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let current = generation
        return Task { await self.load(generation: current) }
    }

    private static func initialStatus(for context: ExplorerContext) -> GitHistoryStatus {
        switch context {
        case .none: return .noSession
        case .remote: return .remote
        case .local: return .loading
        }
    }

    // MARK: - Loading

    private func load(generation current: Int) async {
        guard current == generation, let root else { return }
        let readHead = services.head
        let result = await Task.detached(priority: .userInitiated) { readHead(root) }.value
        guard current == generation else { return }
        switch result {
        case .success(let read):
            head = read
            status = read.hasCommits ? .ready : .noCommits
        case .failure(let failure):
            head = nil
            status = GitHistoryStatus(failure)
        }
    }
}
