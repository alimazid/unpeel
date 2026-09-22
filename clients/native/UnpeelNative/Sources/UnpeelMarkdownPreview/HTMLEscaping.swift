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

    static func escapeAttribute(_ value: String) -> String {
        escape(value)
    }
}
