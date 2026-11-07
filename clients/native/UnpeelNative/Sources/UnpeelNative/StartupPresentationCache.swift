import Foundation

/// A disposable Controller display cache, never a source of Host lifecycle or
/// authorization. One bounded file avoids opening every manifest before paint.
struct StartupPresentation: Codable, Equatable, Sendable {
    var version = 1
    let home: String
    let hostID: String
    let nodes: [ProjectNode]
    let pins: [String: [PinnedSidebarSession]]
    let unreadIDs: Set<String>
    /// Fork-only: Scheduled Tasks. The Run Sessions the Host last called
    /// superseded, so the disk seed hides them too
    /// (`ScheduledRunListing.seeding`). Absent in an older cache.
    var supersededRunIDs: Set<String>? = nil
    /// Fork-only: the stopped Runs the Host last said kept output, so the
    /// disk seed shows their kept output too (ADR 0006). Absent in an older
    /// cache.
    var keptOutputRunIDs: Set<String>? = nil
}

final class StartupPresentationCache: Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    let fileURL: URL
    private let writer = DispatchQueue(label: "unpeel.startup-presentation", qos: .utility)

    init(home: URL) {
        fileURL = home.appendingPathComponent("native-startup-cache.json")
    }

    func load(home: String, hostID: String) -> StartupPresentation? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes,
              let value = try? JSONDecoder().decode(StartupPresentation.self, from: data),
              value.version == 1, value.home == home, value.hostID == hostID
        else { return nil }
        return value
    }

    func save(_ value: StartupPresentation) {
        writer.async { [fileURL] in
            guard let data = try? JSONEncoder().encode(value),
                  data.count <= Self.maximumBytes else { return }
            // Whole-file replacement on one queue: no shared read/modify/write
            // state, and no notification channel. Only this Controller reads it.
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }
}
