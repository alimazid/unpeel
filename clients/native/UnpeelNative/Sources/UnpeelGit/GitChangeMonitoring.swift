import Foundation

/// A running watch on one repository that calls its handler when the
/// repository changes. Git History owns one per Explorer Root and stops it
/// when the root changes.
public protocol GitChangeMonitoring: AnyObject, Sendable {
    func stop()
}
