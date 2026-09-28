import AppKit
import ImageIO
import Testing
@testable import Foldera

@Suite struct Pictures {
    /// A 3×2 picture with a red pixel top-left, written as `type`.
    private func write(_ type: String, to url: URL) throws {
        let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaPictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [
        ("jpg", "public.jpeg"), ("png", "public.png"), ("tiff", "public.tiff"), ("gif", "com.compuserve.gif"),
        ("heic", "public.heic"), ("psd", "com.adobe.photoshop-image"), ("bmp", "com.microsoft.bmp"),
        ("tga", "com.truevision.tga-image"),
    ])
    func bitmapsDecodeAtTheirPixelSize(_ ext: String, _ type: String) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("picture.\(ext)")
        try write(type, to: url)
        #expect(ImageFiles.isImage(url))
        let loaded = try #require(ImageFiles.decodeBitmap(url))
        #expect(loaded.pixels == NSSize(width: 3, height: 2))
    }

    @Test func webpDecodes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pixel.webp")
        // The smallest lossless WebP there is (1×1); macOS can read WebP but not write it.
        try Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!.write(to: url)
        #expect(ImageFiles.isImage(url))
        #expect(try #require(ImageFiles.decodeBitmap(url)).pixels == NSSize(width: 1, height: 1))
    }

    @Test func svgDecodesAsAVector() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("logo.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="red"/></svg>"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(ImageFiles.isImage(url))
        #expect(ImageFiles.decodeBitmap(url) == nil)
        let loaded = try #require(ImageFiles.decodeOther(url))
        #expect(loaded.pixels == nil)
        #expect(loaded.image.size == NSSize(width: 120, height: 80))
    }

    @Test func textIsNotAPicture() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        #expect(!ImageFiles.isImage(url))
    }

    @Test func folderPicturesAreInNameOrder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["img10.png", "img2.png", "img1.png"] { try write("public.png", to: dir.appendingPathComponent(name)) }
        try "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        #expect(ImageFiles.images(in: dir).map(\.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
    }

    @Test func quarterTurnsSwapWidthAndHeight() throws {
        let image = NSImage(size: NSSize(width: 30, height: 20))
        let loaded = ImageFiles.Loaded(image: image, pixels: NSSize(width: 30, height: 20))
        let turned = ImageFiles.rotated(loaded, quarterTurns: 1)
        #expect(turned.pixels == NSSize(width: 20, height: 30))
        #expect(turned.image.size == NSSize(width: 20, height: 30))
        #expect(ImageFiles.rotated(loaded, quarterTurns: 2).pixels == NSSize(width: 30, height: 20))
        #expect(ImageFiles.rotated(loaded, quarterTurns: -1).pixels == NSSize(width: 20, height: 30))
    }
}
