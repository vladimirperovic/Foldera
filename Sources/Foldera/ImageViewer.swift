import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Which files the viewer takes, and how they are decoded. Everything comes
/// from macOS itself: ImageIO reads JPEG, PNG, WebP, HEIC, AVIF, JPEG XL,
/// GIF, TIFF, BMP, ICO, TGA, PSD and camera RAW; NSImage adds SVG.
enum ImageFiles {
    struct Loaded {
        let image: NSImage
        /// Pixel size of what was decoded; nil for vector images (SVG), whose natural size is in points.
        let pixels: NSSize?
        /// Pixel size of the picture itself, upright. Larger than `pixels` when decoded at screen size.
        var full: NSSize?

        init(image: NSImage, pixels: NSSize?, full: NSSize? = nil) {
            self.image = image
            self.pixels = pixels
            self.full = full ?? pixels
        }

        var isFull: Bool {
            guard let pixels, let full else { return true }
            return pixels.width >= full.width - 1
        }
    }

    /// The most pixels any screen here can show across: enough for fitting a picture to any window.
    static var screenPixels: Int {
        Int(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3840)
    }

    static func isImage(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    /// The images in a folder, in the order Foldera lists names.
    static func images(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter(isImage)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Decodes with the camera's orientation applied, so a portrait photo
    /// stands up; no larger than `maxPixels` across when given (a 24 MP
    /// photo is 96 MB decoded, the screen-sized one a fraction of that).
    /// Safe to call off the main thread.
    static func decodeBitmap(_ url: URL, maxPixels: Int? = nil) -> Loaded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Animations (GIF, animated WebP) stay NSImages, which NSImageView
        // plays. A JPEG with more than one picture holds a camera's preview
        // (MPF) or a stereo pair: the photo is the first, decoded as any other.
        if CGImageSourceGetCount(source) > 1, !isJPEG(source), let image = NSImage(contentsOf: url),
           let rep = image.representations.first as? NSBitmapImageRep {
            return Loaded(image: image, pixels: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        let upright = uprightSize(of: source)
        let largest = Int(max(upright?.width ?? 1, upright?.height ?? 1))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels ?? largest, largest),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = NSSize(width: cg.width, height: cg.height)
        return Loaded(image: NSImage(cgImage: cg, size: size), pixels: size, full: upright ?? size)
    }

    private static func isJPEG(_ source: CGImageSource) -> Bool {
        guard let found = CGImageSourceGetType(source) else { return false }
        let id = found as String
        return UTType(id)?.conforms(to: .jpeg) == true || id == "public.mpo-image"
    }

    /// The picture's pixel size standing up, as the camera's orientation turns it.
    static func uprightSize(of source: CGImageSource) -> NSSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = p[kCGImagePropertyPixelWidth] as? Int, let height = p[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5–8 stand the picture on its side.
        let sideways = (p[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return sideways ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
    }

    /// The small picture a camera or phone keeps inside the file (EXIF, or a
    /// RAW file's preview), standing up and at most `maxPixels` across. It is
    /// read from the first part of the file without decoding the photo, so it
    /// costs next to nothing even on a slow disk. Nil when there is none, or
    /// when its shape says it isn't of this photo. Safe off the main thread.
    static func storedThumbnail(_ url: URL, in source: CGImageSource, maxPixels: Int) -> CGImage? {
        guard keepsThumbnail(url, source) else { return nil }
        guard let stored = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary) else { return nil }
        guard let upright = uprightSize(of: source) else { return stored }
        return trimmed(stored, toShapeOf: upright)
    }

    /// The same, as a picture to show, and nil when the file is not one ImageIO reads.
    static func storedThumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let stored = storedThumbnail(url, in: source, maxPixels: maxPixels) else { return nil }
        return NSImage(cgImage: stored, size: NSSize(width: stored.width, height: stored.height))
    }

    /// Whether the file carries a picture of its own. Asked for one a JPEG
    /// doesn't have, ImageIO decodes the whole photo to make it, so a JPEG's
    /// EXIF is looked at first; HEIC and RAW files always have theirs.
    private static func keepsThumbnail(_ url: URL, _ source: CGImageSource) -> Bool {
        guard let found = CGImageSourceGetType(source) else { return false }
        let id = found as String
        guard let type = UTType(id) else { return false }
        if type.conforms(to: .jpeg) || id == "public.mpo-image" { return jpegKeepsThumbnail(url) }
        return [UTType.heic, .heif, .rawImage].contains { type.conforms(to: $0) }
    }

    /// Whether a JPEG's EXIF holds a thumbnail, read from the start of the file.
    static func jpegKeepsThumbnail(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // EXIF comes before the picture, in a segment of 64 KB at most.
        guard let head = try? handle.read(upToCount: 128 * 1024) else { return false }
        return jpegKeepsThumbnail(head)
    }

    static func jpegKeepsThumbnail(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var at = 2
        while at + 4 <= bytes.count, bytes[at] == 0xFF {
            let marker = bytes[at + 1]
            // Fill bytes, and markers without a length.
            if marker == 0xFF { at += 1; continue }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { at += 2; continue }
            // The picture itself starts: no EXIF before it.
            if marker == 0xDA || marker == 0xD9 { return false }
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 2 else { return false }
            let start = at + 4, end = min(at + 2 + length, bytes.count)
            if marker == 0xE1, end - start > 14, Array(bytes[start..<start + 6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                return exifKeepsThumbnail(Array(bytes[(start + 6)..<end]))
            }
            at += 2 + length
        }
        return false
    }

    /// EXIF is laid out as TIFF: the thumbnail is the second directory
    /// (IFD1), with a pointer to its JPEG data (tag 0x201).
    private static func exifKeepsThumbnail(_ tiff: [UInt8]) -> Bool {
        guard tiff.count >= 8 else { return false }
        let little = tiff[0] == 0x49 && tiff[1] == 0x49
        guard little || (tiff[0] == 0x4D && tiff[1] == 0x4D) else { return false }
        func number(_ at: Int, _ size: Int) -> Int? {
            guard at >= 0, at + size <= tiff.count else { return nil }
            let digits = tiff[at..<at + size].map(Int.init)
            let ordered = little ? Array(digits.reversed()) : digits
            return ordered.reduce(0) { $0 << 8 | $1 }
        }
        guard let first = number(4, 4), let entries = number(first, 2),
              let second = number(first + 2 + entries * 12, 4), second > 0,
              let count = number(second, 2) else { return false }
        return (0..<count).contains { number(second + 2 + $0 * 12, 2) == 0x201 }
    }

    /// A thumbnail of another shape than its photo, as when a camera pads a
    /// 3:2 photo's 4:3 thumbnail with black bars, cut to the photo's shape.
    /// Nil when the shapes are too far apart to be the same picture.
    static func trimmed(_ image: CGImage, toShapeOf size: NSSize) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return nil }
        let wanted = size.width / size.height
        let ratio = width / height / wanted
        if abs(ratio - 1) < 0.02 { return image }
        // 4:3 for 3:2 or 16:9 is padding; a tall thumbnail for a wide photo is another picture.
        guard ratio > 0.7, ratio < 1.43 else { return nil }
        let crop = ratio > 1
            ? CGRect(x: ((width - height * wanted) / 2).rounded(), y: 0, width: (height * wanted).rounded(), height: height)
            : CGRect(x: 0, y: ((height - width / wanted) / 2).rounded(), width: width, height: (width / wanted).rounded())
        return image.cropping(to: crop)
    }

    /// Vector formats and anything ImageIO passed on. Main thread.
    static func decodeOther(_ url: URL) -> Loaded? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        if let rep = image.representations.first as? NSBitmapImageRep {
            return Loaded(image: image, pixels: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        return Loaded(image: image, pixels: nil)
    }

    /// A quarter-turned copy, for R and L. Only the view turns; the file stays as it is.
    static func rotated(_ loaded: Loaded, quarterTurns: Int) -> Loaded {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return loaded }
        let size = loaded.image.size
        let turned = turns % 2 == 1 ? NSSize(width: size.height, height: size.width) : size
        let image = NSImage(size: turned, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: turned.width / 2, yBy: turned.height / 2)
            transform.rotate(byDegrees: CGFloat(-90 * turns))
            transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
            transform.concat()
            loaded.image.draw(in: NSRect(origin: .zero, size: size))
            return true
        }
        let swap = { (size: NSSize) in turns % 2 == 1 ? NSSize(width: size.height, height: size.width) : size }
        return Loaded(image: image, pixels: loaded.pixels.map(swap), full: loaded.full.map(swap))
    }

