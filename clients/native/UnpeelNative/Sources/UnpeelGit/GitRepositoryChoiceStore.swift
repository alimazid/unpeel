import Foundation

/// Fork-only: nested repositories. What the user chose for an Explorer
/// Root that is not a repository.
public enum GitRepositoryChoice: Codable, Equatable, Sendable {
    /// The folder itself: no nested repository, not even a lone one.
    case folder
    /// A nested repository, by its path within the Explorer Root.
    case repository(String)
}

/// Fork-only: nested repositories. The choice remembered per Explorer Root
/// (by real path), bounded like the EXPLORER's view state so a long-lived
/// install does not keep one for every folder ever browsed.
@MainActor
public final class GitRepositoryChoiceStore {
    public static let maxRoots = 50

    private static let key = "unpeel.git.repositoryChoices"

    private struct StoredChoice: Codable {
        let choice: GitRepositoryChoice
        let lastUsed: Double
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func choice(forRoot root: String) -> GitRepositoryChoice? {
        load()[root]?.choice
    }

    public func save(_ choice: GitRepositoryChoice, forRoot root: String, now: Date = Date()) {
        let updated = load().merging([root: StoredChoice(choice: choice, lastUsed: now.timeIntervalSince1970)]) { _, new in new }
        let kept = updated.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(Self.maxRoots)
        let bounded = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func load() -> [String: StoredChoice] {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: StoredChoice].self, from: data)
        else { return [:] }
        return stored
    }
}
