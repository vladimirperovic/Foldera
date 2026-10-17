import AppKit
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct BackgroundWork {
    private func eventually(_ message: String = "condition", _ condition: () -> Bool) async throws {
        Awake.hold()
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message))
    }

    @Test func obsoleteWorkCannotOverwriteTheLatestResult() async throws {
        let queue = BackgroundTask.queue("test.latest", limit: 1)
        let task = BackgroundTask(queue: queue)
        let started = CancelFlag()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var delivered: [Int] = []
        task.run({ started.set(); _ = gate.wait(timeout: .now() + 5); return 1 }) { delivered.append($0) }
        try await eventually { started.isSet }
        // The main actor remains available while the slow read is running.
        task.run({ 2 }) { delivered.append($0) }
        task.run({ 3 }) { delivered.append($0) }
        gate.signal()
        try await eventually { delivered == [3] }
        #expect(delivered == [3])
    }

    @Test func cancellationAlsoDropsACompletionAlreadyOnTheMainQueue() async throws {
        let queue = BackgroundTask.queue("test.completion")
        let task = BackgroundTask(queue: queue)
        var delivered = false
        task.run({ 1 }) { _ in delivered = true }
        // The worker can finish, but its main-thread callback cannot run yet.
        let finished = DispatchSemaphore(value: 0)
        queue.addBarrierBlock { finished.signal() }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        task.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!delivered)
    }

    @Test func backgroundConcurrencyStaysBoundedDuringRapidNavigation() async throws {
        let queue = BackgroundTask.queue("test.bounded", limit: 2)
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var active = 0
        var peak = 0
        let tasks = (0..<12).map { _ in BackgroundTask(queue: queue) }
        var completed = 0
        for task in tasks {
            task.run({
                lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
                _ = gate.wait(timeout: .now() + 5)
                lock.lock(); active -= 1; lock.unlock()
            }) { _ in completed += 1 }
        }
        try await eventually { lock.lock(); defer { lock.unlock() }; return active == 2 }
        for _ in tasks { gate.signal() }
        try await eventually { completed == tasks.count }
        #expect(peak == 2)
    }

    @Test func stoppedWatcherCannotReopenOrReportALateChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DirectoryWatcher()
        var changes = 0
        watcher.onChange = { changes += 1 }
        watcher.watch(folder)
        watcher.stop()
        try "later".write(to: folder.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(watcher.isIdle && changes == 0)
    }

    @Test func aFolderThatKeepsChangingIsReadOneTimeAfterAnother() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaPaced-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        // A slow disk for this folder only: each read waits to be let through.
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads = 0, active = 0, peak = 0
        func counts() -> (reads: Int, active: Int, peak: Int) { lock.lock(); defer { lock.unlock() }; return (reads, active, peak) }
        let original = ExplorerTab.readFolder
        ExplorerTab.readFolder = { url, hidden in
            guard url.key == folder.key else { return try original(url, hidden) }
            lock.lock(); reads += 1; active += 1; peak = max(peak, active); lock.unlock()
            _ = gate.wait(timeout: .now() + 5)
            lock.lock(); active -= 1; lock.unlock()
            return try original(url, hidden)
        }
        defer {
            ExplorerTab.readFolder = original
            for _ in 0..<8 { gate.signal() }
        }

        let tab = ExplorerTab(location: .folder(folder))
        defer { tab.watcher.stop() }
        try await eventually("first read started") { counts().active == 1 }
        try "new".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<5 { tab.watcher.onChange?() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(counts().reads == 1) // Changes during a read wait for it.

        gate.signal()
        try await eventually("read again once") { counts().active == 1 && counts().reads == 2 }
        for _ in 0..<5 { tab.watcher.onChange?() }
        // The changes during the second read bring exactly one more; both are let through.
        gate.signal()
        gate.signal()
        try await eventually("third read") { counts().reads == 3 && counts().active == 0 }
        try await eventually("shown") { tab.items.contains { $0.name == "new.txt" } }
        try await Task.sleep(for: .milliseconds(600))
        #expect(counts().reads == 3)
        #expect(counts().peak == 1)
    }

    @Test func aSlowFolderDoesNotShowTheOneLeftBehind() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaOpening-\(UUID().uuidString)")
        let first = root.appendingPathComponent("First"), slow = root.appendingPathComponent("Slow")
        for folder in [first, slow] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        try "a".write(to: first.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: slow.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        // A slow disk for the second folder only.
        let gate = DispatchSemaphore(value: 0)
        let original = ExplorerTab.readFolder
        ExplorerTab.readFolder = { url, hidden in
            if url.key == slow.key { _ = gate.wait(timeout: .now() + 5) }
            return try original(url, hidden)
        }
        defer {
            ExplorerTab.readFolder = original
            for _ in 0..<4 { gate.signal() }
        }
        func shows(_ name: String) -> Bool { tab.items.contains { $0.name == name } }

        let tab = ExplorerTab(location: .folder(first))
        defer { tab.watcher.stop() }
        try await eventually("first folder") { shows("a.txt") }
        tab.navigate(to: .folder(slow))
        #expect(shows("a.txt") && !tab.waitingForFolder) // No blink while a fast read could still arrive.
        try await eventually("old folder gone") { tab.waitingForFolder && tab.items.isEmpty }
        #expect(tab.emptyLabel.stringValue == "Working on it…" && !tab.emptyLabel.isHidden)
        #expect(!tab.statusLabel.stringValue.contains("item"))
        gate.signal()
        try await eventually("new folder") { shows("b.txt") && !tab.waitingForFolder }
        #expect(tab.emptyLabel.isHidden)

        // Reading the same folder again keeps it on screen.
        tab.reload()
        try await Task.sleep(for: .milliseconds(400))
        #expect(shows("b.txt") && !tab.waitingForFolder)
        gate.signal()
    }

    @Test func expandedSidebarTracksNewFoldersAndRefreshPreservesBranches() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaSidebar-\(UUID().uuidString)")
        let first = root.appendingPathComponent("First")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldPins = UserDefaults.standard.object(forKey: "pinned")
        Pins.urls = [root]
        defer {
            UserDefaults.standard.set(oldPins, forKey: "pinned")
            NotificationCenter.default.post(name: .explorerPinsChanged, object: nil)
        }
        let sidebar = Sidebar()
        defer { sidebar.stop() }
        let outline = sidebar.outline
        let section = try #require(sidebar.outlineView(outline, child: 0, ofItem: nil) as? SidebarNode)
        try await eventually("section loaded") { !section.loading }
        let node = try #require(section.children?.first { $0.url?.key == root.key })
        outline.expandItem(node)
        try await eventually("root loaded") { node.children?.contains { $0.url?.key == first.key } == true }
        let child = try #require(node.children?.first)
        #expect(child.isExpandable) // Empty today must not mean permanently unexpandable.
        outline.expandItem(child)
        try await eventually("empty folder loaded") { child.children?.isEmpty == true && !child.loading }
        let added = first.appendingPathComponent("Added")
        try fm.createDirectory(at: added, withIntermediateDirectories: true)
        try await eventually("new child appeared") { child.children?.contains { $0.url?.key == added.key } == true }
        try fm.removeItem(at: added)
        sidebar.refresh()
        try await eventually("removed child disappeared") { child.children?.isEmpty == true && !child.loading }
        #expect(node.children?.first === child)
        #expect(outline.isItemExpanded(node))
    }

    @Test func treeFoldersCanGoToTheTrashButDrivesCannot() throws {
        _ = NSApplication.shared
        let sidebar = Sidebar()
        defer { sidebar.stop() }
        let folder = SidebarNode(.folder, url: FileManager.default.temporaryDirectory, title: "tmp")
        let drive = SidebarNode(.volume, url: URL(fileURLWithPath: "/"), title: "Macintosh HD")
        let titles = { (node: SidebarNode) in sidebar.menu(for: node)?.items.map(\.title) ?? [] }
        #expect(titles(folder).contains("Move to Trash"))
        #expect(!titles(drive).contains("Move to Trash"))
        #expect(sidebar.focusedFolder == nil) // Nothing picked, no keyboard: the list's selection counts.
    }

    @Test func addressCompletionHandlesSpacesAndCommonPrefixes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaCompletion-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for name in ["My folder", "My photos", "Music"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(AddressBar.completedPath(root.path + "/My") == root.path + "/My ")
        #expect(AddressBar.completedPath(root.path + "/my f") == root.path + "/My folder/")
        #expect(AddressBar.completedPath(root.path + "/missing") == nil)
    }
}
