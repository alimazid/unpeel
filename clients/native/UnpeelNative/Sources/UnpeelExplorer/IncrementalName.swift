import Foundation

/// VS Code's "simple" `incrementFileName`: `a.txt` → `a copy.txt` →
/// `a copy 2.txt`. Used by Duplicate, a copy pasted into its own folder,
/// and Keep Both.
public enum IncrementalName {
    public static func next(_ name: String, isFolder: Bool) -> String {
        let suffix = isFolder ? "" : fileExtension(of: name)
        let stem = String(name.dropLast(suffix.count))
        guard let numbered = incrementedCopy(stem) else { return "\(stem) copy\(suffix)" }
        return numbered + suffix
    }

    /// The first name in the `next` sequence that `isTaken` does not claim.
    public static func available(for name: String, isFolder: Bool, isTaken: (String) -> Bool) -> String {
        var candidate = next(name, isFolder: isFolder)
        while isTaken(candidate) {
            candidate = next(candidate, isFolder: isFolder)
        }
        return candidate
    }

    /// `name copy` → `name copy 2`, `name copy 5` → `name copy 6`,
    /// `name copy 0` → `name copy`; nil when `stem` is not a copy.
    private static func incrementedCopy(_ stem: String) -> String? {
        if stem.count > " copy".count, stem.hasSuffix(" copy") {
            return "\(stem) 2"
        }
        guard let space = stem.lastIndex(of: " ") else { return nil }
        let digits = stem[stem.index(after: space)...]
        let base = stem[..<space]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              base.count > " copy".count, base.hasSuffix(" copy"), let number = Int(digits)
        else { return nil }
        return number == 0 ? String(base) : "\(base) \(number + 1)"
    }

    /// Node's `path.extname` for the names that matter here: from the last
    /// dot, unless everything before that dot is dots (`.env` has none).
    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), name[..<dot].contains(where: { $0 != "." }) else { return "" }
        return String(name[dot...])
    }
}
