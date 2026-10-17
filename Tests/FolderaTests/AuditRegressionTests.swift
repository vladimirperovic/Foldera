import AppKit
import Testing
@testable import Foldera

private final class AuditFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaAudit-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    @discardableResult func file(_ name: String, _ text: String = "text") throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor private func auditEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let end = Date().addingTimeInterval(15)
    while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

// Share BackgroundWork's serialization: these tests replace the same folder reader.
extension BackgroundWork {
    @Test(arguments: [ExplorerTab.ViewMode.details, .icons])
    func progressiveBatchesKeepTheSelectedFileWhenEarlierNamesArrive(mode: ExplorerTab.ViewMode) async throws {
        _ = NSApplication.shared
        let fixture = try AuditFolder()
        let first = try fixture.file("First/first.txt").deletingLastPathComponent()
        let slow = try fixture.file("Slow/a.txt").deletingLastPathComponent()
        for name in ["b.txt", "c.txt", "d.txt"] { try fixture.file("Slow/" + name) }
        let oldMode = UserDefaults.standard.object(forKey: "viewMode")
        defer { UserDefaults.standard.set(oldMode, forKey: "viewMode") }
        let original = ExplorerTab.readFolderInSteps
        let next = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        defer {
            ExplorerTab.readFolderInSteps = original
            for _ in 0..<8 { next.signal(); finish.signal() }
        }
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            let all = try original(url, hidden, { _ in })
            guard url.key == slow.key else { return all }
            Thread.sleep(forTimeInterval: 0.35)
            step(all.filter { ["b.txt", "c.txt"].contains($0.name) })
            _ = next.wait(timeout: .now() + 10)
            step(all.filter { $0.name != "d.txt" })
            _ = finish.wait(timeout: .now() + 10)
            return all
        }
        let tab = ExplorerTab(location: .folder(first))
        defer { tab.watcher.stop() }
        try await auditEventually { tab.items.count == 1 }
        tab.setViewMode(mode)
        tab.navigate(to: .folder(slow))
        try await auditEventually { tab.items.count == 2 && tab.waitingForFolder }
        tab.select(keys: [slow.appendingPathComponent("c.txt").key])
        next.signal()
        try await auditEventually { tab.items.count == 3 }
        #expect(tab.selectedItems.map(\.name) == ["c.txt"])
        finish.signal()
        try await auditEventually { tab.items.count == 4 && !tab.waitingForFolder }
        #expect(tab.selectedItems.map(\.name) == ["c.txt"])
    }

    @Test func removalDuringAnExistingReadCannotResurrectAFileAndUndoStillAppears() async throws {
        _ = NSApplication.shared
        let fixture = try AuditFolder()
        let removed = try fixture.file("a.txt")
        try fixture.file("b.txt")
        let tab = ExplorerTab(location: .folder(fixture.url))
        defer { tab.watcher.stop() }
        try await auditEventually { tab.items.count == 2 }
        tab.watcher.stop()
        let original = ExplorerTab.readFolderInSteps
        let gate = DispatchSemaphore(value: 0), started = CancelFlag()
        defer { ExplorerTab.readFolderInSteps = original; gate.signal() }
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            guard url.key == fixture.url.key else { return try original(url, hidden, step) }
            let before = try original(url, hidden, { _ in })
            started.set()
            _ = gate.wait(timeout: .now() + 10)
            return before
        }
        tab.reload()
        try await auditEventually { started.isSet }
        try FileManager.default.removeItem(at: removed)
        FileOps.announceRemoved([removed])
        #expect(tab.items.map(\.name) == ["b.txt"])
        gate.signal()
        try await Task.sleep(for: .milliseconds(150))
        #expect(tab.items.map(\.name) == ["b.txt"])
        ExplorerTab.readFolderInSteps = original
        try fixture.file("a.txt", "restored by Undo")
        tab.reload()
        try await auditEventually { tab.items.count == 2 }
    }

    @Test func anErrorAfterAProgressiveBatchRemainsVisible() async throws {
        _ = NSApplication.shared
        let fixture = try AuditFolder()
        let first = try fixture.file("First/a.txt").deletingLastPathComponent()
        let slow = try fixture.file("Slow/b.txt").deletingLastPathComponent()
        let original = ExplorerTab.readFolderInSteps
        let gate = DispatchSemaphore(value: 0)
        defer { ExplorerTab.readFolderInSteps = original; gate.signal() }
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            let all = try original(url, hidden, { _ in })
            guard url.key == slow.key else { return all }
            Thread.sleep(forTimeInterval: 0.35)
            step(all)
            _ = gate.wait(timeout: .now() + 10)
            throw CocoaError(.fileReadNoPermission)
        }
        let tab = ExplorerTab(location: .folder(first))
        defer { tab.watcher.stop() }
        try await auditEventually { tab.items.count == 1 }
        tab.navigate(to: .folder(slow))
        try await auditEventually { tab.waitingForFolder && tab.items.map(\.name) == ["b.txt"] }
        gate.signal()
        try await auditEventually { tab.loadError != nil && !tab.waitingForFolder }
        #expect(tab.items.isEmpty)
        #expect(!tab.emptyLabel.isHidden)
    }

    @Test func mergePlanningLeavesTheMainThreadFreeAndCancellationDiscardsThePlan() async throws {
        let fixture = try AuditFolder()
        let source = try fixture.file("From/Tree/child.txt").deletingLastPathComponent()
        let destination = try fixture.file("To/Tree/existing.txt").deletingLastPathComponent().deletingLastPathComponent()
        let gate = DispatchSemaphore(value: 0), started = CancelFlag(), cancelled = CancelFlag()
        defer { gate.signal() }
        var completed = false
        var result: Transfer.Plan?
        Transfer.planInBackground([source], into: destination, move: true, cancelled: cancelled, readDirectory: { folder in
            #expect(!Thread.isMainThread)
            started.set()
            _ = gate.wait(timeout: .now() + 10)
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }, ask: { _, _, _ in
            #expect(Thread.isMainThread)
            return (.merge, true)
        }, done: { result = $0; completed = true })
        try await auditEventually { started.isSet }
        // Reaching this main-actor code while enumeration waits is the responsiveness assertion.
        cancelled.set()
        gate.signal()
        try await auditEventually { completed }
        #expect(result == nil)
        #expect(FileOps.exists(source.appendingPathComponent("child.txt")))
        #expect(!FileOps.exists(destination.appendingPathComponent("Tree/child.txt")))
    }

    @Test func thumbnailFailureCompletesEveryWaiterAndAllowsRetry() async throws {
        var completions: [(NSImage?) -> Void] = []
        let thumbnails = Thumbnails(generator: { _, _, done in completions.append(done) })
        let url = URL(fileURLWithPath: "/unused/broken.jpg")
        var answers: [Bool] = []
        let cancelled = thumbnails.image(for: url, side: 64, scale: 2, version: nil) { _ in Issue.record("Cancelled waiter called") }
        for _ in 0..<2 {
            thumbnails.image(for: url, side: 64, scale: 2, version: nil) { answers.append($0 == nil) }
        }
        thumbnails.cancel(try #require(cancelled))
        #expect(completions.count == 1)
        completions[0](nil)
        try await auditEventually { answers.count == 2 }
        #expect(answers == [true, true])
        #expect(thumbnails.ready(for: url, side: 64, scale: 2, version: nil) == nil)
        var retried: NSImage?
        thumbnails.image(for: url, side: 64, scale: 2, version: nil) { retried = $0 }
        #expect(completions.count == 2)
        let picture = NSImage(size: NSSize(width: 64, height: 64))
        completions[1](picture)
        try await auditEventually { retried != nil }
        #expect(retried === picture)
    }

    @Test func historyReadsOffMainAndIgnoresAnObsoleteDetail() async throws {
        _ = NSApplication.shared
        let setup = SyncWindow.Setup(left: "/left", right: "/right", mode: .update)
        let first = SyncLibrary.Record(profileName: "Slow first run", setup: setup, started: Date())
        let second = SyncLibrary.Record(profileName: "Latest selected run", setup: setup, started: Date())
        let started = CancelFlag(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let controller = SyncHistoryWindow(readRecords: {
            #expect(!Thread.isMainThread)
            return [first, second]
        }, readRecord: { record in
            #expect(!Thread.isMainThread)
            if record.id == first.id {
                started.set()
                _ = gate.wait(timeout: .now() + 10)
            }
            return record
        })
        defer { controller.close() }
        try await auditEventually { started.isSet }
        controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        gate.signal()
        try await auditEventually { controller.details.string.contains("Latest selected run") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!controller.details.string.contains("Slow first run"))
    }
}

@Suite(.serialized) struct AuditFiles {
    @Test func enumerationErrorAfterOneEntryIsThrownInsteadOfReturningPartialSuccess() throws {
        let fixture = try AuditFolder()
        let file = try fixture.file("first.txt")
        #expect(throws: (any Error).self) {
            try FileItem.contents(of: fixture.url, showHidden: true, enumerate: { root, _, _, error in
                var count = 0
                return AnyIterator {
                    count += 1
                    if count == 1 { return file }
                    #expect(!error(root, CocoaError(.fileReadNoPermission)))
                    return nil
                }
            })
        }
    }

    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian])
    func savingUnicodePreservesEncodingAndByteOrderMark(encoding: String.Encoding) throws {
        let fixture = try AuditFolder(), file = fixture.url.appendingPathComponent("notes.md")
        let prefixes: [String.Encoding: [UInt8]] = [.utf8: [0xef, 0xbb, 0xbf], .utf16LittleEndian: [0xff, 0xfe],
            .utf16BigEndian: [0xfe, 0xff], .utf32LittleEndian: [0xff, 0xfe, 0, 0], .utf32BigEndian: [0, 0, 0xfe, 0xff]]
        let prefix = Data(try #require(prefixes[encoding]))
        let original = try #require("Čć Žš 😀".data(using: encoding))
        try (prefix + original).write(to: file)
        #expect(TextFile.read(file) == "Čć Žš 😀")
        try TextFile.write("Promijenjeno: čćšžđ 😀", to: file)
        let saved = try Data(contentsOf: file)
        let expected = try #require("Promijenjeno: čćšžđ 😀".data(using: encoding))
        #expect(saved == prefix + expected)
        #expect(TextFile.read(file) == "Promijenjeno: čćšžđ 😀")
    }

    @Test func ambiguousLegacyTextCannotBeSilentlyConverted() throws {
        let fixture = try AuditFolder(), file = fixture.url.appendingPathComponent("legacy.md")
        // Windows-1250: ČćŠšŽž. These bytes are not valid UTF-8.
        let original = Data([0xc8, 0xe6, 0x8a, 0x9a, 0x8e, 0x9e])
        try original.write(to: file)
        #expect(TextFile.read(file) == nil)
        #expect(throws: (any Error).self) { try TextFile.write("replacement", to: file) }
        #expect(try Data(contentsOf: file) == original)
        let plain = try fixture.file("plain.md", "before")
        try TextFile.write("after č", to: plain)
        #expect(try Data(contentsOf: plain) == Data("after č".utf8))
    }

    @Test func delayedArchiveCleanupCannotRemoveAnArchiveOpenedAtLaunch() throws {
        let fixture = try AuditFolder()
        let cache = try fixture.file("Archives/old/file.txt").deletingLastPathComponent().deletingLastPathComponent()
        var detached: URL?
        try ArchiveFolders.prepareForLaunch(at: cache) { detached = $0 }
        #expect(!FileOps.exists(cache))
        let current = try fixture.file("Archives/new/file.txt", "new extraction")
        try FileManager.default.removeItem(at: #require(detached))
        #expect(try String(contentsOf: current, encoding: .utf8) == "new extraction")
    }

    @Test func schedulesRefreshMovedExecutablesAndRejectTranslocatedCopies() throws {
        let fixture = try AuditFolder()
        let plist = fixture.url.appendingPathComponent("agent.plist")
        let old = URL(fileURLWithPath: "/Applications/Old Foldera.app/Contents/MacOS/Foldera")
        let new = URL(fileURLWithPath: "/Applications/Foldera.app/Contents/MacOS/Foldera")
        try PropertyListSerialization.data(fromPropertyList: SyncAgent.configuration(executable: old, library: fixture.url),
                                          format: .xml, options: 0).write(to: plist)
        var commands: [[String]] = []
        try SyncAgent.refresh(executable: new, library: fixture.url, plistURL: plist, active: true) {
            commands.append($0); return (0, "")
        }
        #expect(commands.map { $0[0] } == ["print", "bootout", "bootstrap"])
        let saved = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect(saved["ProgramArguments"] as? [String] == [new.path, "--sync-scheduler"])
        let data = try Data(contentsOf: plist)
        #expect(throws: (any Error).self) {
            try SyncAgent.refresh(executable: URL(fileURLWithPath: "/private/var/folders/AppTranslocation/id/Foldera"),
                                  library: fixture.url, plistURL: plist, active: true) { _ in
                Issue.record("Transient copies must not change launchd"); return (0, "")
            }
        }
        #expect(try Data(contentsOf: plist) == data)
        commands = []
        try SyncAgent.refresh(executable: new, library: fixture.url, plistURL: plist, active: true) {
            commands.append($0); return (0, "")
        }
        #expect(commands.map { $0[0] } == ["print"])
    }

    @Test func renameCancellationStopsBetweenFilesAndRestoresParkedSwaps() throws {
        let fixture = try AuditFolder()
        let a = try fixture.file("a.txt", "A"), b = try fixture.file("b.txt", "B")
        let cancelled = CancelFlag()
        let rows = [BatchRename.Row(item: FileItem(url: a), newName: "new-a.txt"),
                    BatchRename.Row(item: FileItem(url: b), newName: "new-b.txt")]
        let result = BatchRename.perform(rows, cancelled: cancelled) { url, name in
            let renamed = try FileOps.rename(url, to: name)
            cancelled.set()
            return renamed
        }
        #expect(result.changes.count == 1 && result.failures.isEmpty)
        #expect(FileOps.exists(b) && !FileOps.exists(rows[1].target))
        _ = try FileOps.rename(rows[0].target, to: "a.txt")
        let swap = [BatchRename.Row(item: FileItem(url: a), newName: "b.txt"),
                    BatchRename.Row(item: FileItem(url: b), newName: "a.txt")]
        let stop = CancelFlag()
        let swapped = BatchRename.perform(swap, cancelled: stop) { url, name in
            let renamed = try FileOps.rename(url, to: name)
            stop.set()
            return renamed
        }
        #expect(swapped.changes.isEmpty && swapped.failures.isEmpty)
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).sorted() == ["a.txt", "b.txt"])
    }
}
