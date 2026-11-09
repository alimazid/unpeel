import Foundation

/// Fork-only (#57): the branch each checkout on this Mac has out, keyed by path.
/// The pooled page and the live branch mark both read it, so the commit swap
/// has no gap, and neither touches the disk: HEAD files are read here, off the
/// main thread, when a local workspace's project list changes. `git symbolic-ref`
/// (`refreshTitlebarBranch`) answers into it too, and outranks a HEAD file that
/// names nothing, such as a reftable repo's stub.
@MainActor
final class LocalCheckoutBranches {
    private struct Entry {
        var name: String?
        /// When `git` gave this name, on `clock`. Nil for a name from a HEAD file.
        var gitAnsweredAt: UInt64?
    }

    /// Moves only when a name changes: the pooled page's memo keys on it, so
    /// reading the same name again costs nothing.
    private(set) var nameGeneration = 0

    private var entries: [String: Entry] = [:]
    /// Orders reads against `git`'s answers. A read that started before an
    /// answer knows less than that answer, however late it lands.
    private var clock: UInt64 = 0
    private let read: @Sendable (String) -> String?
    /// One queue: a stalled volume holds back later reads and nothing else.
    private let queue = DispatchQueue(label: "unpeel.local-checkout-branches", qos: .utility)

    init(read: @escaping @Sendable (String) -> String?) {
        self.read = read
    }

    func branch(atPath path: String) -> String? {
        entries[path]?.name
    }

    func refresh(paths: Set<String>) {
        clock += 1
        let startedAt = clock
        let read = read
        queue.async { [weak self] in
            let names = paths.map { (path: $0, name: read($0)) }
            DispatchQueue.main.async {
                self?.apply(names, startedAt: startedAt)
            }
        }
    }

    func noteGitAnswer(_ name: String?, atPath path: String) {
        clock += 1
        write(Entry(name: name, gitAnsweredAt: clock), atPath: path)
    }

    private func apply(_ names: [(path: String, name: String?)], startedAt: UInt64) {
        for (path, name) in names {
            if let answeredAt = entries[path]?.gitAnsweredAt, answeredAt > startedAt || name == nil {
                continue
            }
            write(Entry(name: name, gitAnsweredAt: nil), atPath: path)
        }
    }

    private func write(_ entry: Entry, atPath path: String) {
        if entries[path]?.name != entry.name {
            nameGeneration += 1
        }
        entries[path] = entry
    }
}
