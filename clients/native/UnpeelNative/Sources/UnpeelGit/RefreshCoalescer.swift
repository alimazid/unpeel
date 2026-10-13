import Foundation

/// Fork-only: git support. Turns a burst of refresh requests into as few
/// runs as possible: the first request waits `debounce`, then runs the
/// work; requests while it waits or runs cost at most one more run, never
/// one each. `reset` drops what is pending — a loop already running stops
/// after its current run — for when what the work refreshes is gone (a new
/// root, a hidden view). The work given with the request that starts a
/// loop serves the whole burst.
@MainActor
public final class RefreshCoalescer {
    /// How long a change waits for more before the git views refresh.
    public nonisolated static let defaultDebounce: TimeInterval = 0.2

    private var pending = false
    private var running: Task<Void, Never>?
    /// Bumped by `reset`; a loop started before it stops.
    private var epoch = 0

    public init() {}

    /// The loop serving requests, while one runs.
    public var current: Task<Void, Never>? { running }

    @discardableResult
    public func request(debounce: TimeInterval, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        pending = true
        if let running { return running }
        let started = epoch
        let task = Task {
            if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000)) }
            while self.pending, started == self.epoch {
                self.pending = false
                await work()
            }
            if started == self.epoch { self.running = nil }
        }
        running = task
        return task
    }

    public func reset() {
        epoch += 1
        pending = false
        running = nil
    }
}
