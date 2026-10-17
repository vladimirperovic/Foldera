import AppKit
import ImageIO
import Testing
@testable import Foldera

extension FollowupFilmstrip {
    @Test func hidingARealFilmstripDoesNotPublishItsPendingThumbnail() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaHiddenStrip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let strip = Filmstrip(frame: NSRect(x: 0, y: 0, width: 600, height: Filmstrip.height))
        let window = NSWindow(contentRect: strip.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        window.orderFront(nil)
        defer { strip.urls = []; window.close() }
        strip.urls = [url]
        strip.layoutSubtreeIfNeeded()
        let scroll = try #require(strip.subviews.first as? NSScrollView)
        let grid = try #require(scroll.documentView as? NSCollectionView)
        grid.layoutSubtreeIfNeeded()
        #expect(!grid.visibleItems().isEmpty)
        strip.isHidden = true
        try await Task.sleep(for: .milliseconds(1000))
        let cached = Thumbnails.shared.ready(for: url, side: Filmstrip.side, scale: window.backingScaleFactor, version: nil)
        print("FOLLOWUP filmstrip: pending thumbnail published after hiding=\(cached != nil)")
        #expect(cached == nil)
    }
}
