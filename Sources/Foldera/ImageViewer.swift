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
        // Animations (GIF, animated WebP) stay NSImages, which NSImageView plays.
        if CGImageSourceGetCount(source) > 1, let image = NSImage(contentsOf: url),
           let rep = image.representations.first as? NSBitmapImageRep {
            return Loaded(image: image, pixels: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let largest = max(width, height, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels ?? largest, largest),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = NSSize(width: cg.width, height: cg.height)
        // Orientations 5–8 stand the picture on its side.
        let sideways = (properties?[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        let full = width > 0 && height > 0
            ? (sideways ? NSSize(width: height, height: width) : NSSize(width: width, height: height)) : size
        return Loaded(image: NSImage(cgImage: cg, size: size), pixels: size, full: full)
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

/// The picture. A click switches between fitting the window and actual
/// size at that spot; dragging pans; a double-click goes full screen.
final class ViewerCanvas: NSImageView {
    weak var viewer: ImageViewer?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            viewer?.toggleFullScreen(nil)
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
            viewer?.toggleZoom(at: convert(event.locationInWindow, from: nil))
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
final class ImageViewer: NSWindowController, NSWindowDelegate {
    private static var shared: ImageViewer?

    private var urls: [URL] = []
    private var index = 0
    private var original: ImageFiles.Loaded?
    private var shown: ImageFiles.Loaded?
    private var turns = 0
    private(set) var fitMode = true
    private var cache: [String: ImageFiles.Loaded] = [:]
    private var inFlight: Set<String> = []
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

    /// Opens the viewer on `urls[index]`, reusing the window if it is open.
    static func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        let viewer = shared ?? ImageViewer()
        shared = viewer
        viewer.urls = urls
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
            playButton,
            button("arrow.up.left.and.arrow.down.right", "Full screen (F)", #selector(toggleFullScreen(_:))),
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

        pin(scroll, in: content)
        for v in [spinner, message, bar, infoPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
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
        }
        prefetch()
        updateLabels()
        showChrome()
    }

    func step(_ delta: Int) {
        guard !urls.isEmpty else { return }
        let target = index + delta
        guard target >= 0 && target < urls.count else {
            NSSound.beep()
            return
        }
        go(to: target)
    }

    private func load(_ url: URL) {
        guard !inFlight.contains(url.key) else { return }
        inFlight.insert(url.key)
        let screen = ImageFiles.screenPixels
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bitmap = ImageFiles.decodeBitmap(url, maxPixels: screen)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(url.key)
                guard let loaded = bitmap ?? ImageFiles.decodeOther(url) else {
                    if url.key == self.current?.key { self.failed(url) }
                    return
                }
                self.cache[url.key] = loaded
                if url.key == self.current?.key { self.display(loaded) }
            }
        }
    }

    /// Decodes the neighbours ahead of time, so the next picture is instant;
    /// forgets the ones further away.
    private func prefetch() {
        let keep = Set([index - 1, index, index + 1].filter { $0 >= 0 && $0 < urls.count }.map { urls[$0].key })
        cache = cache.filter { keep.contains($0.key) }
        for i in [index + 1, index - 1] where i >= 0 && i < urls.count && cache[urls[i].key] == nil {
            load(urls[i])
        }
    }

    private func failed(_ url: URL) {
        spinner.stopAnimation(nil)
        canvas.image = nil
        message.stringValue = "Foldera can't display “\(url.lastPathComponent)”.\nPress E to open it in its own app."
        updateLabels()
    }

    private func display(_ loaded: ImageFiles.Loaded) {
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let full = ImageFiles.decodeBitmap(url)
            DispatchQueue.main.async {
                guard let self, self.sharpening, url.key == self.current?.key, let full else { return }
                self.sharpening = false
                self.original = full
                let turned = ImageFiles.rotated(full, quarterTurns: self.turns)
                self.shown = turned
                self.canvas.image = turned.image
            }
        }
    }

    /// Actual size: one image pixel to one screen pixel; vector images at their stated size.
    private func naturalSize(_ loaded: ImageFiles.Loaded) -> NSSize {
        guard let pixels = loaded.full ?? loaded.pixels else { return loaded.image.size }
        let scale = window?.backingScaleFactor ?? 2
        return NSSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    // MARK: Zoom

    /// Big pictures shrink to fit; small ones stay at actual size, as in FastStone.
    private func applyFit() {
        let size = canvas.frame.size
        let visible = scroll.contentSize
        guard size.width > 0, size.height > 0, visible.width > 0 else { return }
        let scale = min(visible.width / size.width, visible.height / size.height, 1)
        scroll.magnification = scale
        (scroll.contentView as? CenteringClipView)?.scrollConstrained(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateLabels()
    }

    func toggleZoom(at point: NSPoint) {
        if fitMode && scroll.magnification < 0.999 {
            fitMode = false
            scroll.setMagnification(1, centeredAt: point)
            sharpenIfNeeded()
        } else {
            fitMode = true
            applyFit()
        }
        updateLabels()
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

    /// Delete: to the Trash, and on to the next picture.
    @objc func delete(_ sender: Any?) {
        guard let url = current else { return }
        FileOps.trash([url]) { [weak self] removed in
            guard let self, !removed.isEmpty else { return }
            self.urls.removeAll { $0.key == url.key }
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
        fit(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "viewerFullScreen")
        fit(nil)
    }

    /// ⌘Z brings back a picture deleted here, as it does in the file list.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        FileUndo.manager
    }

    func windowWillClose(_ notification: Notification) {
        slideshow?.invalidate()
        slideshow = nil
        playButton.isOn = false
        hideWork?.cancel()
        cache = [:]
        canvas.image = nil
        original = nil
        shown = nil
        Self.shared = nil
    }
}
