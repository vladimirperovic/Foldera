import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Draws a template image in `color`, resolved when it is drawn, so light and
/// dark mode both come out right.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        // Paint the colour, then keep it only where the symbol is, so a
        // translucent colour (disabled) stays translucent.
        color.set()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
}

/// A flat button in the Windows 11 manner: an icon and/or a word, with a soft
/// highlight only while the pointer is over it.
final class ToolButton: NSView {
    /// Weak, as NSControl's is: the target owns the view the button is in,
    /// and a strong one kept every closed tab alive.
    weak var target: AnyObject?
    var action: Selector?
    var index = 0
    var isEnabled = true { didSet { if oldValue != isEnabled { needsDisplay = true } } }
    var isOn = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var label: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { invalidateIntrinsicContentSize() } }

    private var image: NSImage?
    private let tint: NSColor?
    private let dropdown: Bool
    private let height: CGFloat
    private let padding: CGFloat
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }

    init(symbol: String? = nil, label: String? = nil, tip: String? = nil, dropdown: Bool = false,
         iconSize: CGFloat = 15, height: CGFloat = 30, padding: CGFloat? = nil, tint: NSColor? = nil) {
        image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: tip ?? label)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))
        }
        self.label = label
        self.dropdown = dropdown
        self.height = height
        self.padding = padding ?? (label == nil ? 7 : 9)
        self.tint = tint
        super.init(frame: .zero)
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip ?? label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ symbol: String, iconSize: CGFloat = 15) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip ?? label)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var hasLabel: Bool { !(label ?? "").isEmpty }
    private var labelWidth: CGFloat {
        guard let label, hasLabel else { return 0 }
        return ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    private var contentWidth: CGFloat {
        var w: CGFloat = 0
        if let image { w += image.size.width }
        if image != nil && hasLabel { w += 6 }
        w += labelWidth
        if dropdown { w += 13 }
        return w
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(contentWidth + padding * 2, height), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovering || pressed || isOn) {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.15 : (isOn ? 0.11 : 0.07)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = isEnabled ? (tint ?? .labelColor) : .tertiaryLabelColor
        var x = floor((bounds.width - contentWidth) / 2)
        if let image {
            let s = image.size
            tinted(image, color).draw(in: NSRect(x: x, y: floor((bounds.height - s.height) / 2), width: s.width, height: s.height))
            x += s.width + (hasLabel ? 6 : 0)
        }
        if let label, hasLabel {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let s = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: x, y: floor((bounds.height - s.height) / 2)), withAttributes: attributes)
            x += labelWidth
        }
        if dropdown, let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let s = chevron.size
            tinted(chevron, isEnabled ? .secondaryLabelColor : .tertiaryLabelColor)
                .draw(in: NSRect(x: x + 5, y: floor((bounds.height - s.height) / 2), width: s.width, height: s.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        displayIfNeeded()
        // Track like a real button: letting go outside cancels.
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            displayIfNeeded()
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside, let action { NSApp.sendAction(action, to: target, from: self) }
        // A menu may have been open while the pointer left.
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    /// Pops `menu` up just below the button, as Windows' dropdowns do.
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 2, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let statusColumn = NSUserInterfaceItemIdentifier("status")
    static let locationColumn = NSUserInterfaceItemIdentifier("location")
    static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let freeColumn = NSUserInterfaceItemIdentifier("free")
    static let createdColumn = NSUserInterfaceItemIdentifier("created")
    static let accessedColumn = NSUserInterfaceItemIdentifier("accessed")
    static let extensionColumn = NSUserInterfaceItemIdentifier("extension")
    static let tagsColumn = NSUserInterfaceItemIdentifier("tags")
    static let nameCell = NSUserInterfaceItemIdentifier("NameCell")
    static let textCell = NSUserInterfaceItemIdentifier("TextCell")
    static let iconItem = NSUserInterfaceItemIdentifier("IconItem")
}

/// Icon and name, the first column of the details view.
final class NameCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .nameCell
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        text.focusRingType = .none
        // The name gives way (truncates) before the tag dots do.
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for v in [image, text, dots] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            dots.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 5),
            dots.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            dots.centerYAnchor.constraint(equalTo: centerYAnchor),
            dots.heightAnchor.constraint(equalToConstant: 12),
        ])
        imageView = image
        textField = text
    }

    private let dots = TagDots()

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: FileItem, dimmed: Bool) {
        imageView?.image = item.icon
        imageView?.alphaValue = dimmed || item.isHidden ? 0.45 : 1
        textField?.stringValue = item.name
        // Tags not read yet are read in the background (see ExplorerTab.readTags), and the row drawn again.
        dots.tags = item.shownTags
        textField?.isEditable = false
        textField?.isBordered = false
        textField?.drawsBackground = false
    }

    /// Windows' rename box: the name in an edit field, only the part before
    /// the extension selected.
    func beginRename(stemLength: Int) -> Bool {
        guard let field = textField, let window else { return false }
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        guard window.makeFirstResponder(field) else { return false }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: stemLength)
        return true
    }
}

