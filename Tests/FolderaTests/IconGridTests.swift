import AppKit
import ImageIO
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct IconGrid {
    private func eventually(_ message: String = "condition", _ condition: () -> Bool) async throws {
        Awake.hold()
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message))
    }

    /// How many tiles a row of this geometry holds, and whether they fill it exactly.
    private func columns(_ g: IconGeometry, width: CGFloat) -> CGFloat {
        ((width - g.left - g.right + g.gap) / (g.tile.width + g.gap)).rounded()
    }

    @Test func rowsAreFilledInsteadOfSpreadingTheirGaps() {
        for width: CGFloat in [700, 1000, 1243, 1600] {
            for side: CGFloat in [48, 64, 100, 180, 240] {
                let g = IconGeometry(side: side, width: width, scale: 2)
                let n = columns(g, width: width)
                #expect(g.left + g.right + n * g.tile.width + (n - 1) * g.gap == width)
                // Only what pixel-aligned tiles leave over: under a pixel per tile.
                #expect((g.left - g.margin) + (g.right - g.margin) < n / 2)
                #expect(g.side >= side && g.names)
            }
        }
    }

    @Test func gapsShrinkAsPicturesGrowAndVanishAtTheLargest() {
        var last = IconGeometry(side: 48, width: 1200, scale: 2)
        #expect(last.gap == 4 && last.margin == 10 && last.top == 8)
        for side in stride(from: CGFloat(56), to: IconGeometry.largest, by: 8) {
            let g = IconGeometry(side: side, width: 1200, scale: 2)
            #expect(g.gap <= last.gap && g.margin <= last.margin && g.top <= last.top)
            #expect(g.tile.height - g.side - g.top <= last.tile.height - last.side - last.top)
            last = g
        }
        let sheet = IconGeometry(side: IconGeometry.largest, width: 1243, scale: 2)
        #expect(!sheet.names && sheet.gap == 0 && sheet.margin == 0 && sheet.top == 0)
        #expect(sheet.tile.width == sheet.tile.height && sheet.side == sheet.tile.width)
        let n = columns(sheet, width: 1243)
        #expect(sheet.left + sheet.right + n * sheet.tile.width == 1243)
        #expect(sheet.left + sheet.right < n / 2) // Under a pixel per tile, at the edges only.
    }

    @Test func aNarrowPaneHasOneTileThatFits() {
        let g = IconGeometry(side: IconGeometry.largest, width: 200, scale: 2)
        #expect(g.tile.width <= 200 && g.side == g.tile.width)
        let named = IconGeometry(side: 200, width: 150, scale: 2)
        #expect(named.tile.width + named.left + named.right <= 150)
    }

    /// The slider's top end moved one step past 256 (the old largest), so a
    /// row that held four pictures edge to edge holds three now.
    @Test func theTopSizeShowsThreeEdgeToEdge() {
        #expect(IconGeometry.largest == 320)
        let atOldTop = IconGeometry(side: 256, width: 1243, scale: 2)
        #expect(columns(atOldTop, width: 1243) == 4)
        let sheet = IconGeometry(side: IconGeometry.largest, width: 1243, scale: 2)
        #expect(!sheet.names && sheet.gap == 0 && sheet.margin == 0 && sheet.top == 0)
        #expect(columns(sheet, width: 1243) == 3)
        #expect(sheet.side == sheet.tile.width)
    }

    /// Pictures a little below the screen are made before they are scrolled
    /// to, so their tiles don't come in empty.
    @Test func picturesBelowTheScreenAreMadeAhead() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaAhead-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        for i in 0..<120 {
            let url = folder.appendingPathComponent(String(format: "p%03d.png", i))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let prefs = UserDefaults.standard
        let oldSize = prefs.object(forKey: "iconSize"), oldMode = prefs.object(forKey: "viewMode")
        defer {
            prefs.set(oldSize, forKey: "iconSize")
            prefs.set(oldMode, forKey: "viewMode")
        }
        prefs.set("details", forKey: "viewMode")
        let tab = ExplorerTab(location: .folder(folder))
        defer { tab.watcher.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.view
        defer { window.close() }
        try await eventually("folder read") { tab.items.count == 120 }
        tab.setViewMode(.icons)
        tab.setIconSize(64)
        tab.view.layoutSubtreeIfNeeded()
        tab.grid.layoutSubtreeIfNeeded()

        let layout = try #require(tab.grid.collectionViewLayout as? IconLayout)
        let seen = tab.grid.visibleRect
        let below = try #require((0..<120).first { i in
            guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame else { return false }
            return frame.minY > seen.maxY && frame.maxY < seen.maxY + seen.height
        }, "nothing just below a screen of \(seen)")
        tab.makeThumbnailsAhead()
        let item = tab.items[below]
        let side = layout.geometry.thumbnailSide, scale = window.backingScaleFactor
        try await eventually("made before it is in sight") {
            Thumbnails.shared.ready(for: item.url, side: side, scale: scale, version: item.modified) != nil
        }
    }

    @Test func theLargestSizeLaysPicturesEdgeToEdge() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaSheet-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for i in 0..<20 { try "\(i)".write(to: folder.appendingPathComponent("file \(i).txt"), atomically: true, encoding: .utf8) }
        let prefs = UserDefaults.standard
        let oldSize = prefs.object(forKey: "iconSize"), oldMode = prefs.object(forKey: "viewMode")
        defer {
            prefs.set(oldSize, forKey: "iconSize")
            prefs.set(oldMode, forKey: "viewMode")
        }

        // Starts in Details, as a first run does: the pictures' view was laid out while hidden.
        prefs.set("details", forKey: "viewMode")
        let tab = ExplorerTab(location: .folder(folder))
        defer { tab.watcher.stop() }
        try await eventually("folder read") { tab.items.count == 20 }
        tab.setViewMode(.icons)
        tab.setIconSize(IconGeometry.largest)
        tab.view.layoutSubtreeIfNeeded()
        tab.grid.layoutSubtreeIfNeeded()
        let layout = try #require(tab.grid.collectionViewLayout)
        let frames = (0..<20).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        #expect(frames.count == 20)
        let geometry0 = try #require((layout as? IconLayout)?.geometry)
        #expect(geometry0.left + geometry0.right + frames.filter { $0.minY == frames[0].minY }.map(\.width).reduce(0, +)
                    == tab.grid.bounds.width, "grid \(tab.grid.bounds.width), tile \(geometry0.tile)")
        let firstRow = frames.filter { $0.minY == frames[0].minY }
        #expect(firstRow.count > 1)
        for (a, b) in zip(firstRow, firstRow.dropFirst()) { #expect(b.minX == a.maxX) }
        let secondRow = try #require(frames.first { $0.minY > frames[0].minY })
        #expect(secondRow.minY == frames[0].maxY)
        #expect(secondRow.minX == frames[0].minX)

        tab.setIconSize(128)
        tab.grid.layoutSubtreeIfNeeded()
        let named = (0..<20).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        let row = named.filter { $0.minY == named[0].minY }
        let geometry = try #require((layout as? IconLayout)?.geometry)
        #expect(geometry.names && geometry.gap > 0)
        for (a, b) in zip(row, row.dropFirst()) { #expect(b.minX - a.maxX == geometry.gap) }
    }

    /// Some sites hand out WebP under a .avif name; Quick Look reads by the
    /// name and gives up, ImageIO reads what is inside.
    @Test func aPictureUnderTheWrongExtensionStillGetsAThumbnail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaMisnamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.avif")
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(Thumbnails.decode(source, pixels: 128).map { max($0.width, $0.height) } == 128)
        var delivered: NSImage?
        Thumbnails.shared.image(for: file, side: 64, scale: 2, version: Date()) { delivered = $0 }
        try await eventually("thumbnail made") { delivered != nil }
        #expect((delivered?.size.width ?? 0) > (delivered?.size.height ?? 0))
    }
}
