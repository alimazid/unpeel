import Foundation

/// Everything `GitHistoryViewModel` asks of the outside world, injectable so
/// tests control results and timing. Every read is called off the main
/// thread.
public struct GitHistoryServices: Sendable {
    public typealias Head = @Sendable (_ root: String) -> GitReadResult<GitHead>
    public typealias LogPage = @Sendable (
        _ root: String, _ scope: GitLogScope, _ offset: Int, _ limit: Int
    ) -> GitReadResult<GitLogPage>

    public let head: Head
    public let logPage: LogPage

    public init(head: @escaping Head, logPage: @escaping LogPage) {
        self.head = head
        self.logPage = logPage
    }

    /// Services backed by a real reader.
    public static func reading(_ reader: GitReader) -> GitHistoryServices {
        GitHistoryServices(
            head: { reader.head(at: $0) },
            logPage: { reader.logPage(at: $0, scope: $1, offset: $2, limit: $3) }
        )
    }

    public static let live = reading(GitReader())
}
