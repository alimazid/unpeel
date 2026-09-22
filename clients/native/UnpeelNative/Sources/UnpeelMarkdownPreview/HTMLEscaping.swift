import Foundation

enum HTMLEscaping {
    /// Text content: `&`, `<`, `>` (quotes are harmless in text but escaped
    /// too so attribute and text escaping never diverge in tests).
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // Fork-only: markdown preview pane — M10: `escape` alone leaves `'`
    // unescaped, which is harmless inside a double-quoted attribute value
    // right up until something double-quotes an attribute built from
    // untrusted input elsewhere; escape it here too so the name matches
    // what it does.
    static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}
