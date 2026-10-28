import AppKit

/// Receives files that another app has promised, but has not put on disk yet.
/// The provider writes only into a private folder. The ordinary transfer then
/// handles name conflicts, cancellation and Undo at the user's destination.
final class PromisedFiles {
    static func hasFiles(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    static func read(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// Keeps the received files alive until the subsequent transfer finishes.
    /// Cancellation can finish before a provider does; cleanup waits for it.
    final class Outcome {
        let urls: [URL]
        let failures: [String]
        let cancelled: Bool
        private let lock = NSLock()
        private var release: (() -> Void)?

        fileprivate init(urls: [URL], failures: [String], cancelled: Bool, release: @escaping () -> Void) {
            self.urls = urls
            self.failures = failures
            self.cancelled = cancelled
            self.release = release
        }

        func cleanup() {
            lock.lock()
            let action = release
            release = nil
            lock.unlock()
            action?()
        }

        deinit { cleanup() }
    }

    /// The small adapter also allows tests to deliver late and failed promises
    /// without needing a second app or a system drag session.
    struct Source {
        let names: () -> [String]
        let typeCount: Int
        let receive: (URL, OperationQueue, @escaping (URL, Error?) -> Void) -> Void

        init(_ receiver: NSFilePromiseReceiver) {
            names = { receiver.fileNames }
            typeCount = receiver.fileTypes.count
            receive = { folder, queue, reader in
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: reader)
            }
        }

        init(names: @escaping () -> [String], typeCount: Int = 1,
             receive: @escaping (URL, OperationQueue, @escaping (URL, Error?) -> Void) -> Void) {
            self.names = names
            self.typeCount = typeCount
            self.receive = receive
        }
    }

    private var sources: [Source]
    private let queue: OperationQueue
    private let temporaryRoot: URL
    private var staging: URL?
    private var remaining: [Int] = []
    private var callbacks: [Set<String>] = []
    private var urls: [URL] = []
    private var seen = Set<String>()
    private var failures: [String] = []
    private var completion: ((Outcome) -> Void)?
    private var started = false
    private var delivered = false
    private var cleanupRequested = false

    convenience init(receivers: [NSFilePromiseReceiver]) {
        self.init(sources: receivers.map(Source.init))
    }

    init(sources: [Source], temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.sources = sources
        self.temporaryRoot = temporaryRoot
        queue = BackgroundTask.queue("Foldera promised files", limit: 1)
    }

    /// Call on the main thread. AppKit supplies fileNames only AFTER receiving
    /// is requested. Suspend callbacks until every receiver's count is known.
    func start(done: @escaping (Outcome) -> Void) {
        precondition(Thread.isMainThread)
        precondition(!started)
        started = true
        completion = done
        queue.isSuspended = true
        do {
            let folder = temporaryRoot.appendingPathComponent("FolderaPromises-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            staging = folder
            remaining = Array(repeating: 0, count: sources.count)
            callbacks = Array(repeating: [], count: sources.count)
            // AppKit requires all receivers from one drag to use the same
            // destination. It assigns unique names there before writing.
            for (index, source) in sources.enumerated() {
                source.receive(folder, queue) { [self] url, error in
                    received(url, error: error, from: index)
                }
                // A failed handoff may not have any names, but still promises
                // a reader callback carrying the error. Do not finish early.
                remaining[index] = max(source.names().count, max(source.typeCount, 1))
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        queue.addOperation { [self] in finishIfReady() }
        queue.isSuspended = false
    }

    func cancel() {
        queue.addOperation { [self] in
            deliver(cancelled: true)
            cleanupRequested = true
            cleanIfReady()
        }
    }

    /// Runs on the serial receiver queue. A callback with an error may point
    /// at a partial file; it is never offered to the subsequent transfer.
    private func received(_ url: URL, error: Error?, from index: Int) {
        guard remaining.indices.contains(index), remaining[index] > 0 else { return }
        if error == nil, !callbacks[index].insert(url.standardizedFileURL.path).inserted { return }
        remaining[index] -= 1
        if let error {
            failures.append(error.localizedDescription)
        } else if let staging, Self.isReceivedFile(url, in: staging) {
            if seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) }
        } else {
            failures.append("The app returned a file outside its receiving folder, or no file at all.")
        }
        finishIfReady()
    }

    private func finishIfReady() {
        guard remaining.allSatisfy({ $0 == 0 }) else { return }
        // Receivers may retain their reader closures. Break that cycle once
        // every promised file has called back, including after cancellation.
        sources = []
        deliver(cancelled: false)
        cleanIfReady()
    }

    private func deliver(cancelled: Bool) {
        guard !delivered else { return }
        delivered = true
        let outcome = Outcome(urls: cancelled ? [] : urls, failures: failures, cancelled: cancelled) { [self] in
            queue.addOperation { [self] in
                cleanupRequested = true
                cleanIfReady()
            }
        }
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(outcome) }
    }

    private func cleanIfReady() {
        guard cleanupRequested, remaining.allSatisfy({ $0 == 0 }), let staging else { return }
        FileOps.removeOwn(staging)
        self.staging = nil
    }

    /// A promised folder is accepted as one item, with all its descendants.
    /// Reject paths escaping the receiving directory, including symlink roots.
    static func isReceivedFile(_ url: URL, in folder: URL) -> Bool {
        guard url.isFileURL, FileOps.exists(url) else { return false }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == root && resolved.hasPrefix(root + "/")
    }
}