    /// Name, size, and what the camera wrote down.
    static func details(_ url: URL, pixels: NSSize?) -> [(String, String)] {
        var rows: [(String, String)] = [("Name", url.lastPathComponent), ("Folder", Format.path(url.deletingLastPathComponent()))]
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey])
        if let kind = values?.localizedTypeDescription { rows.append(("Type", kind)) }
        if let pixels { rows.append(("Dimensions", "\(Int(pixels.width)) × \(Int(pixels.height)) px")) }
        if let size = values?.fileSize { rows.append(("File size", Format.bytes(Int64(size)))) }
        if let date = values?.contentModificationDate { rows.append(("Modified", Format.date.string(from: date))) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return rows }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append(("Taken", taken)) }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        if !camera.isEmpty { rows.append(("Camera", camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
        var exposure: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            exposure.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : "\(t) s")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "f/%.1f", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append(String(format: "%.0f mm", focal)) }
        if !exposure.isEmpty { rows.append(("Exposure", exposure.joined(separator: "  "))) }
        if let model = p[kCGImagePropertyColorModel] as? String {
            let depth = (p[kCGImagePropertyDepth] as? Int).map { ", \($0)-bit" } ?? ""
            let profile = (p[kCGImagePropertyProfileName] as? String).map { ", \($0)" } ?? ""
            rows.append(("Colour", model + depth + profile))
        }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" { lat = -lat }
            if gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" { lon = -lon }
            rows.append(("Location", String(format: "%.5f, %.5f", lat, lon)))
        }
        return rows
    }
}

