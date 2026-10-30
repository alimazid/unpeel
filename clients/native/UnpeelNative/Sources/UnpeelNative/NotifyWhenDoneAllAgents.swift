//
//  NotifyWhenDoneAllAgents.swift
//  UnpeelNative
//
//  Fork-only: Settings ▸ Notifications "Notify when any agent finishes" —
//  the per-session "Notify when done" opt-in applied to every Session at
//  once. The Host sends every finished turn as a `notification.deliver`
//  with `requiresNotifyWhenDone`; this app's adapter half decides
//  eligibility, so the knob is a pure Controller overlay (no Host verb).
//

import Foundation

enum NotifyWhenDoneAllAgents {
    /// Per-workspace overlay key (`AppDefaults.shared`).
    static let key = "unpeel.native.notifyWhenDoneAllAgents"

    /// Whether a `notification.deliver` callback should reach the Mac banner
    /// and the phone push. Needs-input alerts never require the opt-in; a
    /// finished turn needs the session's own toggle or the all-agents knob.
    /// Deliberately not gated on the app's session catalog: the Host only
    /// reports a finished turn for Sessions with a lifecycle source, and the
    /// startup catalog misses Sessions created after launch.
    static func isEligible(
        requiresNotifyWhenDone: Bool,
        sessionOptedIn: Bool,
        allAgents: Bool
    ) -> Bool {
        !requiresNotifyWhenDone || sessionOptedIn || allAgents
    }

    /// The effective value: this workspace's own setting, else the default
    /// workspace's (`baseline`, the shared `.standard` domain — Decision 4
    /// generalized, as for menu attention), else off.
    static func resolve(
        own: UserDefaults,
        baseline: UserDefaults,
        isDefaultInstance: Bool
    ) -> Bool {
        if let value = own.object(forKey: key) as? Bool {
            return value
        }
        if !isDefaultInstance,
           let inherited = baseline.object(forKey: key) as? Bool {
            return inherited
        }
        return false
    }

    /// Whether `defaults` records its own value — feeds the Notifications
    /// revert button's enablement.
    static func hasOwnSetting(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) != nil
    }
}

extension NotifyWhenDoneAllAgents {
    /// `resolve` for this process: its own workspace suite over the default
    /// workspace's `.standard` domain.
    static func resolveForThisInstance() -> Bool {
        resolve(
            own: AppDefaults.shared,
            baseline: .standard,
            isDefaultInstance: UnpeelWorkspaceContext.isDefaultInstance
        )
    }

    static var hasOwnSettingForThisInstance: Bool {
        hasOwnSetting(in: AppDefaults.shared)
    }
}
