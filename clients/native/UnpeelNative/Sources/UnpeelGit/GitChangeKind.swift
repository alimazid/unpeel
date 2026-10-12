import AppKit

/// A file's git change, with the letter and colour VS Code uses for it.
/// The one source for both Git History's changed files and the EXPLORER's
/// Git Status Decorations.
public enum GitChangeKind: String, CaseIterable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    /// VS Code's letters (`extensions/git/src/repository.ts`,
    /// `Resource.getStatusLetter`); a conflict is `!`.
    public var letter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    /// VS Code's git decoration colours (`extensions/git/package.json`,
    /// `contributes.colors`), light and dark defaults. Mapping as in
    /// `Resource.getStatusColor`: copies and renames share the renamed
    /// colour, a type change the modified one.
    public var color: NSColor {
        switch self {
        case .added: return Palette.added
        case .modified, .typeChanged: return Palette.modified
        case .deleted: return Palette.deleted
        case .renamed, .copied: return Palette.renamed
        case .untracked: return Palette.untracked
        case .conflicted: return Palette.conflicting
        }
    }

    /// One instance per colour, so every view shares the same object.
    private enum Palette {
        // gitDecoration.addedResourceForeground
        static let added = dynamic(light: 0x587C0C, dark: 0x81B88B)
        // gitDecoration.modifiedResourceForeground
        static let modified = dynamic(light: 0x895503, dark: 0xE2C08D)
        // gitDecoration.deletedResourceForeground
        static let deleted = dynamic(light: 0xAD0707, dark: 0xC74E39)
        // gitDecoration.renamedResourceForeground
        static let renamed = dynamic(light: 0x007100, dark: 0x73C991)
        // gitDecoration.untrackedResourceForeground
        static let untracked = dynamic(light: 0x007100, dark: 0x73C991)
        // gitDecoration.conflictingResourceForeground
        static let conflicting = dynamic(light: 0xAD0707, dark: 0xE4676B)
    }

    /// Which state wins when one path has two (staged and unstaged), and
    /// which a folder carries for its descendants: conflict > deleted >
    /// modified > type change > renamed > copied > added > untracked. A
    /// file renamed or added and then edited therefore reads as modified.
    public var precedence: Int {
        switch self {
        case .untracked: return 0
        case .added: return 1
        case .copied: return 2
        case .renamed: return 3
        case .typeChanged: return 4
        case .modified: return 5
        case .deleted: return 6
        case .conflicted: return 7
        }
    }

    public static func strongest(_ lhs: GitChangeKind, _ rhs: GitChangeKind) -> GitChangeKind {
        rhs.precedence > lhs.precedence ? rhs : lhs
    }

    /// One side (`X` staged or `Y` unstaged) of a `git status --porcelain`
    /// code; `.` (unchanged) and anything unknown are nil.
    init?(statusCode: Character) {
        switch statusCode {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: return nil
        }
    }

    /// `diff-tree --name-status` letters (similarity scores dropped).
    init?(nameStatus: Substring) {
        guard let letter = nameStatus.first else { return nil }
        self.init(statusCode: letter)
    }

    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
