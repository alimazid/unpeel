import AppKit

func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < end
    return condition()
}

func press(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + 6, y: rect.midY) }
func labels(_ rows: [Row]) -> [String] { rows.map(\.label) }
/// Each row with its indent, for a failure report.
func layout(_ rows: [Row]) -> String {
    let left = rows.map(\.frame.minX).min() ?? 0
    return rows.map { "\(summary([$0.label]))@\(Int($0.frame.minX - left))" }.joined(separator: " ")
}
func summary(_ names: [String]) -> String {
    names.map { $0.replacingOccurrences(of: "~/w/Big/", with: "") }.joined(separator: " ")
}

/// Whether `first` comes before `second`; nil unless the list has both.
func isAbove(_ first: String, _ second: String, in order: [String]) -> Bool? {
    guard let one = order.firstIndex(of: first), let two = order.firstIndex(of: second) else { return nil }
    return one < two
}

/// The rows' positions, to compare two moments of one drag.
func positions(_ rows: [Row]) -> [String: CGFloat] {
    Dictionary(rows.map { ($0.label, $0.frame.minY) }, uniquingKeysWith: { first, _ in first })
}

/// Rows of `before` that sit elsewhere in `now`. A row gone from `now` isn't one.
func movedRows(_ names: [String], from before: [String: CGFloat], to now: [String: CGFloat]) -> [String] {
    names.filter { name in
        guard let was = before[name], let current = now[name] else { return false }
        return abs(was - current) > 2
    }
}

func setExpanded(_ group: String, children: [String], _ expanded: Bool) {
    let rows = readRows()
    guard Set(labels(rows)).isSuperset(of: children) != expanded,
          let header = rows.first(where: { $0.label == group }) else { return }
    click(press(header.frame))
    Thread.sleep(forTimeInterval: 0.8)
}