/// Keeps a picture smaller than the window in the middle of it.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }

    /// scroll(to:) takes the point as given; this keeps it centred and inside the picture.
    func scrollConstrained(to point: NSPoint) {
        scroll(to: constrainBoundsRect(NSRect(origin: point, size: bounds.size)).origin)
    }

    // A click on the dark around a picture counts as one on the picture.
    private var viewer: ImageViewer? { (enclosingScrollView as? ViewerScrollView)?.viewer }

    override func mouseDown(with event: NSEvent) {
        guard let viewer else { return super.mouseDown(with: event) }
        if event.clickCount == 2 { viewer.doubleClicked() }
    }

    override func mouseUp(with event: NSEvent) {
        guard let viewer else { return super.mouseUp(with: event) }
        if event.clickCount == 1 { viewer.clicked() }
    }
}

/// While the whole picture fits, the wheel turns pages, as in FastStone;
/// zoomed in, it scrolls. ⌘ or ⌥ with the wheel zooms.
final class ViewerScrollView: NSScrollView {
    weak var viewer: ImageViewer?
    private var accumulated: CGFloat = 0
    private var gestureUsed = false

    override func scrollWheel(with event: NSEvent) {
        guard let viewer else { return super.scrollWheel(with: event) }
        if !event.modifierFlags.intersection([.command, .option]).isEmpty {
            let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.1 : 0.9
            if event.scrollingDeltaY != 0 { viewer.zoom(by: factor, at: event) }
            return
        }
        guard viewer.fitMode else { return super.scrollWheel(with: event) }
        if !event.momentumPhase.isEmpty { return }
        if event.phase == .began || event.phase == .mayBegin {
            accumulated = 0
            gestureUsed = false
        }
        if event.phase.isEmpty {
            // A mouse wheel: every notch counts.
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            if delta != 0 { viewer.step(delta > 0 ? -1 : 1) }
            return
        }
        guard !gestureUsed else { return }
        accumulated += abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if abs(accumulated) > 30 {
            gestureUsed = true
            viewer.step(accumulated > 0 ? -1 : 1)
        }
    }
}

/// The picture. A click shows or hides the thumbnails (or, zoomed in, fits
/// the picture again); dragging pans; a double-click goes full screen.
final class ViewerCanvas: NSImageView {
    weak var viewer: ImageViewer?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragged = false

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewer else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy text from image", action: #selector(ImageViewer.copyTextFromImage(_:)), keyEquivalent: "")
        copy.target = viewer
        copy.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        menu.addItem(copy)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            viewer?.doubleClicked()
            start = nil
            return
        }
        start = event.locationInWindow
        origin = enclosingScrollView?.contentView.bounds.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let origin, let scroll = enclosingScrollView else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        if abs(dx) + abs(dy) > 3 {
            dragged = true
            NSCursor.closedHand.set()
        }
        let m = scroll.magnification
        (scroll.contentView as? CenteringClipView)?.scrollConstrained(to: NSPoint(x: origin.x - dx / m, y: origin.y - dy / m))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if start != nil && !dragged && event.clickCount == 1 {
            viewer?.clicked()
        }
        if dragged { NSCursor.arrow.set() }
        start = nil
    }
}

final class ViewerWindow: NSWindow {
    weak var viewer: ImageViewer?

    override func keyDown(with event: NSEvent) {
        if viewer?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        viewer?.showChrome()
    }
}

