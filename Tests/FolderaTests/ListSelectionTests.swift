import AppKit
import ImageIO
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct ListSelection {
    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        Awake.hold()
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message))
    }

    private func folder(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaSelect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names { try "x".write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return url
    }

    /// Windows' Shift+click: the first click, then Shift on the tenth file.
    @Test func shiftClickTakesTheRangeFromTheAnchor() async throws {
        _ = NSApplication.shared
        let prefs = UserDefaults.standard
        let oldMode = prefs.object(forKey: "viewMode")
        prefs.set("details", forKey: "viewMode")
        let root = try folder((0..<12).map { String(format: "file %02d.txt", $0) })
        defer {
            prefs.set(oldMode, forKey: "viewMode")
            try? FileManager.default.removeItem(at: root)
        }
        let tab = ExplorerTab(location: .folder(root))
        defer { tab.watcher.stop() }
        try await eventually("folder read") { tab.items.count == 12 }

        // The first click lands on file 0 and selects it.
        tab.selectQuietly([tab.items[0].key])
        tab.listClicked(at: 0, command: false)
        // Shift+click on file 9 takes everything in between.
        #expect(tab.extendSelection(to: 9))
        #expect(tab.selectedIndexes == Array(0...9))
        // A second Shift+click moves the far end, not the anchor.
        #expect(tab.extendSelection(to: 4))
        #expect(tab.selectedIndexes == Array(0...4))
        // A click on another file moves the anchor; Shift+click extends from it.
        tab.selectQuietly([tab.items[7].key])
        tab.listClicked(at: 7, command: false)
        #expect(tab.extendSelection(to: 10))
        #expect(tab.selectedIndexes == Array(7...10))
        // A Command+click leaves the anchor where it was.
        tab.listClicked(at: 5, command: true)
        #expect(tab.extendSelection(to: 9))
        #expect(tab.selectedIndexes == Array(7...9))
    }

    /// One picture selected: the status bar names it, its pixel size, and the rest.
    @Test func theStatusBarNamesThePictureAndItsSize() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.png")
        let context = try #require(CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let tab = ExplorerTab(location: .folder(root))
        defer { tab.watcher.stop() }
        try await eventually("folder read") { tab.items.count == 1 }
        tab.selectQuietly([tab.items[0].key])
        tab.listSelectionDidChange()
        try await eventually("status shows the picture's size") {
            tab.statusLabel.stringValue.contains("300 × 200 px")
        }
        #expect(tab.statusLabel.stringValue.contains("picture.png"))
    }
}
