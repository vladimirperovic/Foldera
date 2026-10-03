import AppKit
import Testing
@testable import Foldera

extension SyncTestIsolation {
@Suite(.serialized) @MainActor struct SyncScreen {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Sync should finish comparing or replanning")
    }

    @Test func compareDirectionAndModeChangesProduceThePlanThatSynchronizeExecutes() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaSyncScreen-\(UUID().uuidString)")
        let left = root.appendingPathComponent("Left")
        let right = root.appendingPathComponent("Right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try "left".write(to: left.appendingPathComponent("left.txt"), atomically: false, encoding: .utf8)
        try "right".write(to: right.appendingPathComponent("right.txt"), atomically: false, encoding: .utf8)
        let prefs = UserDefaults.standard
        let recent = prefs.object(forKey: "syncRecent")
        let frame = prefs.object(forKey: "NSWindow Frame SyncWindow")
        let memory = Sync.Memory.folder
        let library = SyncLibrary.folder
        SyncLibrary.folder = root.appendingPathComponent("Library")
        Sync.Memory.folder = root.appendingPathComponent("Memory")
        let sync = SyncWindow(.init(left: left.key, right: right.key, mode: .mirror))
        defer {
            sync.window?.close()
            prefs.set(recent, forKey: "syncRecent")
            prefs.set(frame, forKey: "NSWindow Frame SyncWindow")
            Sync.Memory.folder = memory
            SyncLibrary.folder = library
            try? fm.removeItem(at: root)
        }
        #expect(!sync.canSynchronize && sync.plannedRows.isEmpty)
        sync.compare(nil)
        try await waitUntil { sync.canSynchronize }
        #expect(sync.plannedRows.first { $0.name == "left.txt" }?.action == .toRight)
        #expect(sync.plannedRows.first { $0.name == "right.txt" }?.action == .deleteRight)
        #expect(!fm.fileExists(atPath: right.appendingPathComponent("left.txt").path))

        sync.selectFilter(.deletions)
        #expect(sync.visibleRows.count == 1 && sync.visibleRows[0].action == .deleteRight)
        #expect(sync.plannedRows.count == 2 && sync.canSynchronize)
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let table = try #require(sync.window?.contentView.flatMap { tables(in: $0).first })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let skip = NSMenuItem()
        skip.tag = 4
        _ = sync.perform(NSSelectorFromString("setAction:"), with: skip)
        #expect(sync.plannedRows.first { $0.name == "right.txt" }?.action == Sync.Action.none)
        #expect(sync.plannedRows.first { $0.name == "left.txt" }?.action == .toRight)
        sync.selectMode(.mirror)
        try await waitUntil { sync.canSynchronize && sync.plannedRows.contains { $0.action == .deleteRight } }
        sync.selectFilter(.conflicts)
        #expect(sync.visibleRows.isEmpty && sync.canSynchronize)
        sync.selectFilter(.all)
        sync.switchDirection(nil)
        #expect(!sync.canSynchronize)
        try await waitUntil { sync.canSynchronize }
        #expect(sync.plannedRows.first { $0.name == "right.txt" }?.action == .toLeft)
        #expect(sync.plannedRows.first { $0.name == "left.txt" }?.action == .deleteLeft)
        sync.selectMode(.update)
        #expect(!sync.canSynchronize)
        try await waitUntil { sync.canSynchronize }
        #expect(sync.plannedRows.first { $0.name == "left.txt" }?.action == Sync.Action.none)
        sync.synchronize(nil)
        #expect(sync.isSynchronizing)
        try await waitUntil { !sync.isSynchronizing && !sync.canSynchronize }
        #expect(try String(contentsOf: left.appendingPathComponent("right.txt"), encoding: .utf8) == "right")
        #expect(try String(contentsOf: left.appendingPathComponent("left.txt"), encoding: .utf8) == "left")
        #expect(!fm.fileExists(atPath: right.appendingPathComponent("left.txt").path))
        let records = try SyncLibrary.records()
        #expect(records.count == 1 && records[0].copied == 1 && records[0].status == .success)
        #expect(records[0].events.first?.path == "right.txt")
    }

