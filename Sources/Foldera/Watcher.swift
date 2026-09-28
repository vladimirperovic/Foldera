import Foundation

/// Tells the window when something is added, removed or renamed in the folder
/// it shows, so the list never needs F5 for that.
final class DirectoryWatcher {
    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    var isIdle: Bool { source == nil }

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .attrib], queue: .main)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// Also drops a change still waiting to be answered, so a closed tab or a
    /// folder left behind is not read again.
    func stop() {
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