/// The Status column: where an iCloud item is, as a small symbol.
final class StatusCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("StatusCell")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        let image = NSImageView()
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ cloud: FileItem.Cloud?) {
        imageView?.image = cloud.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.description) }
        imageView?.contentTintColor = cloud == .local ? .systemGreen : .secondaryLabelColor
        toolTip = cloud?.description
    }
}

/// The Free space column of This Mac, as Windows' This PC draws it: a bar
/// of how full the drive is (red when nearly full), and what is free.
final class DriveUsageCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("DriveUsageCell")
    private let bar = UsageBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        let text = NSTextField(labelWithString: "")
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        for v in [bar, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 64),
            bar.heightAnchor.constraint(equalToConstant: 6),
            text.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ volume: FileItem.Volume) {
        bar.fraction = volume.total > 0 ? Double(volume.total - volume.free) / Double(volume.total) : 0
        textField?.stringValue = "\(Format.bytes(volume.free)) free"
        toolTip = "\(Format.bytes(volume.free)) free of \(Format.bytes(volume.total))"
    }
}

final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let filled = bounds.width * CGFloat(min(max(fraction, 0), 1))
        guard filled > 0 else { return }
        (fraction > 0.9 ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(filled, bounds.height), height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// Every other column: one line of grey text.
final class TextCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .textCell
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = text
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The details view. Right-clicking selects what is under the pointer first,
/// as in Windows, then asks the window for its menu.
final class FileTableView: NSTableView {
    weak var host: ExplorerTab?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        return host?.contextMenu()
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { host?.openInNewTab(item: row) } else { super.otherMouseDown(with: event) }
    }
}

