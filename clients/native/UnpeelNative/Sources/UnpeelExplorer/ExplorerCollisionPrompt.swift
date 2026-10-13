import AppKit

/// Fork-only: explorer operations. The Collision Prompt: what to do when an
/// item being pasted, dropped or moved meets one of the same name.
public struct CollisionAnswer: Equatable, Sendable {
    public let resolution: CollisionResolution
    /// Use the same answer for every other collision of this operation.
    public let appliesToAll: Bool

    public init(_ resolution: CollisionResolution, appliesToAll: Bool = false) {
        self.resolution = resolution
        self.appliesToAll = appliesToAll
    }
}

@MainActor
public protocol CollisionPrompting: AnyObject {
    /// `remaining` is how many more collisions follow this one; "Apply to
    /// all" is offered only when there are some.
    func answer(forExisting name: String, isFolder: Bool, copying: Bool, remaining: Int) async -> CollisionAnswer
}

/// The Collision Prompt as a sheet on the tree's window: Replace, Keep Both
/// or Skip (Escape), with "Apply to all" when more collisions follow.
@MainActor
public final class AlertCollisionPrompt: CollisionPrompting {
    private weak var window: NSWindow?

    public init(window: NSWindow?) {
        self.window = window
    }

    public func answer(forExisting name: String, isFolder: Bool, copying: Bool, remaining: Int) async -> CollisionAnswer {
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in this location."
        alert.informativeText = "Do you want to replace it with the \(isFolder ? "folder" : "file") you’re "
            + "\(copying ? "copying" : "moving")? Replace moves the existing item to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        let skip = alert.addButton(withTitle: "Skip")
        skip.keyEquivalent = "\u{1b}"
        if remaining > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all"
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let resolution: CollisionResolution = switch response {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .keepBoth
        default: .skip
        }
        return CollisionAnswer(resolution, appliesToAll: alert.suppressionButton?.state == .on)
    }
}
