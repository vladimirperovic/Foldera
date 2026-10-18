import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
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

private final class FollowupReads {
    private let lock = NSLock()
    private var reads = 0, active = 0, peak = 0
    func start() { lock.lock(); reads += 1; active += 1; peak = max(peak, active); lock.unlock() }
    func finish() { lock.lock(); active -= 1; lock.unlock() }
    var counts: (reads: Int, active: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }; return (reads, active, peak)
    }
}

@Suite(.serialized) struct FollowupImages {
    @Test func jpegInspectionAndDecodeShareOneOpenAndCloudFilesStayUnopened() throws {
        let folder = try FollowupFolder(), url = folder.url.appendingPathComponent("camera.jpg")
        let png = try iconPNG(640)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)),
                                  [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var opens = 0, queries = 0, early = 0
        let image = Thumbnails.photo(url, pixels: 512, isCloudOnly: false,
            downloadStatus: { _ in queries += 1; return false },
            openSource: { url in ThumbnailSource(url, openFile: { opens += 1; return open($0, O_RDONLY) }) },
            early: { _ in early += 1 })
        #expect(image?.width == 512)
        #expect(opens == 1 && queries == 0 && early == 1)
        let cloud = Thumbnails.photo(url, pixels: 512,
            downloadStatus: { _ in queries += 1; return true },
            openSource: { _ in opens += 1; return nil })
        #expect(cloud == nil && queries == 1 && opens == 1)
    }

    @Test func thumbnailSourceClosesItsDescriptorOnSuccessAndInvalidInput() throws {
        let folder = try FollowupFolder(), valid = folder.url.appendingPathComponent("image.png")
        try iconPNG(32).write(to: valid)
        let invalid = try folder.file("broken.jpg")
        for url in [valid, invalid] {
            var descriptor: Int32 = -1
            autoreleasepool {
                let source = ThumbnailSource(url, openFile: { descriptor = open($0, O_RDONLY); return descriptor })
                if url == valid { #expect(source != nil); _ = source.map { Thumbnails.decode($0.image, pixels: 16) } }
                else { #expect(source == nil) }
            }
            #expect(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF)
        }
    }

    @Test func progressSnapshotsOwnTheirMutableDisplayStateAndKeepMetadata() throws {
        let folder = try FollowupFolder(), url = try folder.file("photo.jpg")
        let original = FileItem(url: url)
        original.tags = ["Red"]
        let snapshot = FileItem(snapshot: original, folderSize: 12)
        try FileManager.default.removeItem(at: url)
        original.folderSize = 99
        original.tags = ["Blue"]
        #expect(snapshot !== original && snapshot.key == original.key)
        #expect(snapshot.folderSize == 12 && snapshot.tags == ["Red"])
        #expect(snapshot.isImage && original.isImage)
        #expect(snapshot.size == original.size && snapshot.modified == original.modified)
    }

    @Test @MainActor func failedClipboardPreparationPreservesEveryExistingType() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("app.foldera.regression")
        board.setString("keep this text", forType: .string)
        board.setData(Data([1, 2, 3]), forType: custom)
        let revision = board.changeCount
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        #expect(!ImageFiles.writeClipboard(ImageFiles.clipboardData(missing, quarterTurns: 0), to: board))
        #expect(board.changeCount == revision)
        #expect(board.string(forType: .string) == "keep this text")
        #expect(board.data(forType: custom) == Data([1, 2, 3]))
    }
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLDERA_EXFAT_VOLUME"] != nil))
    func foreignVolumeKeepsNativeHiddenAttributes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FOLDERA_EXFAT_VOLUME"])
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
    @Test func removalMatchesPrivateAliasesButNeverAnUnrelatedPathSuffix() {
        let path = "/var/nonexistent/\(UUID().uuidString).txt"
        let ordinary = FileItem(url: URL(fileURLWithPath: path))
        #expect(ExplorerTab.isAmong(ordinary, ["/private" + path]))
        let unrelated = FileItem(url: URL(fileURLWithPath: "/unrelated" + path))
        #expect(!ExplorerTab.isAmong(unrelated, [path]))
    }
    @Test func aPublishedProgressBatchIsIndependentOfTheReaderUntilItsFinalResult() async throws {
        _ = NSApplication.shared
        let first = try FollowupFolder(), slow = try FollowupFolder()
        try first.file("first.txt")
        let child = slow.url.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let gate = DispatchSemaphore(value: 0), original = ExplorerTab.readFolderInSteps
        let tab = ExplorerTab(location: .folder(first.url))
        defer { tab.watcher.stop(); ExplorerTab.readFolderInSteps = original; gate.signal() }
        try await followupEventually { tab.items.count == 1 }
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            guard url.key == slow.url.key else { return try original(url, hidden, step) }
            let all = try original(url, hidden, { _ in })
            Thread.sleep(forTimeInterval: 0.25)
            step(all)
            _ = gate.wait(timeout: .now() + 10)
            for item in all { item.folderSize = 12345 }
            return all
        }
        tab.navigate(to: .folder(slow.url))
        try await followupEventually { tab.waitingForFolder && tab.items.first?.name == "child" }
        let published = try #require(tab.items.first)
        let sizeBefore = published.folderSize
        gate.signal()
        try await followupEventually { !tab.waitingForFolder }
        #expect(tab.items.first !== published)
        #expect(published.folderSize == sizeBefore)
    }

    @Test func openingAQuietFolderReadsItOnceAndTheArmedWatchCatchesLaterWrites() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder()
        try folder.file("first.txt")
        let meter = FollowupReads(), original = ExplorerTab.readFolderInSteps
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            guard url.key == folder.url.key else { return try original(url, hidden, step) }
            meter.start(); defer { meter.finish() }
            return try original(url, hidden, step)
        }
        defer { ExplorerTab.readFolderInSteps = original }
        let tab = ExplorerTab(location: .folder(folder.url))
        defer { tab.watcher.stop() }
        try await followupEventually { tab.items.count == 1 }
        try await Task.sleep(for: .milliseconds(750))
        #expect(meter.counts.reads == 1)
        try folder.file("second.txt")
        try await followupEventually { tab.items.count == 2 }
        #expect(meter.counts.reads == 2 && meter.counts.peak == 1)
    }

    @Test func successiveDeleteCompletionsShareOneRead() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder()
        for i in 0..<4 { try folder.file("\(i).txt") }
        let tab = ExplorerTab(location: .folder(folder.url))
        defer { tab.watcher.stop() }
        try await followupEventually { tab.items.count == 4 }
        tab.setViewMode(.details)
        tab.watcher.stop()
        let meter = FollowupReads(), original = ExplorerTab.readFolderInSteps
        ExplorerTab.readFolderInSteps = { url, hidden, step in
            guard url.key == folder.url.key else { return try original(url, hidden, step) }
            meter.start(); defer { meter.finish() }
            Thread.sleep(forTimeInterval: 0.2)
            return try original(url, hidden, step)
        }
        defer { ExplorerTab.readFolderInSteps = original }
        for item in Array(tab.items.prefix(3)) {
            try FileManager.default.removeItem(at: item.url)
            tab.removed([item], only: [item.url])
        }
        #expect(tab.items.count == 1)
        #expect(meter.counts.reads == 0)
        try await followupEventually { meter.counts.reads > 0 && meter.counts.active == 0 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(meter.counts.reads == 1 && meter.counts.peak == 1)
        #expect(tab.items.count == 1)
    }

    @Test func anUnrevealableFolderDoesNotReopenACollapsedBranch() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder()
        let outer = folder.url.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        let hidden = outer.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let pins = UserDefaults.standard.object(forKey: "pinned")
        Pins.urls = [folder.url]
        defer { UserDefaults.standard.set(pins, forKey: "pinned"); NotificationCenter.default.post(name: .explorerPinsChanged, object: nil) }
        let sidebar = Sidebar(), outline = sidebar.outline
        defer { sidebar.stop() }
        func node(_ url: URL) -> SidebarNode? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }.first { $0.url?.key == url.key }
        }
        sidebar.sync(to: .folder(hidden))
        try await followupEventually { node(outer).map { outline.isItemExpanded($0) && !$0.loading && !$0.needsReload } == true }
        let ancestor = try #require(node(outer))
        outline.collapseItem(ancestor)
        sidebar.refresh()
        try await Task.sleep(for: .milliseconds(750))
        #expect(!outline.isItemExpanded(ancestor))
    }

    @Test func scrollBurstsUseTheLatestViewportAndCancellationStopsAPendingPass() async throws {
        var position = 0, visited: [Int] = []
        let task = CoalescedTask(delay: 0.05) { visited.append(position) }
        for i in 0..<200 { position = i; task.request() }
        #expect(visited.isEmpty)
        try await followupEventually { !visited.isEmpty }
        #expect(visited == [199])
        position = 300
        task.request()
        try await followupEventually { visited.count == 2 }
        #expect(visited == [199, 300])
        task.request(); task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(visited.count == 2)
    }
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
    @Test func hidingCancelsPendingThumbnailsAndShowingRestartsThem() async throws {
        _ = NSApplication.shared
        var completions: [(NSImage?) -> Void] = []
        let service = Thumbnails(generator: { _, _, done in completions.append(done) })
        let strip = Filmstrip(frame: NSRect(x: 0, y: 0, width: 600, height: Filmstrip.height))
        strip.thumbnails = service
        let window = NSWindow(contentRect: strip.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        window.orderFront(nil)
        defer { strip.isHidden = true; window.close() }
        let url = URL(fileURLWithPath: "/unused/\(UUID().uuidString).png")
        strip.urls = [url]
        strip.layoutSubtreeIfNeeded()
        try await followupEventually { completions.count == 1 }
        strip.isHidden = true
        completions[0](NSImage(size: NSSize(width: 84, height: 84)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.anyPicture(of: url) == nil)
        strip.isHidden = false
        strip.layoutSubtreeIfNeeded()
        try await followupEventually { completions.count == 2 }
    }
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
        try await Task.sleep(for: .milliseconds(750))
        let hiddenImage = Thumbnails.shared.anyPicture(of: url)
        print("FOLLOWUP filmstrip: generated while hidden=\(hiddenImage != nil)")
        #expect(hiddenImage == nil)
        strip.isHidden = false
        strip.current = 0
        strip.layoutSubtreeIfNeeded()
        try await followupEventually { Thumbnails.shared.anyPicture(of: url) != nil }
    }
}

extension Viewer {
    @Test func copyingAnImageThatDisappearedPreservesTheClipboard() async throws {
        _ = NSApplication.shared
        let folder = try FollowupFolder(), url = folder.url.appendingPathComponent("gone.png")
        try iconPNG(64).write(to: url)
        let oldFullScreen = UserDefaults.standard.object(forKey: "viewerFullScreen")
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        defer { UserDefaults.standard.set(oldFullScreen, forKey: "viewerFullScreen") }
        ImageViewer.show([url], at: 0)
        let window = try #require(NSApp.windows.compactMap { $0 as? ViewerWindow }.first { $0.isVisible })
        defer { window.close() }
        let viewer = try #require(window.viewer)
        try FileManager.default.removeItem(at: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        let revision = board.changeCount
        var done = false
        viewer.copyImage(to: board) { done = true }
        try await followupEventually { done }
        #expect(board.changeCount == revision)
        #expect(board.string(forType: .string) == "previous clipboard")
    }
}
