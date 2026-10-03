import AppKit
import Testing
@testable import Foldera

@Suite @MainActor struct PaneTabs {
    @Test func rightTabsStayIndependentAndClosingTheirLastTabReturnsToOnePane() throws {
        _ = NSApplication.shared
        let prefs = UserDefaults.standard
        let oldTwoPanes = prefs.object(forKey: "twoPanes")
        let oldFolder = prefs.object(forKey: "secondPaneFolder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaPaneTabs-\(UUID().uuidString)")
        let leftFolder = root.appendingPathComponent("Left")
        let rightFolder = root.appendingPathComponent("Right")
        try FileManager.default.createDirectory(at: leftFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightFolder, withIntermediateDirectories: true)
        prefs.set(rightFolder.path, forKey: "secondPaneFolder")
        defer {
            prefs.set(oldTwoPanes, forKey: "twoPanes")
            prefs.set(oldFolder, forKey: "secondPaneFolder")
            try? FileManager.default.removeItem(at: root)
        }

        let left = ExplorerTab(location: .folder(leftFolder))
        let host = ExplorerWindow(first: left)
        defer { host.window?.close() }
        host.showTwoPanes(true)
        let firstRight = try #require(host.partner)
        #expect(host.rightTabs.count == 1)
        #expect(firstRight.split.arrangedSubviews.first?.isHidden == false)

        let secondRight = ExplorerTab(location: .folder(rightFolder), secondPane: true)
        host.add(secondRight)
        #expect(host.rightTabs.count == 2)
        #expect(host.partner === secondRight)
        #expect(host.selected === left && host.tabs.count == 1)
        host.select(firstRight)
        #expect(host.partner === firstRight)
        host.select(left)
        QuickOpenController.activate(QuickOpenItem(title: "Right tab", detail: "", kind: .tab,
                                                  destination: .tab(secondRight)), from: left)
        #expect(host.partner === secondRight && host.selected === left)
        host.duplicate(firstRight)
        let duplicated = try #require(host.partner)
        #expect(duplicated !== firstRight && host.rightTabs.count == 3)
        host.closeOthers(duplicated)
        #expect(host.rightTabs.count == 1 && host.partner === duplicated)
        #expect(host.tabs.count == 1 && host.selected === left)
        host.closeTab(nil)
        #expect(host.partner == nil && host.rightTabs.isEmpty)
        #expect(host.selected === left)
        host.showTwoPanes(true)
        #expect(host.rightTabs.count == 1 && host.partner != nil)
        host.showTwoPanes(false)
        #expect(host.rightTabs.isEmpty && host.partner == nil)
    }
}
