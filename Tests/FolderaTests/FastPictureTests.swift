import AppKit
import ImageIO
import QuickLookThumbnailing
import Testing
@testable import Foldera

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaFastPictures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A JPEG like a camera's, with a thumbnail kept inside: noise drawn
/// four times larger, soft detail that compresses about as a photo does.
private func photo(_ url: URL, width: Int, height: Int, thumbnail: Bool = true, orientation: Int? = nil) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.noneSkipLast.rawValue
    let grain = try #require(CGContext(data: nil, width: width / 4, height: height / 4, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: info))
    let noise = try #require(grain.data)
    arc4random_buf(noise, grain.bytesPerRow * grain.height)
    let detail = try #require(grain.makeImage())
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: info))
    context.interpolationQuality = .high
    context.draw(detail, in: CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    var properties: [CFString: Any] = [
        kCGImageDestinationEmbedThumbnail: thumbnail,
        kCGImageDestinationLossyCompressionQuality: 0.85,
    ]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func source(_ url: URL) throws -> CGImageSource {
    try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
}

/// Pictures shown quickly, the way FastStone shows them: the small picture a
/// camera keeps in the file first, photos decoded straight to the tile's
/// size, and a size already made standing in for another.
@Suite(.serialized) @MainActor struct FastPictures {
    private func eventually(_ message: String = "condition", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: message))
    }

    @Test func aCamerasPaddedThumbnailIsCutToThePhotosShape() throws {
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let padded = try #require(context.makeImage())
        // 4:3 for a 3:2 photo: the black bars go.
        let cut = try #require(ImageFiles.trimmed(padded, toShapeOf: NSSize(width: 6000, height: 4000)))
        #expect(cut.width == 160 && cut.height == 107)
        // The same shape stays as it is.
        #expect(ImageFiles.trimmed(padded, toShapeOf: NSSize(width: 4000, height: 3000)) === padded)
        // A wide thumbnail for a tall photo is of another picture.
        #expect(ImageFiles.trimmed(padded, toShapeOf: NSSize(width: 3000, height: 4500)) == nil)
    }

    @Test func theThumbnailAJPEGKeepsIsReadAndStandsUp() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appendingPathComponent("kept.jpg")
        try photo(kept, width: 2400, height: 1600)
        #expect(ImageFiles.jpegKeepsThumbnail(kept))
        let keptSource = try source(kept)
        let thumbnail = try #require(ImageFiles.storedThumbnail(kept, in: keptSource, maxPixels: 1024))
        #expect(max(thumbnail.width, thumbnail.height) < 1024)
        #expect(abs(CGFloat(thumbnail.width) / CGFloat(thumbnail.height) - 1.5) < 0.05)
        #expect(ImageFiles.storedThumbnail(kept, maxPixels: 1024) != nil)

        // Taken with the camera on its side: the thumbnail stands up as the photo does.
        let turned = dir.appendingPathComponent("turned.jpg")
        try photo(turned, width: 2400, height: 1600, orientation: 6)
        let turnedSource = try source(turned)
        let upright = try #require(ImageFiles.storedThumbnail(turned, in: turnedSource, maxPixels: 1024))
        #expect(upright.height > upright.width)

        // A file without one has none to give: ImageIO would decode the photo to make one.
        let bare = dir.appendingPathComponent("bare.jpg")
        try photo(bare, width: 2400, height: 1600, thumbnail: false)
        #expect(!ImageFiles.jpegKeepsThumbnail(bare))
        let bareSource = try source(bare)
        #expect(ImageFiles.storedThumbnail(bare, in: bareSource, maxPixels: 1024) == nil)
        // Nor does a file that isn't a JPEG at all, or one cut short.
        #expect(!ImageFiles.jpegKeepsThumbnail(Data("not a picture".utf8)))
        let start = try Data(contentsOf: kept).prefix(40)
        #expect(!ImageFiles.jpegKeepsThumbnail(start))
    }

    @Test func aSmallTileTakesTheKeptThumbnailAndALargeOneDecodesThePhoto() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.jpg")
        try photo(url, width: 2400, height: 1600)

        guard case .enough(let small) = Thumbnails.peek(url, pixels: 64) else {
            Issue.record("a 64-pixel tile should take the thumbnail the file keeps")
            return
        }
        #expect(max(small.width, small.height) >= 57)

        guard case .decode(let rough) = Thumbnails.peek(url, pixels: 800) else {
            Issue.record("an 800-pixel tile needs the photo decoded")
            return
        }
        #expect(rough != nil)
        let decoded = try #require(Thumbnails.decode(url, pixels: 800))
        #expect(max(decoded.width, decoded.height) == 800)
    }

    @Test func aRoughPictureShowsFirstThenTheRightOne() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.jpg")
        try photo(url, width: 2400, height: 1600)
        var events: [String] = []
        var made: NSImage?
        Thumbnails.shared.image(for: url, side: 400, scale: 2, version: Date(), early: { _ in events.append("rough") }) {
            events.append("done")
            made = $0
        }
        try await eventually("made") { made != nil }
        #expect(events == ["rough", "done"])
        #expect(made?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { max($0.width, $0.height) } == 800)
    }

    @Test func aPictureMadeLargerAnswersForASmallerSizeAtOnce() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.jpg")
        try photo(url, width: 2000, height: 1500, thumbnail: false)
        let version = Date()
        var large: NSImage?
        Thumbnails.shared.image(for: url, side: 256, scale: 2, version: version) { large = $0 }
        try await eventually("made") { large != nil }

        var smaller: NSImage?
        let ticket = Thumbnails.shared.image(for: url, side: 96, scale: 2, version: version) { smaller = $0 }
        #expect(ticket == nil)
        #expect(smaller === large)
        // The viewer can show it while it reads the photo.
        #expect(Thumbnails.shared.anyPicture(of: url) === large)
        // Not for another version of the file: it was changed since.
        var other: NSImage?
        Thumbnails.shared.image(for: url, side: 96, scale: 2, version: version.addingTimeInterval(60)) { other = $0 }
        #expect(other == nil)
        try await eventually("made again") { other != nil }
    }

    @Test func theViewerReadsAheadTheWayThePagesTurn() {
        #expect(ImageViewer.readAhead(from: 5, heading: 1, count: 10) == [6, 7, 4])
        #expect(ImageViewer.readAhead(from: 5, heading: -1, count: 10) == [4, 3, 6])
        #expect(ImageViewer.readAhead(from: 9, heading: 1, count: 10) == [8])
        #expect(ImageViewer.readAhead(from: 0, heading: -1, count: 1) == [])
    }
}

