import AppKit
import Testing
@testable import Foldera

private final class ListingFiles {
    let root: URL
    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        root = parent.appendingPathComponent("FolderaListing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    @discardableResult func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "contents".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    deinit { FileOps.removeOwn(root) }
}

@MainActor private func listingEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Suite(.serialized) @MainActor struct PerformanceListing {
    @Test func replacingAQueuedSearchOnlyDeliversTheLatestResultsBeforeCompletion() async throws {
        let files = try ListingFiles()
        try files.file("first.txt")
        try files.file("second.txt")
        let queue = BackgroundTask.queue("test.search.replacement", limit: 1)
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let search = FolderSearch(queue: queue)
        var events: [String] = []
        search.start(in: files.root, for: "first", showHidden: false,
                     found: { _ in events.append("obsolete results") },
                     finished: { _, _ in events.append("obsolete completion") })
        search.start(in: files.root, for: "second", showHidden: false,
                     found: { events += $0.map(\.name) },
                     finished: { truncated, unreadable in
                         #expect(!truncated && unreadable == 0)
                         events.append("finished")
                     })
        queue.isSuspended = false
        try await listingEventually { events.last == "finished" }
        #expect(events == ["second.txt", "finished"])
    }

    @Test func replacingAColumnTreeStopsItsReadAndDropsItsWaitingCallbacks() async throws {
        _ = NSApplication.shared
        let files = try ListingFiles()
        try files.file("branch/entry.txt")
        let columns = Columns()
        let started = CancelFlag(), stopped = CancelFlag()
        columns.readChildren = { url, _, _, _, cancelled in
            started.set()
            let deadline = Date().addingTimeInterval(5)
            while !cancelled.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            if cancelled.isSet { stopped.set() }
            return [ColumnNode(url: url.appendingPathComponent("obsolete.txt"), item: nil)]
        }
        defer { columns.cancelLoading() }
        columns.show(files.root, items: [FileItem(url: files.root.appendingPathComponent("branch"))])
        let root = try #require(columns.rootItem(for: columns.browser) as? ColumnNode)
        let old = try #require(root.children?.first)
        var callbacks = 0
        old.whenLoaded.append { callbacks += 1 }
        #expect(columns.browser(columns.browser, numberOfChildrenOfItem: old) == 1)
        try await listingEventually { started.isSet }
        columns.show(files.root, items: [])
        try await listingEventually { stopped.isSet }
        #expect(!old.loading && old.children == nil && old.whenLoaded.isEmpty)
        #expect(callbacks == 0)
    }

}
