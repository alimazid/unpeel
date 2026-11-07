//
//  KeptOutput.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks (ADR 0006, #36). A stopped Run Session whose
//  output the Host kept shows it, read-only, in its terminal area instead of
//  the stopped placeholder. The bytes come through the selected scope's Host
//  connection (`session.output.read`) in every scope, Local included, so a
//  local and a remote Host take one path and the app never reads another
//  home's journal. The pane is the in-memory Ghostty pane remote Sessions
//  render in, with every callback a no-op: nothing typed, pasted, dropped
//  or resized reaches any Session.
//

import AppKit
import Foundation

/// One tail read of a stopped Session's journal: `GET /mobile/output`
/// without an offset, so no output cursor moves.
struct KeptOutputTail: Decodable, Equatable, Sendable {
    /// The same bounded tail a remote live pane attaches with.
    static let limit = 192 * 1024

    let bytes: Data
    /// Earlier output exists that this tail does not show.
    let truncated: Bool

    init(bytes: Data, truncated: Bool) {
        self.bytes = bytes
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case dataBase64, truncated, offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .dataBase64)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dataBase64,
                in: container,
                debugDescription: "The Host's output bytes are not base64."
            )
        }
        self.bytes = bytes
        let offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? (offset > 0)
    }
}

extension RemoteHostRuntime {
    /// A stopped Session's kept output, through this Host connection.
    func keptOutputTail(sessionID: String) async throws -> KeptOutputTail {
        let data = try await resourceRequest(
            operation: "outputTail",
            capability: "session.output.read",
            parameters: [
                "session_id": sessionID,
                "limit": String(KeptOutputTail.limit),
            ]
        )
        return try JSONDecoder().decode(KeptOutputTail.self, from: data)
    }
}

/// The read-only panes stopped Runs show their kept output in, a few at a
/// time. A pane is fed once; its VT state then stays as drawn while the
/// Run stays stopped, so moving back to it is instant.
@MainActor
final class KeptOutputPanes: ObservableObject {
    /// A stopped Run in one scope. `generation` (the row's lifecycle time)
    /// changes when the Session runs and stops again, so a reloaded Session
    /// never shows a stale tail.
    struct Key: Hashable {
        let scopeID: String
        let sessionID: String
        let generation: Int64?
    }

    /// Shown Runs whose tail leaves earlier output out.
    @Published private(set) var truncatedKeys: Set<Key> = []

    private final class Entry {
        let pane: RemoteGhosttyTerminalPane
        var fed = false
        var loading: Task<Void, Never>?

        init(pane: RemoteGhosttyTerminalPane) {
            self.pane = pane
        }
    }

    /// A just-mounted pane builds its surface on attach; give it this long.
    private static let feedAttempts = 300
    private static let feedRetryNanoseconds: UInt64 = 16_000_000

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    /// The pane for `key`. Its input and resize callbacks are no-ops.
    func pane(for key: Key, style: TerminalPaneStyle) -> RemoteGhosttyTerminalPane {
        recency.removeAll { $0 == key }
        recency.append(key)
        if let entry = entries[key] {
            entry.pane.applyPaneStyle(style)
            return entry.pane
        }
        let pane = RemoteGhosttyTerminalPane(
            style: style,
            onInput: { _ in },
            onResize: { _ in }
        )
        entries[key] = Entry(pane: pane)
        evictOverCapacity()
        return pane
    }

    /// Read the tail through `read` and feed it once the pane is on screen.
    /// A failed read or a pane that never attached is retried on the next
    /// call; a fed pane is never read again.
    func load(_ key: Key, read: @escaping @MainActor () async throws -> KeptOutputTail) {
        guard let entry = entries[key], !entry.fed, entry.loading == nil else { return }
        entry.loading = Task { [weak self, weak entry] in
            defer { entry?.loading = nil }
            let tail: KeptOutputTail
            do {
                tail = try await read()
            } catch is CancellationError {
                return
            } catch {
                NSLog(
                    "[UnpeelNative] kept output for %@ unavailable: %@",
                    key.sessionID,
                    error.localizedDescription
                )
                return
            }
            for _ in 0..<Self.feedAttempts {
                guard !Task.isCancelled, let self, let entry else { return }
                if entry.pane.receiveHostBytes(tail.bytes, resetBeforeFeed: true) {
                    entry.fed = true
                    if tail.truncated { self.truncatedKeys.insert(key) }
                    return
                }
                try? await Task.sleep(nanoseconds: Self.feedRetryNanoseconds)
            }
        }
    }

    func isTruncated(_ key: Key) -> Bool {
        truncatedKeys.contains(key)
    }

    private func evictOverCapacity() {
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            entries.removeValue(forKey: evicted)?.loading?.cancel()
            // Called from a view's body: publish only a real change.
            if truncatedKeys.contains(evicted) { truncatedKeys.remove(evicted) }
        }
    }
}
