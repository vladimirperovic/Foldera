import AppKit
import ImageIO
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct Viewer {
    /// The message is put together when the wait is over, to say how things
    /// stood. Long, since the other suites can keep the main thread for
    /// seconds on a busy CI Mac.
    private func eventually(_ message: @autoclosure () -> String = "condition", _ condition: () -> Bool) async throws {
        Awake.hold()
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message()))
    }

    private func picture(_ url: URL, width: Int, height: Int) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aSmallPictureFillsTheWindowAndAClickShowsTheThumbnails() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaViewer-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let urls = (1...3).map { folder.appendingPathComponent("picture \($0).png") }
        for url in urls { try picture(url, width: 200, height: 100) }
        let oldFullScreen = UserDefaults.standard.object(forKey: "viewerFullScreen")
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        defer { UserDefaults.standard.set(oldFullScreen, forKey: "viewerFullScreen") }

        ImageViewer.show(urls, at: 0)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.isVisible })
        defer { window.close() }
        let viewer = try #require(window.viewer)
        // 200 pixels across is 100 points on a Retina screen; fit makes it as wide as the window allows.
        try await eventually("fitted") { viewer.magnification > 1.5 }
        #expect(viewer.fitMode)

        let tall = viewer.pictureArea.height
        viewer.clicked()
        try await eventually("""
            thumbnails: fit \(viewer.fitMode), \(viewer.magnification)×, \
            double click \(NSEvent.doubleClickInterval) s
            """) { !viewer.filmstrip.isHidden }
        #expect(viewer.pictureArea.height < tall) // The picture makes room for them.
        #expect(viewer.filmstrip.urls.count == 3)
        viewer.filmstrip.onPick?(2)
        #expect(window.title == "picture 3.png")
        #expect(viewer.filmstrip.current == 2)

        // A double click is full screen, not a click twice. (Held windowed here.)
        window.collectionBehavior = [.fullScreenNone]
        viewer.clicked()
        viewer.doubleClicked()
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
        #expect(!viewer.filmstrip.isHidden && !window.styleMask.contains(.fullScreen))
        viewer.toggleThumbnails(nil)
        #expect(viewer.filmstrip.isHidden && viewer.pictureArea.height == tall)

        // Two clicks, each its own: the first, still waiting when the second
        // comes (a busy Mac is late with it), is done then, not dropped.
        viewer.clicked()
        viewer.clicked()
        #expect(!viewer.filmstrip.isHidden)
        try await eventually("second click") { viewer.filmstrip.isHidden }
    }

    /// A tooltip lives in a tracking area of its own. The buttons used to
    /// remove every area when they refreshed their hover area, so no tooltip
    /// in the app ever showed, though each button had one.
    @Test func toolButtonsKeepTheirTooltipsWhenTheirAreasAreRefreshed() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = ToolButton(symbol: "doc.on.doc", tip: "Copy (⌘C)")
        button.frame = NSRect(x: 10, y: 10, width: 40, height: 30)
        window.contentView?.addSubview(button)
        window.orderFront(nil)
        button.updateTrackingAreas()
        let owners = button.trackingAreas.map { $0.owner.map { String(describing: type(of: $0)) } ?? "none" }
        #expect(owners.count >= 2, "a hover area and the tooltip's: \(owners)")
        button.updateTrackingAreas()
        button.updateTrackingAreas()
        #expect(button.trackingAreas.count == owners.count)
        #expect(button.toolTip == "Copy (⌘C)")
    }

    @Test func thePicturesMenuCopiesAndSaysWhatEachCommandDoes() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaViewerMenu-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let url = folder.appendingPathComponent("wide.png")
        try picture(url, width: 300, height: 200)
        let oldFullScreen = UserDefaults.standard.object(forKey: "viewerFullScreen")
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        defer { UserDefaults.standard.set(oldFullScreen, forKey: "viewerFullScreen") }

        ImageViewer.show([url], at: 0)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.isVisible })
        defer { window.close() }
        let viewer = try #require(window.viewer)
        try await eventually("shown") { viewer.magnification > 0.1 }

        let items = viewer.pictureMenu().items.filter { !$0.isSeparatorItem }
        let untold = items.filter { ($0.toolTip ?? "").isEmpty }.map(\.title)
        #expect(untold.isEmpty, "without a tooltip: \(untold)")
        let copy = try #require(items.first { $0.title == "Copy" })
        #expect(copy.keyEquivalent == "c" && copy.keyEquivalentModifierMask == .command)
        for title in ["Copy image", "Copy as path", "Copy text from image", "Open with", "Show in Foldera", "Move to Trash"] {
            #expect(items.contains { $0.title == title }, "missing \(title)")
        }
        // The tool bar's Copy button offers the same four, each with its tooltip.
        let copies = viewer.copyMenu().items
        #expect(copies.map(\.title) == ["Copy", "Copy image", "Copy as path", "Copy text from image"])
        #expect(copies.allSatisfy { !($0.toolTip ?? "").isEmpty })
        // Each of the viewer's own commands reaches it, and is on while a picture shows.
        for item in items where item.target === viewer {
            let action = try #require(item.action)
            #expect(viewer.responds(to: action), "\(item.title)")
            #expect(viewer.validateMenuItem(item), "\(item.title)")
        }

        // Copy image: the picture itself, full size and turned as it is shown.
        viewer.rotateRight(nil)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var copied = false
        viewer.copyImage(to: board) { copied = true }
        try await eventually("copied") { copied }
        let rep = try #require(NSImage(pasteboard: board)?.representations.first)
        #expect(rep.pixelsWide == 200 && rep.pixelsHigh == 300)
    }
}
