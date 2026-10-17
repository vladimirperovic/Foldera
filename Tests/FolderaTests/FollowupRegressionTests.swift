import AppKit
import ImageIO
import Testing
@testable import Foldera

private final class FollowupFolder {
    let url: URL
    init(root: URL = FileManager.default.temporaryDirectory) throws {
        url = root.appendingPathComponent("FolderaFollowup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    @discardableResult func file(_ name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data("content".utf8).write(to: file)
        return file
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor private func followupEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private func iconPNG(_ side: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func iconFile(_ ext: String, in folder: URL) throws -> URL {
    let small = try iconPNG(16), large = try iconPNG(256)
    func bytes(_ value: Int, count: Int, big: Bool = false) -> Data {
        Data((big ? Array((0..<count).reversed()) : Array(0..<count)).map { UInt8((value >> ($0 * 8)) & 255) })
    }
    let data: Data
    if ext == "ico" {
        var directory = Data([0, 0, 1, 0, 2, 0])
        var offset = 6 + 16 * 2
        for (side, picture) in [(16, small), (256, large)] {
            directory += Data([UInt8(side % 256), UInt8(side % 256), 0, 0, 1, 0, 32, 0])
            directory += bytes(picture.count, count: 4)
            directory += bytes(offset, count: 4)
            offset += picture.count
        }
        data = directory + small + large
    } else {
        let chunks = Data("icp4".utf8) + bytes(small.count + 8, count: 4, big: true) + small
            + Data("ic08".utf8) + bytes(large.count + 8, count: 4, big: true) + large
        data = Data("icns".utf8) + bytes(chunks.count + 8, count: 4, big: true) + chunks
    }
    let url = folder.appendingPathComponent("multiple.\(ext)")
    try data.write(to: url)
    return url
}

@Suite(.serialized) struct FollowupImages {
    @Test(arguments: ["ico", "icns"])
    func multiResolutionIconsUseAnImageLargeEnoughForTheTile(ext: String) throws {
        let folder = try FollowupFolder(), url = try iconFile(ext, in: folder.url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let widths = (0..<CGImageSourceGetCount(source)).map {
            (CGImageSourceCopyPropertiesAtIndex(source, $0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        print("FOLLOWUP icon \(ext): representations \(widths)")
        #expect(widths.contains(16) && widths.contains(256))
        let image = try #require(Thumbnails.decode(source, pixels: 128))
        #expect(image.width == 128 && image.height == 128)
    }

    @Test func foreignVolumeKeepsNativeHiddenAttributes() throws {
        guard let path = ProcessInfo.processInfo.environment["FOLDERA_EXFAT_VOLUME"] else { return }
        let folder = try FollowupFolder(root: URL(fileURLWithPath: path))
        let hidden = try folder.file("hidden-by-attribute.txt")
        try folder.file("visible.txt")
        #expect(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        let values = try hidden.resourceValues(forKeys: [.isHiddenKey])
        print("FOLLOWUP exFAT: native isHidden=\(String(describing: values.isHidden)), foreign=\(UsageScanner.isForeign(folder.url))")
        #expect(values.isHidden == true)
        #expect(UsageScanner.isForeign(folder.url))
        #expect(FileItem(url: hidden, foreign: true).isHidden)
        #expect(try FileItem.contents(of: folder.url, showHidden: false).map(\.name) == ["visible.txt"])
        #expect(try FileItem.contents(of: folder.url, showHidden: true).contains { $0.name == hidden.lastPathComponent })
    }
}

extension BackgroundWork {
    @Test func deletingAnotherFileDoesNotEndAnInlineRename() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder()
        let original = try folder.file("original.txt"), other = try folder.file("other.txt")
        let tab = ExplorerTab(location: .folder(folder.url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.view
        window.makeKeyAndOrderFront(nil)
        defer { tab.cancelRename = true; window.makeFirstResponder(nil); tab.watcher.stop(); window.close() }
        try await followupEventually { tab.items.count == 2 }
        tab.watcher.stop()
        tab.setViewMode(.details)
        tab.view.layoutSubtreeIfNeeded()
        tab.select(keys: [original.key])
        tab.renameSelection(nil)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.string = "half-typed.txt"
        try FileManager.default.removeItem(at: other)
        FileOps.announceRemoved([other])
        try await Task.sleep(for: .milliseconds(100))
        print("FOLLOWUP rename: editing=\(tab.renamingKey != nil), originalExists=\(FileOps.exists(original))")
        #expect(tab.renamingKey == original.key)
        #expect(window.firstResponder === editor)
        #expect(editor.string == "half-typed.txt")
        #expect(FileOps.exists(original))
        #expect(!FileOps.exists(folder.url.appendingPathComponent("half-typed.txt")))
    }
}

@Suite(.serialized) @MainActor struct FollowupFilmstrip {
    @Test func hiddenFilmstripDoesNotGenerateThumbnailsAndShowingItDoes() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder(), url = folder.url.appendingPathComponent("picture.png")
        try iconPNG(256).write(to: url)
        let strip = Filmstrip(frame: NSRect(x: 0, y: 0, width: 600, height: Filmstrip.height))
        strip.isHidden = true
        let window = NSWindow(contentRect: strip.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        window.orderFront(nil)
        defer { strip.urls = []; window.close() }
        strip.urls = [url]
        strip.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        try await Task.sleep(for: .milliseconds(750))
        let hiddenImage = Thumbnails.shared.ready(for: url, side: Filmstrip.side, scale: scale, version: nil)
        print("FOLLOWUP filmstrip: generated while hidden=\(hiddenImage != nil)")
        #expect(hiddenImage == nil)
        strip.isHidden = false
        strip.current = 0
        strip.layoutSubtreeIfNeeded()
        try await followupEventually { Thumbnails.shared.ready(for: url, side: Filmstrip.side, scale: scale, version: nil) != nil }
    }
}
