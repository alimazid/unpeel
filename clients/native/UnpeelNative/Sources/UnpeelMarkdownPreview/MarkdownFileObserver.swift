import Foundation

/// Watches ONE file with a vnode DispatchSource. Atomic saves replace the
/// inode (the source then reports `.delete`/`.rename`), so after such an
/// event the observer closes its descriptor and re-opens the path a moment
/// later; the callback is debounced so a burst of writes yields one reload.
@MainActor
public final class MarkdownFileObserver {
    private let path: String
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?
    private var reopen: DispatchWorkItem?
    private static let reopenDelay: TimeInterval = 0.1

    public init(path: String, debounce: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard source == nil else { return }
        arm()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        disarm()
    }

    private func arm() {
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self.disarm()
                let work = DispatchWorkItem { [weak self] in
                    self?.reopen = nil
                    self?.arm()
                }
                self.reopen = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reopenDelay, execute: work)
            }
            self.scheduleChange()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func disarm() {
        reopen?.cancel()
        reopen = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        // Cancelling closes the descriptor through the cancel handler.
        source?.cancel()
    }
}
