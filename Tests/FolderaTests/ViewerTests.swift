import AppKit
import ImageIO
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct Viewer {
    private func eventually(_ message: String = "condition", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message))
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
        try await eventually("thumbnails") { !viewer.filmstrip.isHidden }
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
    }
}
