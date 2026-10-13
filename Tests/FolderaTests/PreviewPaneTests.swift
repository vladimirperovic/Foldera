import AppKit
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct DetachedPreview {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func button(_ id: String, in pane: PreviewPane) throws -> NSButton {
        try #require(descendants(of: pane).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == id })
    }

    private func click(_ button: NSButton) throws {
        // Deliver the real action without performClick's nested animation loop,
        // which can end the SwiftPM test host before its async tests complete.
        let action = try #require(button.action)
        #expect(button.sendAction(action, to: button.target))
    }

    @Test func detachingAndDockingPreservesTheMarkdownDraftWithoutSaving() async throws {
        _ = NSApplication.shared
        let old = UserDefaults.standard.object(forKey: "previewPane")
        Prefs.previewPane = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("draft.md")
        try "# Original".write(to: file, atomically: true, encoding: .utf8)
        let tab = ExplorerTab(location: .folder(root), select: [file])
        defer {
            // Don't invoke a save or conflict dialog during fixture cleanup.
            descendants(of: tab.previewPane).compactMap { $0 as? NSTextView }
                .forEach { $0.string = "# Original" }
            tab.tearDown()
            UserDefaults.standard.set(old, forKey: "previewPane")
            try? FileManager.default.removeItem(at: root)
        }
        // Wait for folder enumeration and the background Markdown read.
        var edit: NSButton?
        for _ in 0..<100 {
            edit = try button("preview.edit", in: tab.previewPane)
            if edit?.isEnabled == true && edit?.isHidden == false { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let editButton = try #require(edit)
        try #require(editButton.isEnabled && !editButton.isHidden)
        try click(editButton)
        let text = try #require(descendants(of: tab.previewPane).compactMap { $0 as? NSTextView }.first)
        text.string = "# Unsaved draft"
        let detach = try button("preview.detach", in: tab.previewPane)
        try click(detach)
        let detached = try #require(tab.previewWindow)
        #expect(detached.window?.contentView === tab.previewPane)
        #expect(detached.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
        #expect(!tab.split.arrangedSubviews.contains(tab.previewPane))
        #expect(text.string == "# Unsaved draft")
        #expect(TextFile.read(file) == "# Original")
        try click(detach)
        #expect(tab.previewWindow == nil)
        #expect(tab.previewPane.superview === tab.split)
        #expect(!tab.previewPane.isDetached)
        #expect(text.string == "# Unsaved draft")
        #expect(TextFile.read(file) == "# Original")
        #expect(editButton.title == "Done")
    }

    @Test func closingDocksButHidingAndClosingTheTabDisposeTheDetachedWindow() throws {
        _ = NSApplication.shared
        let old = UserDefaults.standard.object(forKey: "previewPane")
        Prefs.previewPane = true
        let tab = ExplorerTab(location: .thisMac)
        defer {
            tab.tearDown()
            UserDefaults.standard.set(old, forKey: "previewPane")
        }
        tab.togglePreviewDetachment(nil)
        let detached = try #require(tab.previewWindow)
        detached.closeTab(nil)
        #expect(tab.previewWindow == nil)
        #expect(tab.previewPane.superview === tab.split)
        #expect(detached.window?.contentView == nil)

        tab.togglePreviewDetachment(nil)
        Prefs.previewPane = false
        tab.applyPreviewPane()
        #expect(tab.previewWindow == nil)
        #expect(tab.previewPane.superview == nil)

        Prefs.previewPane = true
        tab.applyPreviewPane()
        tab.togglePreviewDetachment(nil)
        let lastWindow = try #require(tab.previewWindow?.window)
        tab.tearDown()
        #expect(tab.previewWindow == nil)
        #expect(!lastWindow.isVisible)
        #expect(tab.previewPane.superview == nil)
    }

    @Test func detachedDetailsFollowTheirOriginalTabAndLeaveOtherTabsIndependent() throws {
        _ = NSApplication.shared
        let old = UserDefaults.standard.object(forKey: "previewPane")
        Prefs.previewPane = true
        let tab = ExplorerTab(location: .thisMac)
        let other = ExplorerTab(location: .thisMac)
        defer {
            tab.tearDown()
            other.tearDown()
            UserDefaults.standard.set(old, forKey: "previewPane")
        }
        tab.togglePreviewDetachment(nil)
        let detached = try #require(tab.previewWindow)
        let folder = FileManager.default.temporaryDirectory
        tab.location = .folder(folder)
        tab.selectionChanged()
        #expect(detached.window?.representedURL == folder)
        #expect(other.previewWindow == nil)
        #expect(other.previewPane.superview === other.split)
        // Notifications that show Details must not take it out of its window.
        tab.applyPreviewPane()
        #expect(detached.window?.contentView === tab.previewPane)
    }
}