/// A FastStone-style image viewer: one picture on a dark background, the
/// rest of the folder one key away, and the tools out of sight until the
/// mouse moves.
final class ImageViewer: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var shared: ImageViewer?

    private var urls: [URL] = []
    private var index = 0
    private var original: ImageFiles.Loaded?
    private var shown: ImageFiles.Loaded?
    private var turns = 0
    private(set) var fitMode = true
    var magnification: CGFloat { scroll.magnification }
    /// Where the picture can go, above the thumbnails when they show.
    var pictureArea: NSSize { scroll.frame.size }
    private var cache: [String: ImageFiles.Loaded] = [:]
    /// The picture on screen and the ones read ahead, side by side.
    private static let decodes = BackgroundTask.queue("Foldera.image-decoding", limit: 3)
    private var inFlight: [String: BackgroundTask] = [:]
    private let sharpen = BackgroundTask(queue: ImageViewer.decodes)
    /// The rough picture shown while the right one decodes.
    private static let previews = BackgroundTask.queue("Foldera.image-previews")
    private let rough = BackgroundTask(queue: ImageViewer.previews)
    /// Which way the pages are turning (1 or −1), to read ahead that way.
    private var heading = 1
    /// True while the full-resolution picture is being decoded for zooming in.
    private var sharpening = false
    private var slideshow: Timer?
    private var hideWork: DispatchWorkItem?

    private let scroll = ViewerScrollView()
    private let canvas = ViewerCanvas()
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(labelWithString: "")
    private let bar = NSVisualEffectView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let infoPanel = NSVisualEffectView()
    private let infoText = NSTextField(wrappingLabelWithString: "")
    private let playButton = ToolButton(symbol: "play.fill", tip: "Slideshow (S)", iconSize: 13)
    private let fullScreenButton = ToolButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen",
                                              tip: "Full screen (F)", iconSize: 13)
    private let thumbnailsButton = ToolButton(symbol: "film", tip: "Thumbnails (T)", iconSize: 13)
    let filmstrip = Filmstrip()
    private var scrollBottom: NSLayoutConstraint?
    private var barBottom: NSLayoutConstraint?
    /// A single click, waiting to see whether it becomes a double one.
    private var pendingClick: DispatchWorkItem?

    /// Opens the viewer on `urls[index]`, reusing the window if it is open.
    static func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        let viewer = shared ?? ImageViewer()
        shared = viewer
        viewer.urls = urls
        viewer.filmstrip.urls = urls
        viewer.cancelLoads()
        viewer.cache = [:]
        viewer.go(to: min(max(index, 0), urls.count - 1))
        viewer.showWindow(nil)
        viewer.window?.makeKeyAndOrderFront(nil)
        if UserDefaults.standard.bool(forKey: "viewerFullScreen"), viewer.window?.styleMask.contains(.fullScreen) == false {
            viewer.window?.toggleFullScreen(nil)
        }
    }

    private init() {
        let frame = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)).insetBy(dx: 60, dy: 40)
        let window = ViewerWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        window.delegate = self
        window.viewer = self
        window.setFrameAutosaveName("ImageViewer")
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        scroll.viewer = self
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.01
        scroll.maxMagnification = 32
        canvas.viewer = self
        canvas.imageScaling = .scaleAxesIndependently
        canvas.imageFrameStyle = .none
        canvas.animates = true
        canvas.isEditable = false
        canvas.wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        message.textColor = .secondaryLabelColor
        message.alignment = .center

        // The tool bar, floating at the bottom.
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        nameLabel.font = .boldSystemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [nameLabel, metaLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        labels.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> ToolButton {
            let b = ToolButton(symbol: symbol, tip: tip, iconSize: 13)
            b.target = self
            b.action = action
            return b
        }
        playButton.target = self
        playButton.action = #selector(toggleSlideshow(_:))
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen(_:))
        thumbnailsButton.target = self
        thumbnailsButton.action = #selector(toggleThumbnails(_:))
        let views: [NSView] = [
            button("chevron.left", "Previous (←)", #selector(previous(_:))),
            button("chevron.right", "Next (→)", #selector(next(_:))),
            labels,
            button("minus.magnifyingglass", "Zoom out (−)", #selector(zoomOut(_:))),
            button("plus.magnifyingglass", "Zoom in (+)", #selector(zoomIn(_:))),
            button("arrow.down.right.and.arrow.up.left", "Fit to window (0)", #selector(fit(_:))),
            button("1.magnifyingglass", "Actual size (1)", #selector(actualSize(_:))),
            button("rotate.left", "Rotate left (L)", #selector(rotateLeft(_:))),
            button("rotate.right", "Rotate right (R)", #selector(rotateRight(_:))),
            button("info.circle", "Information (I)", #selector(toggleInfo(_:))),
            thumbnailsButton,
            playButton,
            fullScreenButton,
            button("arrow.up.forward.app", "Open in the default app (E)", #selector(openExternally(_:))),
            button("trash", "Move to Trash (Delete)", #selector(delete(_:))),
        ]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.setCustomSpacing(12, after: views[1])
        row.setCustomSpacing(12, after: labels)
        pin(row, in: bar)

        // Camera details, on the right when asked for.
        infoPanel.material = .hudWindow
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.wantsLayer = true
        infoPanel.layer?.cornerRadius = 12
        infoPanel.isHidden = true
        infoText.font = .systemFont(ofSize: 12)
        infoText.isSelectable = true
        infoText.preferredMaxLayoutWidth = 260
        infoText.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoText)
        NSLayoutConstraint.activate([
            infoText.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 14),
            infoText.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -14),
            infoText.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 12),
            infoText.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -12),
            infoText.widthAnchor.constraint(equalToConstant: 260),
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let scrollBottom = scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        let barBottom = bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        self.scrollBottom = scrollBottom
        self.barBottom = barBottom
        filmstrip.isHidden = true
        filmstrip.onPick = { [weak self] index in self?.go(to: index) }
        for v in [spinner, message, filmstrip, bar, infoPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scrollBottom,
            filmstrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: Filmstrip.height),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            barBottom,
            bar.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            infoPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            infoPanel.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
        ])
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Moving through the folder

    private var current: URL? { index < urls.count ? urls[index] : nil }

    private func go(to newIndex: Int) {
        index = newIndex
        turns = 0
        sharpening = false
        sharpen.cancel()
        guard let url = current else { return }
        window?.title = url.lastPathComponent
        window?.representedURL = url
        message.stringValue = ""
        if let loaded = cache[url.key] {
            display(loaded)
        } else {
            original = nil
            shown = nil
            canvas.image = nil
            spinner.startAnimation(nil)
            load(url)
            inFlight[url.key]?.hurry()
            showRough(url)
        }
        prefetch()
        updateLabels()
        showChrome()
        filmstrip.current = index
    }

    func step(_ delta: Int) {
        guard !urls.isEmpty else { return }
        let target = index + delta
        guard target >= 0 && target < urls.count else {
            NSSound.beep()
            return
        }
        heading = delta < 0 ? -1 : 1
        go(to: target)
    }

    /// Something to look at at once while the photo decodes, as FastStone
    /// does: the thumbnail the folder's grid made, else the small picture the
    /// file keeps. It is stretched to fit, and gives way to the photo.
    private func showRough(_ url: URL) {
        rough.cancel()
        if let image = Thumbnails.shared.anyPicture(of: url) { return showRough(image) }
        rough.run({ ImageFiles.storedThumbnail(url, maxPixels: 1024) }) { [weak self] image in
            guard let self, let image, self.original == nil, url.key == self.current?.key else { return }
            self.showRough(image)
        }
    }

    private func showRough(_ image: NSImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        spinner.stopAnimation(nil)
        canvas.image = image
        // Window-sized, so fitting it stays within the zoom's limits.
        let across = 1000 / max(size.width, size.height)
        canvas.frame = NSRect(x: 0, y: 0, width: size.width * across, height: size.height * across)
        applyFit()
    }

    private func load(_ url: URL) {
        guard inFlight[url.key] == nil else { return }
        let task = BackgroundTask(queue: Self.decodes)
        inFlight[url.key] = task
        let screen = ImageFiles.screenPixels
        task.run({ ImageFiles.decodeBitmap(url, maxPixels: screen) }) { [weak self] bitmap in
            guard let self else { return }
            self.inFlight[url.key] = nil
            guard let loaded = bitmap ?? ImageFiles.decodeOther(url) else {
                if url.key == self.current?.key { self.failed(url) }
                return
            }
            self.cache[url.key] = loaded
            if url.key == self.current?.key { self.display(loaded) }
        }
    }

    /// The pictures decoded ahead of time, so turning the page is instant:
    /// two the way the pages are turning, and the one behind.
    static func readAhead(from index: Int, heading: Int, count: Int) -> [Int] {
        [index + heading, index + 2 * heading, index - heading].filter { $0 >= 0 && $0 < count }
    }

    /// Decodes the neighbours ahead of time; forgets the ones further away.
    private func prefetch() {
        let ahead = Self.readAhead(from: index, heading: heading, count: urls.count)
        let keep = Set(([index] + ahead).map { urls[$0].key })
        cache = cache.filter { keep.contains($0.key) }
        for key in Array(inFlight.keys) where !keep.contains(key) {
            inFlight.removeValue(forKey: key)?.cancel()
        }
        for i in ahead where cache[urls[i].key] == nil {
            load(urls[i])
        }
    }

    private func cancelLoads() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        sharpen.cancel()
        sharpening = false
        rough.cancel()
    }

    private func failed(_ url: URL) {
        rough.cancel()
        spinner.stopAnimation(nil)
        canvas.image = nil
        message.stringValue = "Foldera can't display “\(url.lastPathComponent)”.\nPress E to open it in its own app."
        updateLabels()
    }

    private func display(_ loaded: ImageFiles.Loaded) {
        rough.cancel()
        spinner.stopAnimation(nil)
        message.stringValue = ""
        original = loaded
        applyTurns()
        if !infoPanel.isHidden { fillInfo() }
    }

    private func applyTurns() {
        guard let original else { return }
        let loaded = ImageFiles.rotated(original, quarterTurns: turns)
        shown = loaded
        canvas.image = loaded.image
        canvas.frame = NSRect(origin: .zero, size: naturalSize(loaded))
        fitMode = true
        applyFit()
        updateLabels()
    }

    /// Zoomed in past what the screen-sized picture holds: decode the whole
    /// one and swap it in, without moving the view. It is not kept once you move on.
    private func sharpenIfNeeded() {
        guard let original, !original.isFull, !sharpening, let url = current, let decoded = shown?.pixels,
              let window else { return }
        let needed = canvas.frame.width * scroll.magnification * window.backingScaleFactor
        guard needed > decoded.width * 1.05 else { return }
        sharpening = true
        sharpen.run({ ImageFiles.decodeBitmap(url) }) { [weak self] full in
            guard let self, self.sharpening, url.key == self.current?.key else { return }
            self.sharpening = false
            guard let full else { return }
            self.original = full
            let turned = ImageFiles.rotated(full, quarterTurns: self.turns)
            self.shown = turned
            self.canvas.image = turned.image
        }
    }

    /// Actual size: one image pixel to one screen pixel; vector images at their stated size.
    private func naturalSize(_ loaded: ImageFiles.Loaded) -> NSSize {
        guard let pixels = loaded.full ?? loaded.pixels else { return loaded.image.size }
        let scale = window?.backingScaleFactor ?? 2
        return NSSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    // MARK: Zoom

    /// The picture as large as the window lets it be, small ones too.
    private func applyFit() {
        let size = canvas.frame.size
        let visible = scroll.contentSize
        guard size.width > 0, size.height > 0, visible.width > 0 else { return }
        let scale = min(visible.width / size.width, visible.height / size.height)
        scroll.magnification = scale
        (scroll.contentView as? CenteringClipView)?.scrollConstrained(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLabels()
    }

    /// While the picture fits, a click shows or hides the thumbnails; zoomed
    /// in, it fits the picture again. It waits a double click's time, since
    /// a double click goes full screen instead.
    func clicked() {
        pendingClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClick = nil
            if self.fitMode { self.toggleThumbnails(nil) } else { self.fit(nil) }
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    func doubleClicked() {
        pendingClick?.cancel()
        pendingClick = nil
        toggleFullScreen(nil)
    }

    /// The folder's pictures along the bottom; the picture makes room for them.
    @objc func toggleThumbnails(_ sender: Any?) {
        let show = filmstrip.isHidden
        filmstrip.isHidden = !show
        thumbnailsButton.isOn = show
        scrollBottom?.constant = show ? -Filmstrip.height : 0
        barBottom?.constant = show ? -Filmstrip.height - 10 : -18
        window?.contentView?.layoutSubtreeIfNeeded()
        if show { filmstrip.current = index }
        if fitMode { applyFit() }
        showChrome()
    }

    func zoom(by factor: CGFloat, at event: NSEvent? = nil) {
        guard shown != nil else { return }
        fitMode = false
        let center: NSPoint
        if let event {
            center = canvas.convert(event.locationInWindow, from: nil)
        } else {
            let visible = scroll.contentView.bounds
            center = NSPoint(x: visible.midX, y: visible.midY)
        }
        scroll.setMagnification(scroll.magnification * factor, centeredAt: center)
        sharpenIfNeeded()
        updateLabels()
    }

    @objc private func magnified() {
        fitMode = false
        sharpenIfNeeded()
        updateLabels()
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }

    @objc func fit(_ sender: Any?) {
        fitMode = true
        applyFit()
    }

    @objc func actualSize(_ sender: Any?) {
        fitMode = false
        let visible = scroll.contentView.bounds
        scroll.setMagnification(1, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        sharpenIfNeeded()
        updateLabels()
    }

    @objc func rotateLeft(_ sender: Any?) {
        turns -= 1
        applyTurns()
    }

    @objc func rotateRight(_ sender: Any?) {
        turns += 1
        applyTurns()
    }

    // MARK: Labels, tools, information

    private func updateLabels() {
        guard let url = current else { return }
        nameLabel.stringValue = url.lastPathComponent
        var parts = ["\(index + 1) / \(urls.count)"]
        if let pixels = shown?.full { parts.append("\(Int(pixels.width)) × \(Int(pixels.height))") }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { parts.append(Format.bytes(Int64(size))) }
        if shown != nil { parts.append("\(Int((scroll.magnification * 100).rounded()))%") }
        metaLabel.stringValue = parts.joined(separator: "   ")
    }

    /// The tools appear when the mouse moves and fade after a moment of stillness.
    func showChrome() {
        hideWork?.cancel()
        if bar.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            let mouse = window.contentView?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero
            if self.bar.frame.insetBy(dx: -20, dy: -20).contains(mouse) {
                self.showChrome()
                return
            }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.bar.animator().alphaValue = 0 }
            if window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    @objc func toggleInfo(_ sender: Any?) {
        infoPanel.isHidden.toggle()
        if !infoPanel.isHidden { fillInfo() }
    }

    private func fillInfo() {
        guard let url = current else { return }
        let rows = ImageFiles.details(url, pixels: original?.full)
        let text = NSMutableAttributedString()
        for (i, row) in rows.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: row.0 + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            text.append(NSAttributedString(string: row.1, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            ]))
        }
        infoText.attributedStringValue = text
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if let slideshow {
            slideshow.invalidate()
            self.slideshow = nil
        } else {
            slideshow = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, !self.urls.isEmpty else { return }
                self.go(to: (self.index + 1) % self.urls.count)
            }
        }
        playButton.isOn = slideshow != nil
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc func previous(_ sender: Any?) { step(-1) }
    @objc func next(_ sender: Any?) { step(1) }

    @objc func openExternally(_ sender: Any?) {
        if let url = current { NSWorkspace.shared.open(url) }
    }

    @objc func copy(_ sender: Any?) {
        if let url = current { FileClipboard.shared.put([url], cut: false) }
    }

    @objc func copyTextFromImage(_ sender: Any?) {
        guard let current, let window else { return }
        ImageTextCopy.start(current, in: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyTextFromImage(_:)) { return current != nil && window?.attachedSheet == nil }
        return true
    }

    /// Delete: to the Trash, and on to the next picture.
    @objc func delete(_ sender: Any?) {
        guard let url = current else { return }
        FileOps.trash([url]) { [weak self] removed in
            guard let self, !removed.isEmpty else { return }
            self.urls.removeAll { $0.key == url.key }
            self.filmstrip.urls = self.urls
            self.cache[url.key] = nil
            if self.urls.isEmpty {
                self.close()
            } else {
                self.go(to: min(self.index, self.urls.count - 1))
            }
        }
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        showChrome()
        if !mods.subtracting(.shift).isEmpty { return false }
        switch event.keyCode {
        case 124, 125, 49, 121: step(1); return true             // → ↓ space page-down
        case 123, 126, 51, 116: step(-1); return true            // ← ↑ backspace page-up
        case 115: go(to: 0); return true                          // home
        case 119: if !urls.isEmpty { go(to: urls.count - 1) }; return true // end
        case 36, 76: toggleFullScreen(nil); return true           // return
        case 117: delete(nil); return true                        // forward delete
        case 53:                                                  // esc
            if slideshow != nil { toggleSlideshow(nil) }
            else if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else { close() }
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullScreen(nil)
        case "r": rotateRight(nil)
        case "l": rotateLeft(nil)
        case "i": toggleInfo(nil)
        case "t": toggleThumbnails(nil)
        case "s": toggleSlideshow(nil)
        case "e": openExternally(nil)
        case "+", "=": zoomIn(nil)
        case "-", "_": zoomOut(nil)
        case "0", "*": fit(nil)
        case "1": actualSize(nil)
        default: return false
        }
        return true
    }

    // MARK: Window

    func windowDidResize(_ notification: Notification) {
        if fitMode { applyFit() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "viewerFullScreen")
        fullScreenButton.label = "Exit full screen"
        fullScreenButton.setSymbol("arrow.down.right.and.arrow.up.left", iconSize: 13)
        fit(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        fullScreenButton.label = "Full screen"
        fullScreenButton.setSymbol("arrow.up.left.and.arrow.down.right", iconSize: 13)
        fit(nil)
    }

    /// ⌘Z brings back a picture deleted here, as it does in the file list.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        FileUndo.manager
    }

    func windowWillClose(_ notification: Notification) {
        cancelLoads()
        slideshow?.invalidate()
        slideshow = nil
        playButton.isOn = false
        hideWork?.cancel()
        pendingClick?.cancel()
        filmstrip.urls = []
        cache = [:]
        canvas.image = nil
        original = nil
        shown = nil
        Self.shared = nil
    }
}

/// The folder's pictures in a row along the bottom of the viewer; a click
/// on one shows it. Thumbnails are made only for the ones in sight.
final class Filmstrip: NSVisualEffectView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 104
    static let side: CGFloat = 84

    var urls: [URL] = [] { didSet { grid.reloadData() } }
    /// The picture shown above, framed and kept in sight.
    var current = 0 {
        didSet {
            guard !isHidden, current < urls.count else { return }
            for tile in grid.visibleItems() { (tile as? FilmstripItem)?.refreshMark(current: current) }
            grid.layoutSubtreeIfNeeded()
            grid.scrollToItems(at: [IndexPath(item: current, section: 0)], scrollPosition: .centeredHorizontally)
        }
    }
    var onPick: ((Int) -> Void)?

    private let scroll = SidewaysScrollView()
    private let grid = KeylessCollectionView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.side, height: Self.side)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        grid.collectionViewLayout = layout
        grid.backgroundColors = [.clear]
        grid.isSelectable = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(FilmstripItem.self, forItemWithIdentifier: Self.item)
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let item = NSUserInterfaceItemIdentifier("FilmstripItem")

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: Self.item, for: indexPath)
        if let tile = tile as? FilmstripItem, indexPath.item < urls.count {
            tile.configure(urls[indexPath.item], index: indexPath.item, current: current)
            tile.onClick = { [weak self] index in self?.onPick?(index) }
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard collectionView.indexPath(for: item) == nil else { return }
        (item as? FilmstripItem)?.stopThumbnail()
    }
}

/// Keys stay with the viewer, which turns the pages.
final class KeylessCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

/// A row that scrolls sideways under a mouse wheel too.
final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            return super.scrollWheel(with: event)
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x - step, 0), max(document.frame.width - contentView.bounds.width, 0))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

/// One thumbnail in the strip; the picture shown above is framed.
final class FilmstripItem: NSCollectionViewItem {
    private let picture = NSImageView()
    private var url: URL?
    private var index = 0
    private var thumbnail: Thumbnails.Ticket?
    var onClick: ((Int) -> Void)?

    override func loadView() {
        let tile = ClickView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 4
        tile.onClick = { [weak self] in
            guard let self else { return }
            self.onClick?(self.index)
        }
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(picture)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 3),
            picture.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -3),
            picture.topAnchor.constraint(equalTo: tile.topAnchor, constant: 3),
            picture.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -3),
        ])
        view = tile
    }

    func configure(_ url: URL, index: Int, current: Int) {
        // Drawn again for the same picture: the thumbnail on its way stays on its way.
        let coming = self.url?.key == url.key && thumbnail != nil
        if !coming { stopThumbnail() }
        self.url = url
        self.index = index
        view.toolTip = url.lastPathComponent
        refreshMark(current: current)
        guard !coming else { return }
        // By its name, not the file: a slow disk is asked only for the thumbnail.
        picture.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .image)
        let scale = view.window?.backingScaleFactor ?? 2
        thumbnail = Thumbnails.shared.image(for: url, side: Filmstrip.side, scale: scale, version: nil, early: { [weak self] image in
            guard let self, self.url?.key == url.key else { return }
            self.picture.image = image
        }) { [weak self] image in
            guard let self, self.url?.key == url.key else { return }
            self.thumbnail = nil
            self.picture.image = image
        }
    }

    func refreshMark(current: Int) {
        let shown = index == current
        view.layer?.borderWidth = shown ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        picture.alphaValue = shown ? 1 : 0.75
    }

    func stopThumbnail() {
        if let thumbnail { Thumbnails.shared.cancel(thumbnail) }
        thumbnail = nil
    }
}

/// Answers a click, for a tile that isn't a button.
final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
