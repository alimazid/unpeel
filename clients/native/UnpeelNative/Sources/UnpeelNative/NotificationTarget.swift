//
//  NotificationTarget.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. Where a Host `notification.deliver` lands.
//  A Session's notice lands on that Session, as it always has. A Run's
//  notice (`scheduleID`) may concern no Session this Mac knows: the Run
//  never launched (its preset or Project is gone), or its Session never
//  appeared. That one is keyed by its task, and a tap selects nothing.
//

import Foundation

struct NotificationTarget: Equatable {
    /// The Session a banner tap selects; `nil` for a Run with none.
    let sessionID: String?
    /// The banner's identity: a later notice for the same Session, or the
    /// same task with no Session, replaces it.
    let bannerKey: String
    /// The id the phone push names. Its payload requires one, so a Run with
    /// no Session sends the task's key (a tap there opens nothing in
    /// particular, like the Settings test push's stand-in).
    let pushSessionID: String

    /// `nil` when the notice names neither a known Session nor a Run: the
    /// callback answers 404, as before Scheduled Tasks.
    static func resolve(
        sessionID: String,
        sessionKnown: Bool,
        scheduleID: String?
    ) -> NotificationTarget? {
        if sessionKnown, !sessionID.isEmpty {
            return NotificationTarget(
                sessionID: sessionID,
                bannerKey: sessionID,
                pushSessionID: sessionID
            )
        }
        guard let scheduleID else { return nil }
        let key = "schedule:\(scheduleID)"
        return NotificationTarget(sessionID: nil, bannerKey: key, pushSessionID: key)
    }
}
