import Foundation

/// Everything `GitHistoryViewModel` asks of the outside world, injectable so
/// tests control results and timing. Every read is called off the main
/// thread.
public struct GitHistoryServices: Sendable {
    public typealias Head = @Sendable (_ root: String) -> GitReadResult<GitHead>

    public let head: Head

    public init(head: @escaping Head) {
        self.head = head
    }

    /// Services backed by a real reader.
    public static func reading(_ reader: GitReader) -> GitHistoryServices {
        GitHistoryServices(head: { reader.head(at: $0) })
    }

    public static let live = reading(GitReader())
}