/// The large icons view.
final class FileCollectionView: NSCollectionView {
    weak var host: ExplorerTab?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            host?.openSelection(nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(path) { selectionIndexPaths = [path] }
        } else {
            selectionIndexPaths = []
        }
        host?.selectionChanged()
        return host?.contextMenu()
    }

    /// ⌘ (or ⌃, as in Windows) and the scroll wheel make the pictures bigger or smaller.
    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty, let host else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        host.setIconSize(Prefs.iconSize + delta)
    }

    override func otherMouseDown(with event: NSEvent) {
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            host?.openInNewTab(item: path.item)
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

final class SelectionBackground: NSView {
    var selected = false { didSet { if oldValue != selected { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

/// The selection over a picture that fills its tile, where the one behind can't show.
final class SelectionFrame: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
        NSColor.selectedContentBackgroundColor.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        edge.lineWidth = 4
        edge.stroke()
    }
}

/// Where things go in the large icons view. The gaps shrink as the pictures
/// grow, and at the largest size there are none: the pictures fill their
/// tiles edge to edge, without names (they are in the tooltips), as a
/// contact sheet. The tiles always widen to fill their row, so what a row
/// leaves over isn't spread between them as gaps.
struct IconGeometry: Equatable {
    static let largest: CGFloat = 256

    /// The picture's side, and the tile it is in.
    var side: CGFloat = 64
    var tile = NSSize(width: 108, height: 120)
    /// Between the tiles, across and down.
    var gap: CGFloat = 4
    /// Around them all; the sides also take what is left of a pixel-aligned row.
    var margin: CGFloat = 10
    var left: CGFloat = 10
    var right: CGFloat = 10
    /// Above the picture in its tile.
    var top: CGFloat = 8
    /// False at the largest size: pictures only, filling their tiles.
    var names = true

    var insets: NSEdgeInsets { NSEdgeInsets(top: margin, left: left, bottom: margin, right: right) }

    /// The size to ask Quick Look for: a picture cut square needs its short
    /// side as long as the tile. In steps, so resizing the window doesn't
    /// have every picture made again.
    var thumbnailSide: CGFloat {
        ((names ? side : side * 1.8) / 32).rounded(.up) * 32
    }

    init() {}

    /// `wanted` is the slider's size; `width` the room across the view.
    init(side wanted: CGFloat, width: CGFloat, scale: CGFloat) {
        names = wanted < Self.largest
        // 0 at the usual size, 1 at the largest.
        let t = min(max((wanted - 64) / (Self.largest - 64), 0), 1)
        let names = self.names
        func shrink(_ value: CGFloat) -> CGFloat { names ? (value * (1 - t)).rounded() : 0 }
        gap = shrink(4)
        margin = shrink(10)
        top = shrink(8)
        // Room beside a picture for its name, and the narrowest a named tile goes.
        let natural = names ? max(wanted + shrink(44), 108) : wanted
        let room = width - 2 * margin
        var across = natural
        left = margin
        right = margin
        if room >= natural {
            let columns = ((room + gap) / (natural + gap)).rounded(.down)
            across = ((room - gap * (columns - 1)) / columns * scale).rounded(.down) / scale
            let spare = room - across * columns - gap * (columns - 1)
            left += (spare / 2 * scale).rounded(.down) / scale
            right += spare - (left - margin)
        } else if room > 0 {
            // A narrow pane: one tile, as wide as there is room.
            across = max((room * scale).rounded(.down) / scale, 40)
        }
        side = max(across - (natural - wanted), 16)
        tile = NSSize(width: across, height: names ? top + side + 4 + 30 + 2 + shrink(12) : across)
    }
}

/// The large icons view's layout: a flow layout set out by IconGeometry for
/// the width it has.
final class IconLayout: NSCollectionViewFlowLayout {
    /// The picture size from the slider.
    var side: CGFloat = 64 { didSet { if side != oldValue { invalidateLayout() } } }
    private(set) var geometry = IconGeometry()
    /// Called during layout when the geometry changes, for the tiles on screen.
    var onChange: ((IconGeometry) -> Void)?
    private var laidOutWidth: CGFloat = -1

    override func prepare() {
        let view = collectionView
        let width = view?.enclosingScrollView?.contentSize.width ?? view?.bounds.width ?? 0
        laidOutWidth = width
        let fresh = IconGeometry(side: side, width: width, scale: view?.window?.backingScaleFactor ?? 2)
        // Each of these lays out again when set, so only when it changes.
        if itemSize != fresh.tile { itemSize = fresh.tile }
        if minimumInteritemSpacing != fresh.gap { minimumInteritemSpacing = fresh.gap }
        if minimumLineSpacing != fresh.gap { minimumLineSpacing = fresh.gap }
        if !NSEdgeInsetsEqual(sectionInset, fresh.insets) { sectionInset = fresh.insets }
        super.prepare()
        guard fresh != geometry else { return }
        geometry = fresh
        onChange?(fresh)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != laidOutWidth || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

/// One tile in the large icons view: a picture of the file and its name.
final class IconItem: NSCollectionViewItem {
    private let background = SelectionBackground()
    private let picture = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let selectionFrame = SelectionFrame()
    private var key: String?
    /// The file's own picture, before it is cut square for a contact sheet.
    private var shown: NSImage?
    /// The thumbnail being made for this tile, given up if the tile moves on first.
    private var thumbnail: Thumbnails.Ticket?
    private lazy var pictureTop = picture.topAnchor.constraint(equalTo: background.topAnchor, constant: 8)
    private lazy var pictureWidth = picture.widthAnchor.constraint(equalToConstant: 64)
    private lazy var pictureHeight = picture.heightAnchor.constraint(equalToConstant: 64)

    /// Where the picture and the name go, from the view's layout.
    var geometry = IconGeometry() {
        didSet {
            guard geometry != oldValue else { return }
            pictureTop.constant = geometry.top
            pictureWidth.constant = geometry.side
            pictureHeight.constant = geometry.side
            label.preferredMaxLayoutWidth = geometry.tile.width - 8
            label.isHidden = !geometry.names
            // A wide picture sits on its name, as in Finder.
            picture.imageAlignment = geometry.names ? .alignBottom : .alignCenter
            if geometry.names != oldValue.names { show(shown) }
            updateSelection()
        }
    }

    override func loadView() {
        view = background
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignBottom
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = 100
        selectionFrame.isHidden = true
        for v in [picture, label, selectionFrame] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            pictureTop,
            picture.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            pictureWidth,
            pictureHeight,
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            selectionFrame.topAnchor.constraint(equalTo: picture.topAnchor),
            selectionFrame.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
            selectionFrame.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
            selectionFrame.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
        ])
        imageView = picture
        textField = label
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        background.selected = isSelected
        selectionFrame.isHidden = !(isSelected && !geometry.names)
    }

    /// The picture as it is, or cut square to fill a contact sheet's tile.
    private func show(_ image: NSImage?) {
        shown = image
        picture.image = image.map { geometry.names ? $0 : Self.squared($0) }
    }

    /// The middle square of a picture, drawn when shown so it stays sharp.
    private static func squared(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0, size.width != size.height else { return image }
        let edge = min(size.width, size.height)
        let from = NSRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
        return NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            image.draw(in: rect, from: from, operation: .copy, fraction: 1)
            return true
        }
    }

    /// The tile went out of sight (or is shown for another file): its thumbnail is no longer wanted.
    func stopThumbnail() {
        if let thumbnail { Thumbnails.shared.cancel(thumbnail) }
        thumbnail = nil
    }

    func configure(_ item: FileItem, dimmed: Bool) {
        let scale = view.window?.backingScaleFactor ?? 2
        let side = geometry.thumbnailSide
        let wanted = item.isFolder ? nil : Thumbnails.cacheKey(for: item.url, side: side, scale: scale, version: item.modified)
        // Drawn again for the same file (a cut, a refresh): the picture on its way stays on its way.
        if thumbnail?.key != wanted { stopThumbnail() }
        key = item.key
        show(item.icon)
        picture.alphaValue = dimmed || item.isHidden ? 0.45 : 1
        label.stringValue = item.name
        background.toolTip = geometry.names ? nil : item.name
        updateSelection()
        guard !item.isFolder, thumbnail == nil else { return }
        thumbnail = Thumbnails.shared.image(for: item.url, side: side, scale: scale, version: item.modified) { [weak self] image in
            guard let self, self.key == item.key else { return }
            self.thumbnail = nil
            self.show(image)
        }
    }
}

/// Pictures of photos, PDFs and videos for the icons view, made by Quick Look.
/// On the main thread.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    /// One request for a picture being made, with the tiles waiting for it.
    private struct Pending {
        let request: QLThumbnailGenerator.Request
        var waiting: [UUID: (NSImage) -> Void]
    }
    /// A picture asked for again while it is being made isn't made twice.
    private var pending: [NSString: Pending] = [:]

    /// Hands back a picture still being made, to stop waiting for it.
    struct Ticket {
        fileprivate let key: NSString
        fileprivate let id: UUID
    }

    /// Bounded by memory, not count: 2,000 thumbnails at 128×128 would be 128 MB,
    /// and a screenful of a contact sheet's pictures about 40 MB.
    init() { cache.totalCostLimit = 96 * 1024 * 1024 }

    /// `version` is the file's modification date, so an edited picture gets a new thumbnail.
    static func cacheKey(for url: URL, side: CGFloat, scale: CGFloat, version: Date?) -> NSString {
        "\(url.path)|\(side)@\(scale)|\(version?.timeIntervalSince1970 ?? 0)" as NSString
    }

    /// Returns nil when the picture was ready (and `done` called).
    @discardableResult
    func image(for url: URL, side: CGFloat, scale: CGFloat, version: Date?, done: @escaping (NSImage) -> Void) -> Ticket? {
        let cacheKey = Self.cacheKey(for: url, side: side, scale: scale, version: version)
        if let image = cache.object(forKey: cacheKey) {
            done(image)
            return nil
        }
        let ticket = Ticket(key: cacheKey, id: UUID())
        if pending[cacheKey] != nil {
            pending[cacheKey]?.waiting[ticket.id] = done
            return ticket
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        pending[cacheKey] = Pending(request: request, waiting: [ticket.id: done])
        let picture = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            let cost = Int(representation?.cgImage.width ?? 0) * Int(representation?.cgImage.height ?? 0) * 4
            DispatchQueue.main.async {
                // A request given up and asked for again since is a new one; this answer isn't for it.
                guard let self, let entry = self.pending[cacheKey], entry.request === request else { return }
                guard let image else {
                    if picture { self.readPicture(url, side: side, scale: scale, key: cacheKey, request: request) } else { self.pending[cacheKey] = nil }
                    return
                }
                self.pending[cacheKey] = nil
                self.deliver(image, cost: cost, key: cacheKey, to: entry)
            }
        }
        return ticket
    }

    private func deliver(_ image: NSImage, cost: Int, key: NSString, to entry: Pending) {
        cache.setObject(image, forKey: key, cost: cost)
        entry.waiting.values.forEach { $0(image) }
    }

    /// Quick Look picks its reader by the extension, ImageIO by what is in
    /// the file: a picture saved under the wrong one (a WebP named .avif, as
    /// some sites hand out) still gets its thumbnail.
    private func readPicture(_ url: URL, side: CGFloat, scale: CGFloat, key: NSString, request: QLThumbnailGenerator.Request) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.imageIOThumbnail(url, pixels: Int(side * scale))
            DispatchQueue.main.async {
                guard let self, let entry = self.pending[key], entry.request === request else { return }
                self.pending[key] = nil
                guard let image else { return }
                self.deliver(NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)), cost: image.width * image.height * 4, key: key, to: entry)
            }
        }
    }

    static func imageIOThumbnail(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    /// The tile scrolled away before its picture came: once nobody waits
    /// for it, Quick Look stops making it, so a fast scroll doesn't queue
    /// up hundreds of pictures nobody will see.
    func cancel(_ ticket: Ticket) {
        guard var entry = pending[ticket.key] else { return }
        entry.waiting[ticket.id] = nil
        if entry.waiting.isEmpty {
            pending[ticket.key] = nil
            QLThumbnailGenerator.shared.cancel(entry.request)
        } else {
            pending[ticket.key] = entry
        }
    }
}

