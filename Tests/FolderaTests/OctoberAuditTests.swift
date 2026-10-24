import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Foldera

private final class OctoberFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaOctober-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    @discardableResult func file(_ name: String, _ text: String = "contents") throws -> URL {
        let url = url(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    deinit { FileOps.removeOwn(root) }
}

@MainActor private func octoberEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private func octoberPicture(_ url: URL) throws {
    let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(output))
}

@Suite struct OctoberAudit {
    @Test func plannedNamesRespectTheDestinationsCaseRules() throws {
        let f = try OctoberFiles()
        let sources = try [f.file("one/report.txt"), f.file("two/REPORT.txt"), f.file("three/Report.txt")]
        let target = f.url("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sensitive = try target.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let plan = try #require(Transfer.plan(sources, into: target, move: false) { _, _, _ in
            Issue.record("Names reserved by this plan should be resolved without a clash question.")
            return (.stop, false)
        })
        #expect(plan.steps.count == 3)
        let names = plan.steps.map { sensitive ? $0.to.lastPathComponent : $0.to.lastPathComponent.lowercased() }
        #expect(Set(names).count == 3)
    }

    @Test func textReadingRejectsOversizedInputWithoutReturningAPartialDocument() throws {
        let f = try OctoberFiles(), file = try f.file("large.md", "123456789")
        #expect(throws: (any Error).self) { try TextFile.data(file, limit: 8) }
        #expect(try TextFile.data(file, limit: 9) == Data("123456789".utf8))
        #expect(try String(contentsOf: file, encoding: .utf8) == "123456789")
    }

    @Test func usageTotalsAreRepeatableAndRemovalUpdatesOrderAndDominantKind() {
        let root = UsageNode(url: URL(fileURLWithPath: "/usage"), name: "usage", isFolder: true, kind: .folders)
        let images = UsageNode(url: root.url.appendingPathComponent("images"), name: "images", isFolder: true, kind: .folders)
        let video = UsageNode(url: root.url.appendingPathComponent("video"), name: "video", isFolder: true, kind: .folders)
        for node in [images, video] { node.parent = root }
        images.addSmall(100, kind: .images)
        images.unreadable = 1
        video.addSmall(60, kind: .video)
        root.children = [images, video]
        #expect(root.total() == 160 && root.unreadable == 1)
        #expect(root.total() == 160 && root.files == 2 && root.unreadable == 1)
        #expect(root.dominantKind == .images)
        images.remove()
        #expect(root.size == 60 && root.files == 1 && root.unreadable == 0)
        #expect(root.dominantKind == .video)
        images.remove()
        #expect(root.size == 60 && root.files == 1)
        #expect(root.total() == 60 && root.unreadable == 0)
    }

    @Test func shrinkingUsageFoldersStaySortedAndCancelledTotalsStop() {
        let root = UsageNode(url: URL(fileURLWithPath: "/usage"), name: "usage", isFolder: true, kind: .folders)
        let big = UsageNode(url: root.url.appendingPathComponent("big"), name: "big", isFolder: true, kind: .folders)
        let other = UsageNode(url: root.url.appendingPathComponent("other"), name: "other", isFolder: false, kind: .video)
        let file = UsageNode(url: big.url.appendingPathComponent("file"), name: "file", isFolder: false, kind: .images)
        big.parent = root; other.parent = root; file.parent = big
        big.addSmall(10, kind: nil); file.size = 100; other.size = 50
        big.children = [file]; root.children = [big, other]
        root.total()
        #expect(root.children.first === big)
        file.remove()
        #expect(root.children.first === other && root.size == 60)
        let cancelled = CancelFlag(); cancelled.set()
        big.smallFiles = 1000
        #expect(root.total(cancelled: cancelled) == 60)
    }

    @MainActor @Test func usageInvalidationAlsoExpiresOnlyTheRelatedRunningScans() throws {
        let f = try OctoberFiles()
        defer { UsageCache.forget(f.root) }
        let inside = UsageCache.beginScan(f.url("parent/child"))
        let above = UsageCache.beginScan(f.root)
        let sibling = UsageCache.beginScan(f.url("sibling"))
        UsageCache.changed(f.url("parent/child/new.txt"))
        #expect(!inside.isCurrent && !above.isCurrent && sibling.isCurrent)
    }

    @Test(arguments: ["edit", "add", "remove", "replace"])
    func aCopiedSourceThatChangedIsKept(_ change: String) throws {
        let f = try OctoberFiles()
        let file = try f.file("source/nested/a.txt", "old")
        let source = f.url("source"), target = f.url("copy")
        let copier = TreeCopier(cancelled: CancelFlag())
        try copier.copy(source, to: target, verifyingSource: true)
        switch change {
        case "edit": try "new".write(to: file, atomically: false, encoding: .utf8)
        case "add": try f.file("source/nested/new.txt", "never copied")
        case "remove": try FileManager.default.removeItem(at: file)
        default:
            try FileManager.default.moveItem(at: source, to: f.url("original"))
            try f.file("source/different.txt", "different source")
        }
        #expect(throws: (any Error).self) { try copier.removeCopiedSource(source) }
        #expect(FileOps.exists(source))
        #expect(try String(contentsOf: target.appendingPathComponent("nested/a.txt"), encoding: .utf8) == "old")
        if change == "edit" { #expect(try String(contentsOf: file, encoding: .utf8) == "new") }
        if change == "add" { #expect(FileOps.exists(source.appendingPathComponent("nested/new.txt"))) }
    }

    @Test func anUnchangedCopiedTreeCanBeRemovedWithoutFollowingLinks() throws {
        let f = try OctoberFiles()
        try f.file("source/nested/a.txt")
        let outside = try f.file("outside.txt", "outside")
        try FileManager.default.createSymbolicLink(at: f.url("source/link"), withDestinationURL: outside)
        let copier = TreeCopier(cancelled: CancelFlag())
        try copier.copy(f.url("source"), to: f.url("copy"), verifyingSource: true)
        try "changed referent".write(to: outside, atomically: true, encoding: .utf8)
        try copier.removeCopiedSource(f.url("source"))
        #expect(!FileOps.exists(f.url("source")))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "changed referent")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.url("copy/link").path) == outside.path)
    }

    @Test(arguments: Archive.Format.allCases)
    func archiveOperandsStartingWithAtOrDashStayLiteral(_ format: Archive.Format) throws {
        let f = try OctoberFiles()
        let chosen = try f.file("@report.tar", "chosen file")
        let dash = try f.file("-notes.txt", "dash file")
        try f.file("report.tar", "not the selected archive")
        let (archive, problem) = Archive.compress([chosen, dash], as: format).runAndWait()
        #expect(problem == nil)
        try Unpacker(try #require(archive)).unpack(into: f.url("out"))
        #expect(try String(contentsOf: f.url("out/@report.tar"), encoding: .utf8) == "chosen file")
        #expect(try String(contentsOf: f.url("out/-notes.txt"), encoding: .utf8) == "dash file")
        #expect(!FileOps.exists(f.url("out/report.tar")))
    }

    @Test func aCancelledExtractionDoesNotPublishItsStagingTree() throws {
        let f = try OctoberFiles(), source = try f.file("a.txt")
        let (made, _) = Archive.compress([source]).runAndWait()
        let archive = try #require(made), unpacker = Unpacker(archive)
        let output = f.url("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(throws: CancellationError.self) {
            try Archive.extractAll(archive, into: output, using: unpacker, progress: { fraction in
                if fraction >= 1 { unpacker.cancel() }
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let cancelled = CancelFlag()
        cancelled.set()
        #expect(throws: CancellationError.self) {
            try Unpacker.mark(output, with: Data("quarantine".utf8), cancelled: cancelled)
        }
    }

    @Test func markdownFormattingPreservesLinkAddressesAndFormattedLabels() {
        let address = "https://example.com/file__old__v2.zip"
        let linked = Markdown.inline("[**download `now`**](\(address))")
        #expect(linked == "<a href=\"\(address)\"><strong>download <code>now</code></strong></a>")
        #expect(Markdown.inline("<\(address)>") == "<a href=\"\(address)\">\(address)</a>")
        #expect(Markdown.inline("[local](file__old__v2.txt)").contains("href=\"file__old__v2.txt\""))
        #expect(!linked.contains("\0"))
    }

    @Test func renameCounterOverflowIsAValidationError() throws {
        let f = try OctoberFiles()
        let items = try [f.file("a.txt"), f.file("b.txt")].map { FileItem(url: $0) }
        var rule = RenameRule()
        rule.name = "[C]"
        rule.start = Int.max
        #expect(BatchRename.rows(for: items, rule: rule)[1].problem != nil)
        #expect(rule.newName(for: items[1], index: 1) == items[1].name)
        rule.start = Int.min
        rule.step = -1
        #expect(BatchRename.rows(for: items, rule: rule)[1].problem != nil)
        rule.start = 0
        rule.step = Int.max
        #expect(rule.counter(at: 2) == nil)
        #expect(rule.counter(at: 1) == Int.max)
    }

    @Test func oldServerPasswordsAreRemovedFromPersistentPreferences() throws {
        let suite = "FolderaOctoberPreferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["smb://user:secret@nas/share"], forKey: "recentServers")
        #expect(Servers.cleanRecent(in: defaults) == ["smb://user@nas/share"])
        #expect(defaults.stringArray(forKey: "recentServers") == ["smb://user@nas/share"])
    }

    @Test func localPictureReadsRespectSizeAndCancellation() throws {
        let f = try OctoberFiles(), file = f.url("large.png")
        let bytes = Data(repeating: 7, count: 2 << 20)
        try bytes.write(to: file)
        #expect(LocalPictures.readImage(file, limit: bytes.count, cancelled: { false }) == bytes)
        #expect(LocalPictures.readImage(file, limit: 16, cancelled: { false }) == nil)
        var checks = 0
        #expect(LocalPictures.readImage(file, cancelled: { checks += 1; return checks >= 3 }) == nil)
        #expect(checks == 3)
        let png = f.url("valid.png")
        try octoberPicture(png)
        let preview = try #require(LocalPictures.pictureData(png, kind: .png, originalLimit: 1, cancelled: { false }))
        #expect(preview.type == "image/png")
        let decoded = try #require(CGImageSourceCreateWithData(preview.body as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(decoded, 0, nil)?.width == 4)
    }

    @Test func markdownPreviewHonorsCancellationAndDocumentLimits() {
        let cancelled = CancelFlag()
        cancelled.set()
        #expect(Markdown.html("**not rendered**", cancelled: cancelled).isEmpty)
        #expect(Markdown.html("**not rendered**", timeLimit: 0).isEmpty)
        let long = String(repeating: "plain\n", count: Markdown.previewBytes / 6 + 1) + "end-of-document"
        let rendered = Markdown.html(long)
        #expect(rendered.contains("This preview was shortened."))
        #expect(!rendered.contains("end-of-document"))
    }

    @Test func aCancelledFolderReadStopsEnumeration() throws {
        let f = try OctoberFiles(), file = try f.file("a.txt"), cancelled = CancelFlag()
        var yielded = 0
        #expect(throws: CancellationError.self) {
            try FileItem.contents(of: f.root, showHidden: true, cancelled: cancelled, enumerate: { _, _, _, _ in
                AnyIterator {
                    yielded += 1
                    if yielded == 2 { cancelled.set() }
                    return yielded <= 10 ? file : nil
                }
            })
        }
        #expect(yielded == 2)
    }

    @Test func nameAllocationResumesAfterAlreadyReservedSuffixes() throws {
        let f = try OctoberFiles(), source = try f.file("from/report.txt")
        let destination = f.url("to")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try f.file("to/report (2).txt")
        var names = FileOps.NameAllocator(), reserved = Set<String>()
        for suffix in 3...103 {
            let next = names.name(for: source, in: destination, taken: reserved)
            #expect(next.lastPathComponent == "report (\(suffix)).txt")
            reserved.insert(next.key)
        }
    }
}

extension SyncTestIsolation {
    @Suite(.serialized) struct OctoberSyncHistory {
        @Test func replacingARootDuringASyncStopsBeforeTheNextDeletion() throws {
            let f = try OctoberFiles(), left = f.url("left"), right = f.url("right")
            let old = Sync.Memory.folder
            Sync.Memory.folder = f.url("memory")
            defer { Sync.Memory.folder = old }
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try f.file("right/a.txt"); try f.file("right/b.txt")
            let scan = try Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag())
            let job = Sync.Job(scan, rows: Sync.plan(scan, mode: .mirror).rows, permanently: true)
            job.discardPermanently = { url in
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: left, to: f.url("previous-left"))
                try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
            }
            let outcome = job.perform()
            #expect(outcome.deleted == 1 && !outcome.failures.isEmpty && outcome.scan == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: right.path).count == 1)
        }

        @Test func cancellationDuringTheLastActionIsReportedAsStopped() throws {
            let f = try OctoberFiles(), left = f.url("left"), right = f.url("right")
            let old = Sync.Memory.folder
            Sync.Memory.folder = f.url("memory")
            defer { Sync.Memory.folder = old }
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try f.file("right/a.txt")
            let scan = try Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag())
            let job = Sync.Job(scan, rows: Sync.plan(scan, mode: .mirror).rows, permanently: true)
            job.discardPermanently = { url in
                try FileManager.default.removeItem(at: url)
                job.cancel()
            }
            let outcome = job.perform()
            #expect(outcome.deleted == 1 && outcome.cancelled && outcome.scan == nil)
            // Break the injected test callback's strong reference to the job.
            job.discardPermanently = { try FileOps.removeTree($0) }
        }

        @Test(arguments: [false, true])
        func aDifferentRootOrLegacyHistoryDoesNotPropagateDeletions(legacy: Bool) throws {
            let f = try OctoberFiles(), left = f.url("left"), right = f.url("right")
            let old = Sync.Memory.folder
            Sync.Memory.folder = f.url("memory")
            defer { Sync.Memory.folder = old }
            for index in 0..<10 {
                let source = try f.file("left/\(index).txt", "same")
                let target = f.url("right/\(index).txt")
                try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            }
            var memory = try Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag()).memory
            if legacy {
                memory.leftIdentity = nil
                memory.rightIdentity = nil
                memory.identityVersion = nil
                try memory.save()
                try FileManager.default.removeItem(at: right.appendingPathComponent("0.txt"))
            } else {
                let previous = f.url("previous-right")
                try FileManager.default.moveItem(at: right, to: previous)
                try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
                for index in 1..<10 {
                    try FileManager.default.copyItem(at: previous.appendingPathComponent("\(index).txt"),
                                                    to: right.appendingPathComponent("\(index).txt"))
                }
            }
            let scan = try Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag())
            let plan = Sync.plan(scan, mode: .twoWay)
            #expect(scan.memory.requiresReview)
            #expect(plan.rows.first { $0.name == "0.txt" }?.action == .toRight)
            #expect(!plan.rows.contains { $0.action == .deleteLeft || $0.action == .deleteRight })
            #expect(!Sync.Job(scan, rows: plan.rows, permanently: true).perform().failures.isEmpty)
            let fresh = try Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag())
            #expect(!fresh.memory.requiresReview)
            #expect(FileOps.exists(left.appendingPathComponent("0.txt")))
            #expect(Sync.Memory.load(right, left).leftIdentity == Sync.persistentIdentity(of: right))
        }

        @Test func anUnreadableOrMissingRootDoesNotLookEmpty() throws {
            let f = try OctoberFiles()
            #expect(throws: (any Error).self) {
                try Sync.list(f.url("missing"), ignoreCase: false, cancelled: CancelFlag())
            }
        }
    }
}

