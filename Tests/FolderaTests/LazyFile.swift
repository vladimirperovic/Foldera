import Foundation

/// Plays Windows App: the file it presents is an empty placeholder of the
/// right size until a coordinated reader asks for its contents, which take
/// `delay` seconds to arrive. It is ready for readers `readyAfter` seconds
/// after making the placeholder, or never.
final class LazyFile: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let contents: Data
    private let delay: TimeInterval

    init(_ url: URL, contents: Data, delay: TimeInterval = 0, readyAfter: TimeInterval? = 0) throws {
        presentedItemURL = url
        self.contents = contents
        self.delay = delay
        super.init()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let placeholder = try FileHandle(forWritingTo: url)
        defer { try? placeholder.close() }
        try placeholder.truncate(atOffset: UInt64(contents.count))
        guard let readyAfter else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + readyAfter) { NSFileCoordinator.addFilePresenter(self) }
    }

    /// Some bytes, none of them zero, so a placeholder copied instead shows.
    static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 % 251 + 1) })
    }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        Thread.sleep(forTimeInterval: delay)
        do {
            try contents.write(to: presentedItemURL!)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }
}
