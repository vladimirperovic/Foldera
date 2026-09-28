import AppKit
import QuickLookThumbnailing

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
    var target: AnyObject?
    var action: Selector?
    var index = 0
    var isEnabled = true { didSet { if oldValue != isEnabled { needsDisplay = true } } }
    var isOn = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var label: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { invalidateIntrinsicContentSize() } }

    private let image: NSImage?
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
        dots.tags = item.tags
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

/// One tile in the large icons view: a picture of the file and its name.
final class IconItem: NSCollectionViewItem {
    private let background = SelectionBackground()
    private let picture = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var key: String?
    private lazy var pictureWidth = picture.widthAnchor.constraint(equalToConstant: 64)
    private lazy var pictureHeight = picture.heightAnchor.constraint(equalToConstant: 64)

    /// The picture size, from the slider under the list.
    var side: CGFloat = 64 {
        didSet {
            guard side != oldValue else { return }
            pictureWidth.constant = side
            pictureHeight.constant = side
            label.preferredMaxLayoutWidth = ExplorerTab.tileSize(side).width - 8
        }
    }

    override func loadView() {
        view = background
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = 100
        for v in [picture, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            picture.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            pictureWidth,
            pictureHeight,
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
        ])
        imageView = picture
        textField = label
    }

    override var isSelected: Bool {
        didSet { background.selected = isSelected }
    }

    func configure(_ item: FileItem, dimmed: Bool) {
        key = item.key
        picture.image = item.icon
        picture.alphaValue = dimmed || item.isHidden ? 0.45 : 1
        label.stringValue = item.name
        background.selected = isSelected
        guard !item.isFolder else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        Thumbnails.shared.image(for: item.url, side: side, scale: scale) { [weak self] image in
            guard self?.key == item.key else { return }
            self?.picture.image = image
        }
    }
}

/// Pictures of photos, PDFs and videos for the icons view, made by Quick Look.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    /// Bounded by memory, not count: 2,000 thumbnails at 128×128 would be 128 MB.
    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

    func image(for url: URL, side: CGFloat, scale: CGFloat, done: @escaping (NSImage) -> Void) {
        let cacheKey = "\(url.path)|\(side)" as NSString
        if let image = cache.object(forKey: cacheKey) {
            done(image)
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            let cost = Int(representation?.cgImage.width ?? 0) * Int(representation?.cgImage.height ?? 0) * 4
            DispatchQueue.main.async {
                self?.cache.setObject(image, forKey: cacheKey, cost: cost)
                done(image)
            }
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