extension BackgroundWork {
    @Test func aUsageScanInvalidatedWhileRunningIsReadAgainBeforeDelivery() async throws {
        _ = NSApplication.shared
        let f = try OctoberFiles()
        try f.file("present.txt")
        let tab = ExplorerTab(location: .folder(f.root))
        defer { tab.tearDown(); UsageCache.forget(f.root) }
        try await octoberEventually { tab.items.count == 1 }
        tab.watcher.stop()
        let first = CancelFlag(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var delivered: [String] = []
        tab.measure(force: true, scan: { _, url in
            let initial = !first.isSet
            if initial { first.set(); _ = gate.wait(timeout: .now() + 10) }
            return UsageNode(url: url, name: initial ? "stale" : "fresh", isFolder: true, kind: .folders)
        }) { delivered.append($0.name) }
        try await octoberEventually { first.isSet }
        UsageCache.changed(f.url("present.txt"))
        gate.signal()
        try await octoberEventually { delivered == ["fresh"] }
        #expect(UsageCache.node(for: f.root)?.name == "fresh")
    }

    @Test(arguments: [false, true])
    func anOldSortCannotReplaceAChangedListing(removal: Bool) async throws {
        _ = NSApplication.shared
        let f = try OctoberFiles(), a = try f.file("a.txt"), b = try f.file("b.txt")
        let tab = ExplorerTab(location: .folder(f.root))
        defer { tab.tearDown() }
        try await octoberEventually { tab.items.count == 2 }
        tab.watcher.stop()
        tab.sort = SortSpec(key: .tags, ascending: true)
        tab.items.forEach { $0.tags = [] }
        let started = CancelFlag(), returned = CancelFlag(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        tab.resort(using: { items, order in
            started.set()
            _ = gate.wait(timeout: .now() + 10)
            defer { returned.set() }
            return items.sorted(by: order)
        })
        try await octoberEventually { started.isSet }
        let expected: Set<String>
        if removal {
            tab.drop([a.key])
            expected = [b.key]
        } else {
            let c = try f.file("c.txt")
            let full = [a, b, c].map { FileItem(url: $0) }
            full.forEach { $0.tags = [] }
            tab.apply(full, error: nil, sortedBy: tab.sort)
            expected = Set([a.key, b.key, c.key])
        }
        gate.signal()
        try await octoberEventually { returned.isSet }
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(tab.items.map(\.key)) == expected)
    }

    @Test func aCancelledUsageCompletionCannotConsumeTheNewScanCallbacks() async throws {
        _ = NSApplication.shared
        let f = try OctoberFiles()
        try f.file("present.txt")
        let tab = ExplorerTab(location: .folder(f.root))
        defer { tab.tearDown(); UsageCache.forget(f.root) }
        try await octoberEventually { tab.items.count == 1 }
        tab.watcher.stop()
        let first = CancelFlag(), second = CancelFlag(), returned = CancelFlag()
        let oldGate = DispatchSemaphore(value: 0), newGate = DispatchSemaphore(value: 0)
        defer { oldGate.signal(); newGate.signal() }
        var delivered: [String] = []
        tab.measure(force: true, scan: { _, url in
            first.set()
            _ = oldGate.wait(timeout: .now() + 10)
            returned.set()
            return UsageNode(url: url, name: "old", isFolder: true, kind: .folders)
        }) { delivered.append($0.name) }
        try await octoberEventually { first.isSet }
        tab.measure(force: true, scan: { _, url in
            second.set()
            _ = newGate.wait(timeout: .now() + 10)
            return UsageNode(url: url, name: "new", isFolder: true, kind: .folders)
        }) { delivered.append($0.name) }
        try await octoberEventually { second.isSet }
        oldGate.signal()
        try await octoberEventually { returned.isSet }
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered.isEmpty)
        newGate.signal()
        try await octoberEventually { delivered.count == 2 }
        #expect(delivered == ["new", "new"])
        #expect(UsageCache.node(for: f.root)?.name == "new")
    }

