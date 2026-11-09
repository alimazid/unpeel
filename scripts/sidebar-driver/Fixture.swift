import Foundation

let alphaChildren = ["Inner", "~/w/Big/alpha-3", "~/w/Big/alpha-2", "~/w/Big/alpha-1"]
let betaChildren = ["~/w/Big/beta-3", "~/w/Big/beta-2", "~/w/Big/beta-1"]
let innerChildren = ["~/w/Big/inner-1", "~/w/Big/inner-2"]
let smallChildren = ["~/w/Big/small-3", "~/w/Big/small-2", "~/w/Big/small-1"]

/// A folder in a list, and the rows that show under it while it's open.
struct Folder {
    let label: String
    let id: String
    let block: [String]
}
let alphaFolder = Folder(label: "Alpha", id: "g-alpha", block: alphaChildren + innerChildren)
let betaFolder = Folder(label: "Beta", id: "g-beta", block: betaChildren)
let pinA = Folder(label: "Pin-A", id: "g-pin-a", block: ["~/w/Big/pin-a-1"])
let pinB = Folder(label: "Pin-B", id: "g-pin-b", block: ["~/w/Big/pin-b-1"])
let plain = Folder(label: "Plain", id: "g-plain", block: ["~/w/Big/plain-1"])
let pinsRows = [pinA.label, pinB.label, plain.label]
let pinnedBlock = [pinA.label, pinB.label] + pinA.block + pinB.block
let pinsSession = "~/w/Big/pins-1"

/// A folder and its row on screen.
struct PlacedFolder {
    let folder: Folder
    let row: Row
}

/// Two folders' rows, the upper one first; nil unless both are on screen.
func placed(_ one: Folder, _ two: Folder, in rows: [Row]) -> (upper: PlacedFolder, lower: PlacedFolder)? {
    guard let oneRow = rows.first(where: { $0.label == one.label }),
          let twoRow = rows.first(where: { $0.label == two.label }) else { return nil }
    let first = PlacedFolder(folder: one, row: oneRow)
    let second = PlacedFolder(folder: two, row: twoRow)
    return oneRow.frame.midY < twoRow.frame.midY ? (first, second) : (second, first)
}

/// Whether the folder's rows all come right after its header.
func isOpen(_ folder: Folder, in rows: [String]) -> Bool {
    guard let start = rows.firstIndex(of: folder.label), start + folder.block.count < rows.count else { return false }
    return Set(rows[(start + 1) ... (start + folder.block.count)]) == Set(folder.block)
}
