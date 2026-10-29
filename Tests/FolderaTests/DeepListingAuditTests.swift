import AppKit
import Darwin
import Testing
@testable import Foldera

private final class DeepListingFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaDeepListing-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    @discardableResult func file(_ path: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "contents".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    deinit { FileOps.removeOwn(root) }
}

@MainActor private func deepListingEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Suite(.serialized) @MainActor struct DeepListingAudit {
    @Test func aLateOrdinaryLoadCannotReplaceSearchResults() async throws {
        let files = try DeepListingFiles()
        try files.file("match.txt")
        try files.file("unrelated.txt")
        let tab = ExplorerTab(location: .folder(files.root))
        defer { tab.tearDown() }
        try await deepListingEventually { tab.items.count == 2 }
        tab.watcher.stop()
        tab.searchQuery = "match"
        tab.runSearch()
        try await deepListingEventually { !tab.searchRunning }
        let generation = tab.loadGeneration
        // This is the callback a slow watch delivers after Search has begun.
        tab.load()
        #expect(tab.loadGeneration == generation)
        #expect(tab.items.map(\.name) == ["match.txt"])
    }

    @Test func tagSortingSearchResultsStaysOffMainAndIncludesNewBatches() async throws {
        let files = try DeepListingFiles()
        let alpha = FileItem(url: try files.file("alpha.txt"))
        let beta = FileItem(url: try files.file("beta.txt"))
        let zulu = FileItem(url: try files.file("zulu.txt"))
        alpha.tags = ["a"]; beta.tags = ["b"]; zulu.tags = ["z"]
        let tab = ExplorerTab(location: .folder(files.root))
        let gate = DispatchSemaphore(value: 0), started = CancelFlag()
        defer { gate.signal(); tab.tearDown() }
        try await deepListingEventually { tab.items.count == 3 }
        tab.watcher.stop()
        tab.searchQuery = "test"
        tab.searchRunning = true
        tab.sort = SortSpec(key: .tags, ascending: true)
        tab.items = [zulu, alpha]
        tab.showItems()
        tab.selectQuietly([zulu.key])
        tab.resort { items, order in
            #expect(!Thread.isMainThread)
            if !started.isSet {
                started.set()
                _ = gate.wait(timeout: .now() + 5)
            }
            return items.sorted(by: order)
        }
        try await deepListingEventually { started.isSet }
        // Main-thread interaction and new results continue while sorting waits.
        tab.appendResults([beta])
        tab.selectQuietly([alpha.key])
        gate.signal()
        try await deepListingEventually { !tab.sortPending && tab.items.map(\.name) == ["alpha.txt", "beta.txt", "zulu.txt"] }
        #expect(tab.selectedItems.map(\.key) == [alpha.key])
    }

    @Test func delayedSearchResultsCannotResurrectDeletedFilesButRefreshShowsUndo() async throws {
        let files = try DeepListingFiles()
        let file = try files.file("match.txt")
        let stale = FileItem(url: file)
        let tab = ExplorerTab(location: .folder(files.root))
        defer { tab.tearDown() }
        try await deepListingEventually { tab.items.count == 1 }
        tab.watcher.stop()
        tab.searchQuery = "match"
        tab.runSearch()
        try await deepListingEventually { !tab.searchRunning }
        try FileManager.default.removeItem(at: file)
        tab.drop([stale.key])
        tab.appendResults([stale])
        #expect(tab.items.isEmpty)
        try files.file("match.txt")
        tab.runSearch()
        try await deepListingEventually { !tab.searchRunning }
        #expect(tab.items.map(\.name) == ["match.txt"])
    }

    @Test(arguments: [false, true])
    func foreignSearchHonorsNativeHiddenItemsAndPackageBoundaries(showHidden: Bool) async throws {
        let files = try DeepListingFiles()
        try files.file("visible-match.txt")
        try files.file("System Volume Information/system-match.txt")
        try files.file(".private/dot-match.txt")
        try files.file("match.app/Contents/inside-match.txt")
        let hidden = try files.file("native-match.txt")
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        let search = FolderSearch(isForeign: { _ in
            #expect(!Thread.isMainThread)
            return true
        })
        var names: [String] = []
        var finished = false
        search.start(in: files.root, for: "match", showHidden: showHidden, found: { names += $0.map(\.name) }) { truncated, unreadable in
            #expect(!truncated && unreadable == 0)
            finished = true
        }
        try await deepListingEventually { finished }
        let expected: Set<String> = showHidden
            ? ["visible-match.txt", "system-match.txt", "dot-match.txt", "native-match.txt", "match.app"]
            : ["visible-match.txt", "match.app"]
        #expect(Set(names) == expected)
    }

    @Test func todayAndYesterdayUseTheSameReferenceDateAsOtherFilters() throws {
        let files = try DeepListingFiles()
        let file = try files.file("dated.txt")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2001-01-03T01:00:00Z"))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        for (date, filter) in [(now, SearchFilters.Modified.today), (yesterday, .yesterday)] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let item = FileItem(url: URL(fileURLWithPath: file.path))
            var filters = SearchFilters()
            filters.modified = filter
            #expect(filters.matches(item, now: now, calendar: calendar))
            filters.modified = filter == .today ? .yesterday : .today
            #expect(!filters.matches(item, now: now, calendar: calendar))
        }
    }
}
