import AppKit
import ImageIO
import Testing
@testable import Foldera

private final class PreviewAuditFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaPreviewAudit-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    deinit { FileOps.removeOwn(root) }
}

private func previewAuditPicture(_ url: URL, width: Int, height: Int, type: String = "public.png", frames: Int = 1) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(output, image, nil) }
    #expect(CGImageDestinationFinalize(output))
}

@Suite struct DeepPreviewAudit {
    @Test func multipageTIFFUsesABoundedFirstPageDecode() throws {
        let files = try PreviewAuditFiles(), url = files.url("scan.tiff")
        try previewAuditPicture(url, width: 1600, height: 800, type: "public.tiff", frames: 2)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        let image = try #require(ImageFiles.decodeBitmap(url, maxPixels: 160))
        #expect(image.pixels == NSSize(width: 160, height: 80))
        #expect(image.full == NSSize(width: 1600, height: 800))
        #expect(!image.isFull)
    }

    @Test func aCachedImageIsReusedOnlyWhileItsFileRevisionMatches() throws {
        let files = try PreviewAuditFiles(), url = files.url("photo.png")
        try previewAuditPicture(url, width: 100, height: 50)
        let cached = try #require(ImageFiles.readValidated(url, maxPixels: 200))
        let same = try #require(ImageFiles.readValidated(url, maxPixels: 200, cached: cached))
        #expect(same.loaded.image === cached.loaded.image)
        let modified = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try previewAuditPicture(url, width: 80, height: 120)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let updated = try #require(ImageFiles.readValidated(url, maxPixels: 200, cached: cached))
        #expect(updated.revision != cached.revision)
        #expect(updated.loaded.pixels == NSSize(width: 80, height: 120))
        #expect(updated.loaded.image !== cached.loaded.image)
    }

    @Test func aCachedSymlinkImageTracksChangesToItsTarget() throws {
        let files = try PreviewAuditFiles(), target = files.url("target.png"), link = files.url("link.png")
        try previewAuditPicture(target, width: 100, height: 50)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let cached = try #require(ImageFiles.readValidated(link, maxPixels: 200))
        let linkRevision = FileOps.revision(of: link)
        try previewAuditPicture(target, width: 40, height: 90)
        #expect(FileOps.revision(of: link) == linkRevision)
        let updated = try #require(ImageFiles.readValidated(link, maxPixels: 200, cached: cached))
        #expect(updated.loaded.pixels == NSSize(width: 40, height: 90))
        try FileManager.default.removeItem(at: target)
        #expect(ImageFiles.readValidated(link, maxPixels: 200, cached: cached) == nil)
    }

    @Test func aFileChangedDuringDecodeCannotBeCachedUnderItsNewRevision() throws {
        let files = try PreviewAuditFiles(), url = files.url("photo.png")
        try previewAuditPicture(url, width: 100, height: 50)
        var reads = 0
        let loaded = try #require(ImageFiles.readValidated(url, maxPixels: 200) { url, pixels in
            let image = ImageFiles.decodeBitmap(url, maxPixels: pixels)
            reads += 1
            if reads == 1 {
                do { try previewAuditPicture(url, width: 40, height: 90) }
                catch { Issue.record(error) }
            }
            return image
        })
        #expect(reads == 2)
        #expect(loaded.loaded.pixels == NSSize(width: 40, height: 90))
    }

    @Test func aContinuouslyChangingImageStopsAfterTwoDecodes() throws {
        let files = try PreviewAuditFiles(), url = files.url("photo.png")
        try previewAuditPicture(url, width: 100, height: 50)
        var reads = 0
        let loaded = ImageFiles.readValidated(url, maxPixels: 200) { url, pixels in
            let image = ImageFiles.decodeBitmap(url, maxPixels: pixels)
            reads += 1
            do { try previewAuditPicture(url, width: 40 + reads, height: 90) }
            catch { Issue.record(error) }
            return image
        }
        #expect(reads == 2)
        #expect(loaded == nil)
    }

    @Test func sharpeningKeepsTheDisplayedRevisionAndRejectsChangedGeometry() throws {
        let files = try PreviewAuditFiles(), url = files.url("photo.png")
        try previewAuditPicture(url, width: 100, height: 50)
        let screen = try #require(ImageFiles.readValidated(url, maxPixels: 20))
        #expect(screen.loaded.pixels == NSSize(width: 20, height: 10))
        let full = try #require(ImageFiles.readRefinement(url, matching: screen.revision))
        #expect(full.loaded.pixels == NSSize(width: 100, height: 50))
        #expect(full.loaded.isFull)

        var reads = 0
        let changed = ImageFiles.readRefinement(url, matching: screen.revision) { url in
            let loaded = ImageFiles.decodeBitmap(url)
            reads += 1
            if reads == 1 {
                do { try previewAuditPicture(url, width: 40, height: 90) }
                catch { Issue.record(error) }
            }
            return loaded
        }
        #expect(reads == 2)
        #expect(changed == nil, "The new portrait must be loaded with new geometry, not inserted into the old wide canvas")
        let refreshed = try #require(ImageFiles.readValidated(url, maxPixels: 20, cached: screen))
        #expect(refreshed.loaded.full == NSSize(width: 40, height: 90))
        let cancelled = CancelFlag(); cancelled.set()
        let cancelledRead = ImageFiles.readRefinement(url, matching: refreshed.revision, cancelled: cancelled) { _ in
            Issue.record("A cancelled refinement must not decode")
            return nil
        }
        #expect(cancelledRead == nil)
    }

    @MainActor @Test(arguments: [false, true])
    func aLateOCRResultRespectsANewerClipboard(changeClipboard: Bool) async throws {
        _ = NSApplication.shared
        Awake.hold()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("before recognition", forType: .string)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let entered = CancelFlag(), finished = CancelFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        ImageTextCopy.start(URL(fileURLWithPath: "/test.png"), in: window, pasteboard: board) { _, _, _ in
            entered.set()
            guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
            finished.set()
            return "recognized text"
        }
        let deadline = Date().addingTimeInterval(10)
        while !entered.isSet, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSet)
        if changeClipboard {
            board.clearContents()
            board.setString("newer copy", forType: .string)
        }
        release.signal()
        while (!finished.isSet || window.attachedSheet != nil), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // AppKit invokes its sheet completion after removing the sheet.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.attachedSheet == nil)
        #expect(board.string(forType: .string) == (changeClipboard ? "newer copy" : "recognized text"))
    }
}