    @Test func aWatchReconnectsAfterThePathIsTemporarilyMissing() async throws {
        let f = try OctoberFiles(), target = f.url("watched")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        var ready = false, changes = 0
        watcher.onChange = { changes += 1 }
        watcher.watch(target) { ready = true }
        try await octoberEventually { ready }
        try FileManager.default.moveItem(at: target, to: f.url("old"))
        try await octoberEventually { !watcher.isWatching && changes > 0 }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try await octoberEventually { watcher.isWatching }
        let before = changes
        try f.file("watched/new.txt")
        try await octoberEventually { changes > before }
    }

    @Test func aViewerGalleryAlwaysContainsTheExplicitlyChosenPicture() async throws {
        _ = NSApplication.shared
        let f = try OctoberFiles()
        try octoberPicture(f.url("root.png"))
        try f.file("child/chosen.png")
        let chosen = FileItem(url: f.url("child/chosen.png"))
        let tab = ExplorerTab(location: .folder(f.root))
        defer { tab.tearDown() }
        try await octoberEventually { tab.items.count == 2 }
        #expect(tab.picturesForViewer(chosen).map(\.key) == [chosen.key])
        tab.setViewMode(.columns)
        let child = try #require(tab.items.firstIndex { $0.name == "child" })
        tab.columns.browser.selectRow(child, inColumn: 0)
        try await octoberEventually { tab.columns.browser.numberOfRows(inColumn: 1) == 1 }
        tab.columns.browser.selectRow(0, inColumn: 1)
        #expect(tab.picturesForViewer(chosen).map(\.key) == [chosen.key])
    }