/// Windows' search options, as a row under the command bar: kind, size and
/// date. Setting one searches the folder and everything below it.
final class FilterBar: NSView {
    var onChange: ((SearchFilters) -> Void)?
    private let kind = NSPopUpButton()
    private let size = NSPopUpButton()
    private let modified = NSPopUpButton()
    private let clear = NSButton(title: "Clear", target: nil, action: nil)

    var filters: SearchFilters {
        get {
            SearchFilters(
                kind: SearchFilters.Kind(rawValue: kind.selectedItem?.representedObject as? String ?? "") ?? .any,
                size: SearchFilters.Size(rawValue: size.selectedItem?.representedObject as? String ?? "") ?? .any,
                modified: SearchFilters.Modified(rawValue: modified.selectedItem?.representedObject as? String ?? "") ?? .any)
        }
        set {
            select(kind, newValue.kind.rawValue)
            select(size, newValue.size.rawValue)
            select(modified, newValue.modified.rawValue)
            clear.isEnabled = newValue.isActive
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill(kind, SearchFilters.Kind.allCases.map { ($0.rawValue, $0.title) }, symbol: "doc.on.doc")
        fill(size, SearchFilters.Size.allCases.map { ($0.rawValue, $0.title) }, symbol: "internaldrive")
        fill(modified, SearchFilters.Modified.allCases.map { ($0.rawValue, $0.title) }, symbol: "calendar")
        clear.bezelStyle = .push
        clear.controlSize = .small
        clear.target = self
        clear.action = #selector(clearAll(_:))
        clear.isEnabled = false
        let title = NSTextField(labelWithString: "Search options")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title, kind, size, modified, clear])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func fill(_ popup: NSPopUpButton, _ entries: [(String, String)], symbol: String) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        for (value, title) in entries {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.item(at: 0)?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        popup.target = self
        popup.action = #selector(changed(_:))
    }

    private func select(_ popup: NSPopUpButton, _ value: String) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == value }) { popup.select(item) }
    }

    @objc private func changed(_ sender: Any?) {
        clear.isEnabled = filters.isActive
        onChange?(filters)
    }

    @objc private func clearAll(_ sender: Any?) {
        filters = SearchFilters()
        onChange?(filters)
    }
}
