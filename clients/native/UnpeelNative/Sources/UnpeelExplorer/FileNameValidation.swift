import Foundation

public struct FileNameIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// Blocks committing the name.
        case error
        /// Shown, but the name can still be committed.
        case warning
    }

    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// VS Code's `validateFileName` / `isValidBasename` for macOS
/// (`src/vs/workbench/contrib/files/browser/fileActions.ts`), with two
/// deliberate differences: only `/` separates segments (a backslash is a
/// legal macOS file-name character), and a rename may not contain a slash
/// at all, so renaming never moves an item to another folder.
public enum FileNameValidation {
    public enum Purpose: Equatable, Sendable {
        /// New File / New Folder: a relative path whose missing folders are
        /// created.
        case create
        case rename(currentName: String)
    }

    /// APFS and HFS+ limit a name to 255 UTF-8 bytes.
    static let maximumSegmentBytes = 255

    /// Tabs trimmed from both ends and trailing slashes removed, as VS Code's
    /// `getWellFormedFileName` does before validating or creating.
    public static func wellFormed(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// The most important issue with `name`, or nil when it can be used.
    /// `isTaken` answers whether a well-formed name already exists in the
    /// destination folder; it is not consulted for a rename to the item's
    /// own name.
    public static func validate(
        _ name: String,
        purpose: Purpose,
        isTaken: (String) -> Bool
    ) -> FileNameIssue? {
        let name = wellFormed(name)
        if name.isEmpty || name.allSatisfy(\.isWhitespace) {
            return error("A file or folder name must be provided.")
        }
        if name.hasPrefix("/") {
            return error("A file or folder name cannot start with a slash.")
        }
        if case .rename = purpose, name.contains("/") {
            return error("A file or folder name cannot contain a slash.")
        }
        if isRenameToOwnName(name, purpose) == false, isTaken(name) {
            return error("A file or folder “\(name)” already exists at this location. Please choose a different name.")
        }
        let segments = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.contains(where: { !isValidSegment($0) }) {
            return error("The name “\(name)” is not valid as a file or folder name. Please choose a different name.")
        }
        if segments.contains(where: hasOuterWhitespace) {
            return FileNameIssue(
                severity: .warning, message: "Leading or trailing whitespace detected in file or folder name."
            )
        }
        return nil
    }

    private static func isRenameToOwnName(_ name: String, _ purpose: Purpose) -> Bool {
        if case .rename(let currentName) = purpose { return name == currentName }
        return false
    }

    static func isValidSegment(_ segment: String) -> Bool {
        !segment.isEmpty
            && !segment.allSatisfy(\.isWhitespace)
            && segment != "." && segment != ".."
            && !segment.contains("\u{0}")
            && segment.utf8.count <= maximumSegmentBytes
    }

    private static func hasOuterWhitespace(_ segment: String) -> Bool {
        guard let first = segment.first, let last = segment.last else { return false }
        return first.isWhitespace || last.isWhitespace
    }

    private static func error(_ message: String) -> FileNameIssue {
        FileNameIssue(severity: .error, message: message)
    }
}
