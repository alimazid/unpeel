import Foundation

/// A running watch on one repository that calls its handler when the
/// repository changes. `GitRepositoryHub` owns one per followed Explorer
/// Root and stops it when the last view following that root lets go.
public protocol GitChangeMonitoring: AnyObject, Sendable {
    func stop()
}
