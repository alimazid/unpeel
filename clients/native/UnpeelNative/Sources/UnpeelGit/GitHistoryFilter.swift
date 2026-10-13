import Foundation

/// The History Branch Filter: which branch's commits Git History lists.
/// Choosing one only changes what is read — never the working tree.
public enum GitHistoryFilter: Hashable, Sendable {
    /// The Checked-out Branch (or the detached commit), following HEAD.
    case checkedOut
    case branch(GitRef)
    /// Every local and remote-tracking branch, merged by date.
    case allBranches

    public static let allBranchesTitle = "All branches"

    var scope: GitLogScope {
        switch self {
        case .checkedOut: return .head
        case .branch(let ref): return .ref(ref.fullName)
        case .allBranches: return .allBranches
        }
    }

    /// `.checkedOut` for the Checked-out Branch chosen by name, so the
    /// default keeps following HEAD; anything else unchanged.
    func normalized(head: GitHead?) -> GitHistoryFilter {
        if case .branch(let ref) = self, ref.kind == .localBranch, ref.name == head?.branch {
            return .checkedOut
        }
        return self
    }

    /// Whether this lists the Checked-out Branch — by default, or because
    /// the branch chosen is the one checked out now.
    func showsCheckedOutBranch(head: GitHead?) -> Bool {
        normalized(head: head) == .checkedOut
    }

    /// The label: the Checked-out Branch (or `detached@…`), the chosen
    /// branch, or "All branches".
    func title(head: GitHead?) -> String {
        switch self {
        case .checkedOut: return head?.displayName ?? ""
        case .branch(let ref): return ref.name
        case .allBranches: return Self.allBranchesTitle
        }
    }

    /// Still meaningful given the branches that exist now; a chosen branch
    /// that was deleted falls back to the Checked-out Branch.
    func validated(against branches: [GitRef]) -> GitHistoryFilter {
        if case .branch(let ref) = self, !branches.contains(ref) { return .checkedOut }
        return self
    }
}
