import Foundation

/// Tells the window when something is added, removed or renamed in the folder
/// it shows, so the list never needs F5 for that.
final class DirectoryWatcher {
    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var opening = false
    private static let opens = BackgroundTask.queue("Foldera.directory-watches", limit: 4)
    private var openTask: BlockOperation?
    private var target: URL?
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5

    var isIdle: Bool { source == nil && !opening && retry == nil }
    var isOpening: Bool { opening }
    var isWatching: Bool { source != nil }

    /// With `ready`, the first read starts after the watch is armed, closing
    /// the observation gap without a second unconditional directory walk.
    func watch(_ url: URL?, ready: (() -> Void)? = nil) {
        stop()
        guard let url else { ready?(); return }
        target = url
        openTarget(ready: ready)
    }

    private func openTarget(ready: (() -> Void)?) {
        guard let url = target else { return }
        opening = true
        let generation = self.generation
        let task = BlockOperation()
        task.addExecutionBlock { [weak self, weak task] in
            guard let task, !task.isCancelled else { return }
            let fd = open(url.path, O_EVTONLY)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else {
                    if fd >= 0 { close(fd) }
                    return
                }
                self.opening = false
                self.openTask = nil
                guard fd >= 0 else {
                    ready?()
                    self.retryOpening()
                    return
                }
                self.retryDelay = 0.5
                self.install(fd)
                ready?()
            }
        }
        openTask = task
        Self.opens.addOperation(task)
    }

    /// A renamed/deleted inode never starts reporting events for its
    /// replacement. Retry a temporarily missing path with bounded backoff.
    private func retryOpening() {
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation else { return }
            self.retry = nil
            self.openTarget(ready: { [weak self] in self?.changed() })
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(5, retryDelay * 2)
    }

    private func install(_ fd: Int32) {
        let generation = self.generation
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke, .link, .attrib], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, generation == self.generation else { return }
            if let flags = self.source?.data, !flags.intersection([.delete, .rename, .revoke]).isEmpty,
               let url = self.target {
                self.watch(url, ready: { [weak self] in self?.changed() })
                return
            }
            self.changed()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// Also drops a change still waiting to be answered, so a closed tab or a
    /// folder left behind is not read again.
    func stop() {
        generation += 1
        opening = false
        openTask?.cancel()
        openTask = nil
        target = nil
        retry?.cancel()
        retry = nil
        retryDelay = 0.5
        source?.cancel()
        source = nil
        pending?.cancel()
        pending = nil
    }

    /// A copy of a hundred files is a hundred events; answer once they settle.
    private func changed() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit { stop() }
}
