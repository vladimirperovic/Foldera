import AppKit
import Darwin
import ImageIO
import Testing
@testable import Foldera

private final class NovemberFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaNovember-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    @discardableResult func file(_ name: String, _ text: String = "original") throws -> URL {
        let path = url(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
        return path
    }
    deinit { FileOps.removeOwn(root) }
}

private func novemberPicture(_ url: URL, width: Int, height: Int, type: String = "public.png", frames: Int = 1) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    try #require(CGImageDestinationFinalize(destination))
}

@Suite struct NovemberAudit {
    @Test(arguments: ["https://example.com/pixel.png", "http://example.com/pixel.png",
                      "//example.com/pixel.png", "data:image/png;base64,AAAA", "file:///tmp/pixel.png"])
    func markdownNeverEmbedsExternalImages(_ address: String) {
        let html = Markdown.html("![remote](\(address))")
        #expect(!html.contains("<img"))
        #expect(html.contains("Image not loaded"))
        let page = Markdown.page(rendered: html, base: URL(string: "foldera-md://files/")!)
        #expect(page.contains("default-src 'none'; img-src foldera-md:"))
        #expect(!page.contains("img-src https:"))
    }

    @Test(arguments: ["/Users/Shared", "/etc", "/Volumes/External/docs"])
    func markdownOutsideHomeDoesNotGrantParentFolders(_ path: String) throws {
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let pictures = LocalPictures()
        pictures.serve(folder, home: URL(fileURLWithPath: "/Users/test-reader"))
        #expect(pictures.base.path == "/")
        let reference = try #require(URL(string: "../private.png", relativeTo: pictures.base)?.absoluteURL)
        let file = try #require(pictures.file(for: reference))
        #expect(file.deletingLastPathComponent() == folder)
        #expect(pictures.file(for: URL(string: "foldera-md://elsewhere/private.png")!) == nil)
    }

    @Test func markdownRejectsSymlinksLeavingAnExternalDocumentFolder() throws {
        let files = try NovemberFiles()
        let image = try files.file("private.png")
        let doc = try files.file("docs/readme.md")
        try FileManager.default.createSymbolicLink(at: files.url("docs/link.png"), withDestinationURL: image)
        let pictures = LocalPictures()
        pictures.serve(doc.deletingLastPathComponent())
        #expect(pictures.file(for: URL(string: "link.png", relativeTo: pictures.base)!.absoluteURL) == nil)
    }

    @Test func refinementAndAnimationDecodeStayBounded() throws {
        let files = try NovemberFiles(), wide = files.url("wide.png"), animated = files.url("many.gif")
        try novemberPicture(wide, width: 10000, height: 2)
        let screen = try #require(ImageFiles.readValidated(wide, maxPixels: 100))
        let refined = try #require(ImageFiles.readRefinement(wide, matching: screen.revision))
        #expect(refined.loaded.pixels?.width == CGFloat(ImageDecodeLimits.dimension))
        #expect(refined.loaded.limited)
        #expect(refined.loaded.full?.width == 10000)
        try novemberPicture(animated, width: 1, height: 1, type: "com.compuserve.gif", frames: 501)
        let loaded = try #require(ImageFiles.decodeBitmap(animated, maxPixels: 100))
        #expect(loaded.note?.contains("first frame") == true)
        #expect(((loaded.image.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 1) == 1)
        #expect(ImageDecodeLimits.thumbnailDimension(width: 30000, height: 30000, requested: Int.max) <= 5656)
        #expect(ImageDecodeLimits.thumbnailDimension(width: Double.infinity, height: 1, requested: Int.max) == 1)
    }

    @Test func smallImageFilesAreCheckedByPixelsAndTotalFrames() throws {
        let files = try NovemberFiles(), file = files.url("small.jpg"), animated = files.url("two.gif")
        try novemberPicture(file, width: 80, height: 40, type: "public.jpeg")
        let original = try #require(LocalPictures.pictureData(file, kind: .jpeg, cancelled: { false }))
        #expect(original.type == "image/jpeg")
        let bounded = try #require(LocalPictures.pictureData(file, kind: .jpeg, pixelLimit: 100, cancelled: { false }))
        #expect(bounded.type == "image/png")
        try novemberPicture(animated, width: 10, height: 10, type: "com.compuserve.gif", frames: 2)
        let source = try #require(CGImageSourceCreateWithURL(animated as CFURL, nil))
        #expect(!ImageDecodeLimits.fits(source, totalLimit: 150))
        #expect(ImageDecodeLimits.fits(source, totalLimit: 200))
    }