    @Test func loadingASavedProfileRestoresFoldersModeAndDirectionAndShowsItsSchedule() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaSyncProfileUI-\(UUID().uuidString)")
        let left = root.appendingPathComponent("Left")
        let right = root.appendingPathComponent("Right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try "right".write(to: right.appendingPathComponent("right.txt"), atomically: false, encoding: .utf8)
        let library = SyncLibrary.folder
        let memory = Sync.Memory.folder
        SyncLibrary.folder = root.appendingPathComponent("Library")
        Sync.Memory.folder = root.appendingPathComponent("Memory")
        let prefs = UserDefaults.standard
        let recent = prefs.object(forKey: "syncRecent")
        let frame = prefs.object(forKey: "NSWindow Frame SyncWindow")
        try "excluded".write(to: right.appendingPathComponent("skip.tmp"), atomically: false, encoding: .utf8)
        let setup = SyncWindow.Setup(left: left.path, right: right.path, mode: .update, towardLeft: true, excludes: "*.tmp")
        var profile = SyncLibrary.Profile(name: "Test backup", setup: setup, schedule: .init(frequency: .daily), pausedReason: "Review the previous run")
        profile = try SyncLibrary.save(profile)
        let sync = SyncWindow(.init())
        defer {
            sync.window?.close()
            prefs.set(recent, forKey: "syncRecent")
            prefs.set(frame, forKey: "NSWindow Frame SyncWindow")
            SyncLibrary.folder = library
            Sync.Memory.folder = memory
            try? fm.removeItem(at: root)
        }
        sync.loadProfile(profile.id)
        #expect(!sync.canSynchronize)
        sync.compare(nil)
        try await waitUntil { sync.canSynchronize }
        #expect(sync.plannedRows.first?.action == .toLeft)
        sync.selectFilter(.deletions)
        #expect(sync.visibleRows.isEmpty && sync.canSynchronize)
        sync.synchronize(nil)
        try await waitUntil { !sync.isSynchronizing && !sync.canSynchronize }
        #expect(try String(contentsOf: left.appendingPathComponent("right.txt"), encoding: .utf8) == "right")
        #expect(!fm.fileExists(atPath: left.appendingPathComponent("skip.tmp").path))
        #expect(try SyncLibrary.profiles().first?.pausedReason == nil)
        #expect(try SyncLibrary.profiles().first?.nextRun != nil)
        #expect(try SyncLibrary.records().first?.profileID == profile.id)
    }

    @Test func toolbarOpensSeparateSyncWindowUsingBothPanesInTheirDisplayedOrder() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaSyncLaunch-\(UUID().uuidString)")
        let left = root.appendingPathComponent("Left")
        let right = root.appendingPathComponent("Right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        let prefs = UserDefaults.standard
        let keys = ["secondPaneFolder", "twoPanes", "syncRecent", "NSWindow Frame SyncWindow"]
        let saved = keys.map { prefs.object(forKey: $0) }
        prefs.set(right.path, forKey: "secondPaneFolder")
        SyncWindow.Setup.recent = [.init(left: right.key, right: left.key, mode: .update)]
        let library = SyncLibrary.folder
        SyncLibrary.folder = root.appendingPathComponent("Library")
        let tab = ExplorerTab(location: .folder(left))
        let host = ExplorerWindow(first: tab)
        var opened: NSWindow?
        defer {
            opened?.close()
            host.window?.close()
            SyncLibrary.folder = library
            for (key, value) in zip(keys, saved) { prefs.set(value, forKey: key) }
            try? fm.removeItem(at: root)
        }
        host.showTwoPanes(true)
        let partner = try #require(host.partner)
        #expect(partner.syncButton.action == #selector(ExplorerTab.openSync(_:)))
        partner.openSync(partner.syncButton)
        opened = NSApp.windows.first { $0.isVisible && $0.windowController is SyncWindow }
        let window = try #require(opened)
        let content = try #require(window.contentView)
        func fields(in view: NSView) -> [FolderField] {
            (view as? FolderField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        #expect(fields(in: content).compactMap { $0.url?.key } == [left.key, right.key])
        #expect(host.partner === partner && host.selected === tab)
        #expect(host.tabs.count == 1 && host.rightTabs.count == 1)
        let syncMenu = try #require(MainMenu.build().item(withTitle: "Sync")?.submenu)
        #expect(syncMenu.items.first?.action == #selector(ExplorerTab.openSync(_:)))
    }
}

}
