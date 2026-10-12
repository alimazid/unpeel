import Foundation

/// The only git subcommands Unpeel ever runs. None of them writes to the
/// repository: Git History and the EXPLORER are strictly read-only, and git
/// writes stay with the agents and the user's shell. Running anything else
/// is impossible by construction — `GitRunner.run` takes this type, not a
/// free-form string.
public enum GitReadCommand: String, CaseIterable, Sendable {
    case status
    case revParse = "rev-parse"
    case forEachRef = "for-each-ref"
    case log
    case show
    case diffTree = "diff-tree"
    case checkIgnore = "check-ignore"
}
