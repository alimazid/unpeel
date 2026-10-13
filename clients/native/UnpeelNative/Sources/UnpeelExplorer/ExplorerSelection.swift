import Foundation

/// Fork-only: explorer operations. Pure selection rules for File Operations.
enum ExplorerSelection {
    /// The row to select once `removed` leave the tree, as VS Code does: the
    /// first row after the last removed one that is not going too, else the
    /// nearest row before the first one, else nothing. `rows` are the
    /// visible entry rows in order.
    static func afterRemoving(_ removed: [String], rows: [String]) -> String? {
        let gone: (String) -> Bool = { row in
            removed.contains { row == $0 || row.hasPrefix($0 + "/") }
        }
        let indices = rows.indices.filter { gone(rows[$0]) }
        guard let first = indices.first, let last = indices.last else { return nil }
        if let after = rows[(last + 1)...].first(where: { !gone($0) }) { return after }
        return rows[..<first].last(where: { !gone($0) })
    }
}