    @Test func cancellingRunningWorkReleasesTheNextQueuedJob() async throws {
        let work = BackgroundTask(queue: BackgroundTask.queue("test.october-cancel", limit: 1))
        let started = CancelFlag(), stopped = CancelFlag()
        var delivered: [Int] = []
        work.runCancellable({ cancelled in
            started.set()
            let deadline = Date().addingTimeInterval(10)
            while !cancelled.isSet && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            stopped.set()
            return 1
        }) { delivered.append($0) }
        try await octoberEventually { started.isSet }
        work.run({ 2 }) { delivered.append($0) }
        try await octoberEventually { stopped.isSet && delivered == [2] }
    }
}

extension Viewer {
    @Test func slowCopyImagePreservesANewerClipboardChange() async throws {
        _ = NSApplication.shared
        let f = try OctoberFiles(), picture = f.url("picture.png")
        try octoberPicture(picture)
        let previous = UserDefaults.standard.object(forKey: "viewerFullScreen")
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        defer { UserDefaults.standard.set(previous, forKey: "viewerFullScreen") }
        ImageViewer.show([picture], at: 0)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.isVisible })
        defer { window.close() }
        let viewer = try #require(window.viewer), board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let started = CancelFlag(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var done = false
        viewer.copyImage(to: board, prepare: { _, _ in
            started.set()
            _ = gate.wait(timeout: .now() + 10)
            return Data([1, 2, 3])
        }, done: { done = true })
        try await octoberEventually { started.isSet }
        board.clearContents()
        board.setString("newer copy", forType: .string)
        let revision = board.changeCount
        gate.signal()
        try await octoberEventually { done }
        #expect(board.changeCount == revision && board.string(forType: .string) == "newer copy")
        #expect(board.data(forType: .tiff) == nil)
    }

    @Test func finishingAnEarlierDeletionKeepsThePictureNowOnScreen() throws {
        _ = NSApplication.shared
        let f = try OctoberFiles()
        let urls = (0..<3).map { f.url("\($0).png") }
        for url in urls { try octoberPicture(url) }
        let previous = UserDefaults.standard.object(forKey: "viewerFullScreen")
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        defer { UserDefaults.standard.set(previous, forKey: "viewerFullScreen") }
        ImageViewer.show(urls, at: 0)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.isVisible })
        defer { window.close() }
        let viewer = try #require(window.viewer)
        var finish: (([URL]) -> Void)?
        viewer.deleteCurrent(using: { requested, done in
            #expect(requested.map(\.key) == [urls[0].key])
            finish = done
        })
        viewer.step(1)
        #expect(window.title == "1.png")
        finish?([urls[0]])
        #expect(window.title == "1.png" && viewer.filmstrip.current == 0)
        #expect(viewer.filmstrip.urls.map(\.key) == Array(urls.dropFirst()).map(\.key))
    }
}
