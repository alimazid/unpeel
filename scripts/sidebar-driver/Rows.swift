import AppKit
import ApplicationServices

struct Row {
    let label: String
    let frame: CGRect
}

/// The PROJECTS rows on screen, top to bottom: one per title text.
func readRows() -> [Row] {
    guard let window = mainWindow(), let area = firstScrollArea(in: window),
          let visible = frame(of: area) else { return [] }
    var rows: [Row] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        if (attribute(element, kAXRoleAttribute) as? String) == "AXStaticText",
           let text = (attribute(element, kAXValueAttribute) as? String)
           ?? (attribute(element, kAXTitleAttribute) as? String),
           text != "›", !text.isEmpty, let rect = frame(of: element),
           rect.midY > visible.minY, rect.midY < visible.maxY {
            rows.append(Row(label: text, frame: rect))
        }
        guard depth < 14 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth + 1)
        }
    }
    walk(area, 0)
    return rows.sorted { $0.frame.midY < $1.frame.midY }
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