/// The numbers behind it, printed for the record. Off the main thread, so
/// the other suites' work goes on while this one waits.
@Suite struct PictureTiming {
    private func milliseconds(_ work: () -> Void) -> Double {
        let start = Date()
        work()
        return Date().timeIntervalSince(start) * 1000
    }

    /// The kept thumbnail against decoding, and ImageIO against Quick Look, on 12 MP photos.
    @Test func readingTheKeptThumbnailIsFarQuickerThanDecoding() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (1...3).map { dir.appendingPathComponent("photo \($0).jpg") }
        for url in urls { try photo(url, width: 4000, height: 3000) }

        let kept = urls.map { url in milliseconds { _ = ImageFiles.storedThumbnail(url, maxPixels: 256) } }
        let decoded = urls.map { url in milliseconds { _ = try? Thumbnails.decode(source(url), pixels: 256) } }
        let whole = milliseconds { _ = ImageFiles.decodeBitmap(urls[0]) }
        // Far apart, so a busy machine doesn't make this flaky.
        #expect(kept.reduce(0, +) * 3 < decoded.reduce(0, +), "kept \(kept) ms, decoded \(decoded) ms")

        // Why a JPEG's EXIF is looked at first: asked for a thumbnail one doesn't keep, ImageIO makes it from the photo.
        let bare = dir.appendingPathComponent("bare.jpg")
        try photo(bare, width: 4000, height: 3000, thumbnail: false)
        let bareSource = try source(bare)
        var unaskedFor: CGImage?
        let unasked = milliseconds {
            unaskedFor = CGImageSourceCreateThumbnailAtIndex(bareSource, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        let looked = milliseconds { _ = ImageFiles.jpegKeepsThumbnail(bare) }

        // Quick Look, each photo once (it remembers what it made), for comparison only.
        var quickLook: [Double] = []
        for url in urls {
            let done = DispatchSemaphore(value: 0)
            let made = CancelFlag()
            let start = Date()
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                if representation != nil { made.set() }
                done.signal()
            }
            guard done.wait(timeout: .now() + 15) == .success, made.isSet else { break }
            quickLook.append(Date().timeIntervalSince(start) * 1000)
        }
        func listed(_ values: [Double]) -> String { values.map { String(format: "%.1f", $0) }.joined(separator: ", ") }
        print("""
            Thumbnails of 12 MP JPEGs, ms each. Kept in the file: \(listed(kept)). \
            Decoded to 256 px: \(listed(decoded)). Quick Look at 128 pt: \(quickLook.isEmpty ? "unavailable" : listed(quickLook)). \
            Whole photo decoded: \(listed([whole])). Without a kept thumbnail, ImageIO gave \
            \(unaskedFor.map { "\($0.width)×\($0.height)" } ?? "none") in \(listed([unasked])); looking at the EXIF took \(listed([looked])).
            """)
    }
}
