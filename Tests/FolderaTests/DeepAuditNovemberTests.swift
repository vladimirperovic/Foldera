import AppKit
import ImageIO
import Testing
@testable import Foldera

private final class NovemberSixthFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaDeepAudit-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    deinit { FileOps.removeOwn(root) }
}

private func novemberSixthPicture(_ url: URL, width: Int, height: Int) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
}

private func pixels(_ tiff: Data?) throws -> (width: Int, height: Int) {
    let data = try #require(tiff)
    let rep = try #require(NSBitmapImageRep(data: data))
    return (rep.pixelsWide, rep.pixelsHigh)
}

extension SyncTestIsolation {
@Suite(.serialized) struct DeepAuditSyncHistory {
    @Test func oneUnreadableRunDoesNotHideTheRestOfTheHistory() throws {
        let files = try NovemberSixthFiles()
        let previous = SyncLibrary.folder
        SyncLibrary.folder = files.url("Library")
        defer { SyncLibrary.folder = previous }
        let setup = SyncWindow.Setup(left: files.url("Left").path, right: files.url("Right").path, mode: .update)
        let older = SyncLibrary.Record(setup: setup, started: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = SyncLibrary.Record(setup: setup, started: Date(timeIntervalSince1970: 1_700_000_100))
        try SyncLibrary.append(older)
        try SyncLibrary.append(newer)
        // A damaged run between the two, as a full disk or another version may leave one.
        let history = SyncLibrary.folder.appendingPathComponent("History")
        try Data("{ not json".utf8).write(to: history.appendingPathComponent("1700000050.000-\(UUID().uuidString).json"))
        #expect(try SyncLibrary.summaries().map(\.id) == [newer.id, older.id])
    }
}
}

@Suite struct DeepAuditNovember {
    @Test func copyImageKeepsAPictureWithinItsBudgetAndAFittingOneWhole() throws {
        let files = try NovemberSixthFiles(), url = files.url("photo.png")
        try novemberSixthPicture(url, width: 300, height: 200)
        let whole = try pixels(ImageFiles.clipboardPicture(url, quarterTurns: 0))
        #expect(whole.width == 300 && whole.height == 200)
        let bounded = try pixels(ImageFiles.clipboardPicture(url, quarterTurns: 0, pixelLimit: 6_000))
        #expect(bounded.width > bounded.height)
        let area: Int = bounded.width * bounded.height
        let allowed: Int = 6_000 + bounded.width
        #expect(bounded.width <= 94)
        #expect(area <= allowed)
        let turned = try pixels(ImageFiles.clipboardData(url, quarterTurns: 1, pixelLimit: 6_000))
        #expect(turned.height == bounded.width && turned.width == bounded.height)
    }

    @Test func copyImageDrawsAVectorAtItsOwnSizeOrWithinTheBudget() throws {
        let files = try NovemberSixthFiles(), url = files.url("logo.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="red"/></svg>"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(ImageFiles.clipboardPicture(url, quarterTurns: 0) == nil)
        let natural = try pixels(ImageFiles.clipboardData(url, quarterTurns: 0))
        #expect(natural.width == 120 && natural.height == 80)
        let bounded = try pixels(ImageFiles.clipboardData(url, quarterTurns: 0, pixelLimit: 2_400))
        #expect(bounded.width == 60 && bounded.height == 40)
        let turned = try pixels(ImageFiles.clipboardData(url, quarterTurns: 1, pixelLimit: 2_400))
        #expect(turned.width == 40 && turned.height == 60)
    }

    @Test func aRasterImageIOCannotReadIsNotDecodedAgainByNSImage() throws {
        let files = try NovemberSixthFiles(), url = files.url("broken.png")
        try Data("not a picture".utf8).write(to: url)
        #expect(Thumbnails.readsHere(url))
        #expect(ImageFiles.clipboardData(url, quarterTurns: 0) == nil)
    }

    @Test func clipboardBudgetHoldsForAnySizeWithoutTrapping() {
        #expect(ImageDecodeLimits.clipboardSide(width: 10_000, height: 10_000) == nil)
        #expect(ImageDecodeLimits.clipboardSide(width: 20_000, height: 20_000) == 10_000)
        #expect(ImageDecodeLimits.clipboardSide(width: 1_000_000, height: 10) == ImageDecodeLimits.clipboardDimension)
        let huge: Int = ImageDecodeLimits.clipboardSide(width: Int.max, height: Int.max) ?? 0
        #expect(huge >= 1)
        #expect(huge <= ImageDecodeLimits.clipboardDimension)
        #expect(ImageDecodeLimits.clipboardSide(width: 0, height: 5) == nil)
        #expect(ImageDecodeLimits.scale(width: .infinity, height: 1) == 0)
        #expect(ImageDecodeLimits.scale(width: .nan, height: 1) == 0)
        #expect(ImageDecodeLimits.rasterized(NSImage(size: .zero)) == nil)
    }

    @Test func aMediaLengthNoIntegerHoldsShowsNothing() {
        #expect(PreviewPane.runningTime(187) == "3:07")
        #expect(PreviewPane.runningTime(3_765) == "1:02:45")
        #expect(PreviewPane.runningTime(0.6) == "0:01")
        let claims: [Double] = [0, -5, .nan, .infinity, 1.8e19, .greatestFiniteMagnitude]
        for claimed in claims {
            #expect(PreviewPane.runningTime(claimed) == nil)
        }
    }

    @Test func anExposureTimeWithoutAnIntegerReciprocalShowsNothing() {
        #expect(ImageFiles.exposureTime(0.004) == "1/250 s")
        #expect(ImageFiles.exposureTime(2.5) == "2.5 s")
        let claims: [Double] = [0, -1, .nan, .infinity, 1e-12, 1e-310, .leastNonzeroMagnitude]
        for claimed in claims {
            #expect(ImageFiles.exposureTime(claimed) == nil)
        }
    }

    @Test @MainActor func aMissingFolderIsReportedOnceAndAgainOnlyWhenItIsBack() async throws {
        Awake.hold()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaGone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: missing) }
        let watcher = DirectoryWatcher()
        defer { watcher.stop() }
        var ready = 0, changes = 0
        watcher.onChange = { changes += 1 }
        watcher.watch(missing) { ready += 1 }
        // Retries come 0.5 s and 1.5 s in; each used to report a change 0.3 s after it.
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(ready == 1)
        #expect(changes == 0)
        #expect(!watcher.isWatching && !watcher.isIdle)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        let deadline = Date().addingTimeInterval(15)
        while !(watcher.isWatching && changes > 0), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(watcher.isWatching)
        #expect(changes == 1)
    }
}
