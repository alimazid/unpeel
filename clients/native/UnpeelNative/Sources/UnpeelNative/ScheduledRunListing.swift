//
//  ScheduledRunListing.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. A Project lists only each task's latest
//  Run Session. The Host decides which Runs are superseded (the Session of
//  the task's current Run is the latest) and publishes it on each row
//  (`scheduleID`, `superseded`); every listing here (PROJECTS, AGENTS, ⌘K,
//  the carousel's neighbour page, the bell and menu bar) hides a superseded
//  row from that one field. The row stays projected by id, so the SCHEDULED
//  section can still open it.
//

import Foundation
import UnpeelShared

/// What a Run Session's row carries.
struct ScheduledRunMark: Codable, Hashable, Sendable {
    let scheduleID: String
    /// Not its task's latest Run: Project listings hide it.
    let superseded: Bool
}

enum ScheduledRunListing {
    /// A Run Session's `spawned_by` prefix (`schedules::SPAWNED_BY_PREFIX` on
    /// the Host).
    static let spawnedByPrefix = "schedule:"

    /// The mark a Host-published row carries; nil for any other Session.
    static func mark(_ summary: RemoteSessionSummary) -> ScheduledRunMark? {
        summary.scheduleID.map { ScheduledRunMark(scheduleID: $0, superseded: summary.superseded) }
    }

    /// Whether a Project's listings show this Session.
    static func isListed(_ summary: RemoteSessionSummary) -> Bool {
        !summary.superseded
    }

    static func isListed(_ session: SessionEntry) -> Bool {
        session.scheduledRun?.superseded != true
    }

    /// Run Sessions take no slot in a Project's stopped window, as on the
    /// Host: their keep limit is per task (Run retention).
    static func takesStoppedSlot(_ session: SessionEntry) -> Bool {
        session.scheduledRun == nil
    }

    /// The Sessions each known Project lists, in row order.
    static func sessionsByProject(
        _ entries: [SessionEntry],
        knownProjectIDs: Set<String>
    ) -> [String: [SessionEntry]] {
        var byProject: [String: [SessionEntry]] = [:]
        for entry in entries where knownProjectIDs.contains(entry.projectID) && isListed(entry) {
            byProject[entry.projectID, default: []].append(entry)
        }
        return byProject
    }

    // MARK: - The disk seed

    /// Mark the disk scan's Run Sessions (known there only by `spawned_by`)
    /// until the Host's first bootstrap replaces them. `supersededRunIDs` is
    /// the Host's last verdict, from the startup cache; the seed has no rule
    /// of its own, so a Run the Host has not answered for stays listed.
    static func seeding(
        _ sessions: [SessionEntry],
        supersededRunIDs: Set<String>
    ) -> [SessionEntry] {
        sessions.map { session in
            guard let scheduleID = scheduleID(spawnedBy: session.spawnedBy) else { return session }
            var marked = session
            marked.scheduledRun = ScheduledRunMark(
                scheduleID: scheduleID,
                superseded: supersededRunIDs.contains(session.id)
            )
            return marked
        }
    }

    private static func scheduleID(spawnedBy: String?) -> String? {
        guard let spawnedBy, spawnedBy.hasPrefix(spawnedByPrefix) else { return nil }
        let id = String(spawnedBy.dropFirst(spawnedByPrefix.count))
        return id.isEmpty ? nil : id
    }
}
