import Foundation

/// Fork-only: explorer operations. Moves and copies, and the large ones as
/// Transfers. Every move or copy is planned in the operation queue (the
/// plan measures what it copies, off the main actor). A small one is then
/// carried out there like any other operation. A large one copies outside
/// the queue — so a rename or ⌘Z never waits minutes behind it — with a
/// progress row and Cancel, and only putting the copies in place goes
/// through the queue: one undo step. Cancelled or failed, it removes what
/// it copied and records nothing.
///
/// Two large copies at once each run and each show their own row.
extension ExplorerViewModel {
    /// Large pastes and drops into the root on screen.
    public var visibleTransfers: [ExplorerTransfer] {
        guard let root = model?.root else { return [] }
        return transfers.filter { $0.root == root }
    }

    func transfer(
        _ paths: [String], into folder: String, kind: FileOperationKind,
        resolutions: [String: CollisionResolution], named name: FileOperationKind?
    ) -> Task<Void, Never> {
        let large = LargeTransferSlot()
        let planned = enqueue { root, operations in
            let plan = await Self.detached { operations.plan(paths, into: folder, kind: kind) }
            if plan.copySize.exceeds(self.services.largeTransfer) {
                large.task = self.runTransfer(plan, resolutions: resolutions, named: name, root: root, operations: operations)
                return nil
            }
            let outcome = await Self.detached { operations.commit(plan, resolutions: resolutions).named(name) }
            self.push(outcome.record, root: root)
            return outcome
        }
        return Task { @MainActor in
            await planned.value
            await large.task?.value
        }
    }

    private func runTransfer(
        _ plan: TransferPlan, resolutions: [String: CollisionResolution], named name: FileOperationKind?,
        root: String, operations: FileOperations
    ) -> Task<Void, Never> {
        let transfer = ExplorerTransfer(root: root, plan: plan)
        let progress = transfer.progress
        transfers.append(transfer)
        return Task { @MainActor in
            let following = transfer.follow()
            let staged = await Self.detached { operations.stage(plan, resolutions: resolutions, progress: progress) }
            following.cancel()
            switch staged {
            case .cancelled:
                break
            case .failed(let failure):
                if model?.root == root { operationMessage = Self.message(for: [failure] + plan.failures) }
            case .staged(let ready):
                await enqueue(root: root, operations: operations) { root, operations in
                    // Cancelled while it waited for its turn: nothing placed.
                    if progress.isCancelled {
                        await Self.detached { operations.discard(ready) }
                        return nil
                    }
                    let outcome = await Self.detached { operations.commit(ready, resolutions: resolutions).named(name) }
                    self.push(outcome.record, root: root)
                    return outcome
                }.value
            }
            transfers.removeAll { $0 === transfer }
        }
    }
}

/// The task of a Transfer a queued plan started, for whoever asked for it.
@MainActor
private final class LargeTransferSlot {
    var task: Task<Void, Never>?
}
