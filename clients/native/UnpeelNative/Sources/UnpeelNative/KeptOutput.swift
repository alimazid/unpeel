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
    static let limit = RemoteHostRuntime.outputPageLimit

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
/// time (the remote pane cache's own retention). A tail is read once per
/// stop, ahead of selection on hover, and fed the moment its pane's surface
/// exists, so the first frame already shows it; the VT state then stays as
/// drawn, so moving back is instant.
@MainActor
final class KeptOutputPanes: ObservableObject {
    static let retainedPaneLimit = 4
    /// Tails read ahead of selection (hover) are kept for this many Runs.
    static let retainedTailLimit = 8

    enum Status: Equatable {
        case loading
        case shown(truncated: Bool)
        case unreadable
    }

    /// Bumped when a tail lands, is fed, or fails, so the bar re-renders.
    @Published private(set) var revision = 0

    private struct Tail {
        /// The row's lifecycle time when read: a Session that runs and stops
        /// again is read again rather than showing a stale tail.
        let generation: Int64?
        let tail: KeptOutputTail
    }

    private let cache = RemoteGhosttyPaneCache(retainedPaneLimit: KeptOutputPanes.retainedPaneLimit)
    private var tails: [RemoteTerminalPaneKey: Tail] = [:]
    private var tailOrder: [RemoteTerminalPaneKey] = []
    private var fed: [RemoteTerminalPaneKey: Int64?] = [:]
    private var reading: [RemoteTerminalPaneKey: (generation: Int64?, task: Task<Void, Never>)] = [:]
    private var unreadable: Set<RemoteTerminalPaneKey> = []

    /// The pane for a stopped Run in one scope. Its input and resize
    /// callbacks are no-ops. Safe to call from a view's body: it publishes
    /// nothing.
    func pane(for key: RemoteTerminalPaneKey, style: TerminalPaneStyle) -> RemoteGhosttyTerminalPane {
        let pane = cache.pane(
            for: key,
            style: style,
            onInput: { _ in },
            onResize: { _ in }
        )
        pane.onSurfaceAttached = { [weak self] in self?.feedIfReady(key) }
        cache.prune(keeping: Set(fed.keys).union([key]), selectedKey: key)
        fed = fed.filter { cache.existingPane(for: $0.key) != nil }
        return pane
    }

    /// Read the Run's tail (unless this stop's is already read) and feed it
    /// as soon as its pane can take it. Called on hover and on selection; a
    /// failed read is tried again on the next call.
    func load(
        _ key: RemoteTerminalPaneKey,
        generation: Int64?,
        read: @escaping @MainActor () async throws -> KeptOutputTail
    ) {
        if tails[key]?.generation == generation {
            feedIfReady(key)
            return
        }
        if let current = reading[key] {
            guard current.generation != generation else { return }
            current.task.cancel()
        }
        let task = Task { [weak self] in
            let result: Result<KeptOutputTail, Error>
            do {
                result = .success(try await read())
            } catch {
                result = .failure(error)
            }
            self?.finishRead(key, generation: generation, result: result)
        }
        reading[key] = (generation, task)
    }

    func status(_ key: RemoteTerminalPaneKey, generation: Int64?) -> Status {
        if let tail = tails[key], tail.generation == generation {
            return .shown(truncated: tail.tail.truncated)
        }
        return unreadable.contains(key) ? .unreadable : .loading
    }

    private func finishRead(
        _ key: RemoteTerminalPaneKey,
        generation: Int64?,
        result: Result<KeptOutputTail, Error>
    ) {
        guard reading[key]?.generation == generation else { return }
        reading.removeValue(forKey: key)
        switch result {
        case let .success(tail):
            unreadable.remove(key)
            tails[key] = Tail(generation: generation, tail: tail)
            tailOrder.removeAll { $0 == key }
            tailOrder.append(key)
            while tailOrder.count > Self.retainedTailLimit {
                tails.removeValue(forKey: tailOrder.removeFirst())
            }
            feedIfReady(key)
        case let .failure(error):
            if error is CancellationError { return }
            NSLog(
                "[UnpeelNative] kept output for %@ unavailable: %@",
                key.sessionID,
                error.localizedDescription
            )
            unreadable.insert(key)
        }
        revision &+= 1
    }

    /// Feed the read tail into its pane once: a no-op until both exist, and
    /// for a pane already showing this stop's tail.
    private func feedIfReady(_ key: RemoteTerminalPaneKey) {
        guard let tail = tails[key],
              fed[key] != .some(tail.generation),
              let pane = cache.existingPane(for: key),
              pane.receiveHostBytes(tail.tail.bytes, resetBeforeFeed: true)
        else { return }
        fed[key] = .some(tail.generation)
    }
}
