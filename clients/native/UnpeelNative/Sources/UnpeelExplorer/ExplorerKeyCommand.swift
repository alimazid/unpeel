import AppKit

/// Keys the explorer handles itself; everything else (↑ ↓, type-select,
/// ⌘A…) stays with `NSOutlineView`.
public enum ExplorerKeyCommand: Equatable, Sendable {
    case quickLook
    case open
    case expandOrDescend
    case collapseOrAscend
    case copyPath
    case copyRelativePath
    case revealInFinder
    /// Fork-only: explorer operations. ⌘⌫.
    case trash

    public static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ExplorerKeyCommand? {
        // Arrow keys always carry .numericPad/.function; only these four matter.
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        if flags.isEmpty {
            switch keyCode {
            case 49: return .quickLook
            case 124: return .expandOrDescend
            case 123: return .collapseOrAscend
            default: return nil
            }
        }
        if flags == [.command], keyCode == 125 { return .open }
        if flags == [.command, .option], keyCode == 8 { return .copyPath }
        if flags == [.command, .option, .shift], keyCode == 8 { return .copyRelativePath }
        if flags == [.command, .option], keyCode == 15 { return .revealInFinder }
        if flags == [.command], keyCode == 51 { return .trash }
        return nil
    }
}
