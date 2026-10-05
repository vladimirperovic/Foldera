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

    var isIdle: Bool { source == nil && !opening }

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
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
                guard fd >= 0 else { return }
                self.install(fd)
                // Re-read after arming the watch: changes during the open
                // must not be missed on a slow volume.
                self.changed()
            }
        }
        openTask = task
        Self.opens.addOperation(task)
    }

    private func install(_ fd: Int32) {
        let generation = self.generation
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .attrib], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self, generation == self.generation else { return }
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