    @Test func textSavingPreservesSymlinksAndExtendedAttributes() throws {
        let files = try NovemberFiles(), target = try files.file("target.md"), link = files.url("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let attribute = "com.foldera.november-test"
        let value = Data("keep me".utf8)
        try #require(value.withUnsafeBytes { setxattr(target.path, attribute, $0.baseAddress, $0.count, 0, 0) } == 0)
        let linkBefore = FileOps.revision(of: link)
        try TextFile.write("edited", to: link)
        #expect(FileOps.revision(of: link) == linkBefore)
        #expect(TextFile.read(target) == "edited")
        var saved = Data(count: value.count)
        let count = saved.withUnsafeMutableBytes { getxattr(target.path, attribute, $0.baseAddress, $0.count, 0, 0) }
        #expect(count == value.count && saved == value)
    }

    @Test func hardLinksAreRefusedWithoutChangingEitherName() throws {
        let files = try NovemberFiles(), target = try files.file("target.md"), link = files.url("hard.md")
        try FileManager.default.linkItem(at: target, to: link)
        #expect(throws: OpError.self) { try TextFile.write("edited", to: target) }
        #expect(TextFile.read(target) == "original" && TextFile.read(link) == "original")
        #expect(FileOps.revision(of: target)?.inode == FileOps.revision(of: link)?.inode)
    }

    @Test func writersAfterApprovalOrDuringStagingAreNotOverwritten() throws {
        let files = try NovemberFiles(), target = try files.file("draft.md")
        let approved = try TextFile.snapshot(target)
        try files.file("draft.md", "external")
        #expect(throws: OpError.self) { try TextFile.write("edited", to: target, expected: approved) }
        #expect(TextFile.read(target) == "external")
        #expect(throws: OpError.self) {
            try TextFile.write("edited", to: target, beforeCommit: { try files.file("draft.md", "later") })
        }
        #expect(TextFile.read(target) == "later")
        #expect((try FileManager.default.contentsOfDirectory(atPath: files.root.path)) == ["draft.md"])
    }

    @Test func retargetingASymlinkAfterApprovalKeepsBothTargets() throws {
        let files = try NovemberFiles(), first = try files.file("first.md"), second = try files.file("second.md", "second")
        let link = files.url("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let approved = try TextFile.snapshot(link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(throws: OpError.self) { try TextFile.write("edited", to: link, expected: approved) }
        #expect(TextFile.read(first) == "original" && TextFile.read(second) == "second")
    }

    @Test func checksumListsRejectLargeInputAndLongRecordsAndHonorCancellation() throws {
        let files = try NovemberFiles(), list = try files.file("checks.sha256", String(repeating: "a", count: 64) + "  name\r\n")
        #expect(try Checksum.readEntries(list, cancelled: CancelFlag()).first?.name == "name")
        #expect(throws: OpError.self) { try Checksum.readEntries(list, cancelled: CancelFlag(), byteLimit: 10) }
        try files.file("checks.sha256", String(repeating: "x", count: Checksum.maximumLineBytes + 1))
        #expect(throws: OpError.self) { try Checksum.readEntries(list, cancelled: CancelFlag()) }
        let cancelled = CancelFlag(); cancelled.set()
        #expect(throws: CancellationError.self) { try Checksum.readEntries(list, cancelled: cancelled) }
        #expect(throws: CancellationError.self) { try TextFile.data(list, cancelled: cancelled) }
    }

    @Test(arguments: [false, true])
    func abandonedArchiveCachesAreRetriedEvenWithoutACurrentCache(_ currentExists: Bool) throws {
        let files = try NovemberFiles(), oldName = "Archives-old-\(UUID().uuidString)"
        let oldFile = try files.file(oldName + "/private.txt")
        let unrelated = try files.file("Archives-old-keep/private.txt")
        if currentExists { try files.file("Archives/current.txt") }
        var disposed: [URL] = []
        try ArchiveFolders.prepareForLaunch(at: files.url("Archives")) { disposed.append($0) }
        #expect(disposed.contains(oldFile.deletingLastPathComponent()))
        #expect(disposed.count == (currentExists ? 2 : 1))
        let fresh = try files.file("Archives/new.txt")
        disposed.forEach { FileOps.removeOwn($0) }
        #expect(FileOps.exists(fresh) && FileOps.exists(unrelated))
    }
}

@Suite(.serialized) @MainActor struct NovemberEditorLoading {
    @Test func editorOpensBeforeItsBackgroundReadAndClosedLoadsCannotReturn() async throws {
        _ = NSApplication.shared
        let files = try NovemberFiles(), file = try files.file("draft.md", "# Loaded")
        let editor = try #require(MarkdownEditor.show(file))
        defer { editor.close() }
        #expect(editor.loading)
        for _ in 0..<100 where editor.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!editor.loading)
        #expect(editor.draftText == "# Loaded")
        let second = try #require(MarkdownEditor.show(try files.file("other.md")))
        second.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(second.draftText.isEmpty)
    }
}
