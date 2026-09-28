import AppKit

/// The Windows address bar: `This Mac › Macintosh HD › Users › you`, every
/// part clickable, every › a menu of the folders inside. Click the empty part
/// (or ⌘L, F4, ⌥D) and it becomes a text field for typing a path.
final class AddressBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((Location) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var location: Location = .thisMac {
        didSet { rebuild() }
    }

    private(set) var isEditing = false
    private let icon = NSImageView()
    private let crumbs = NSStackView()
    private let overflow = ToolButton(symbol: "chevron.left.2", tip: "Earlier locations", iconSize: 9, height: 24, padding: 5)
    private let field = NSTextField()
    private var parts: [(title: String, location: Location)] = []
    private var firstVisible = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.detachesHiddenViews = true
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)
        // A long path must not hold the window open: the crumbs may be cut
        // short, and fitCrumbs then folds the leading ones into «.
        crumbs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        overflow.target = self
        overflow.action = #selector(showOverflow(_:))

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true

        for v in [icon, crumbs, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            crumbs.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        path.lineWidth = isEditing ? 2 : 1
        (isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    /// A click on the empty part of the bar turns it into a text field.
    override func mouseDown(with event: NSEvent) { beginEditing() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Crumbs

    static func parts(for location: Location) -> [(title: String, location: Location)] {
        var out: [(String, Location)] = [("This Mac", .thisMac)]
        guard let url = location.url else { return out }
        // Inside an opened archive: the archive's own path, then the archive, then the folders in it.
        if let archive = ArchiveFolders.context(of: url) {
            var parts = Self.parts(for: .folder(archive.archive.deletingLastPathComponent()))
            parts.append((archive.archive.lastPathComponent, .folder(archive.root)))
            var current = archive.root
            for name in url.key.dropFirst(archive.root.key.count).split(separator: "/") {
                current.appendPathComponent(String(name), isDirectory: true)
                parts.append((String(name), .folder(current)))
            }
            return parts
        }
        let components = url.standardizedFileURL.pathComponents
        var rootPath = "/"
        var consumed = 1
        if components.count >= 3 && components[1] == "Volumes" {
            rootPath = "/Volumes/" + components[2]
            consumed = 3
        }
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        out.append((volumeName(current), .folder(current)))
        for name in components.dropFirst(consumed) {
            current.appendPathComponent(name, isDirectory: true)
            out.append((name, .folder(current)))
        }
        return out
    }

    private func rebuild() {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        parts = Self.parts(for: location)
        icon.image = location.icon
        crumbs.addArrangedSubview(overflow)
        for (i, part) in parts.enumerated() {
            let name = ToolButton(label: part.title, tip: nil, height: 24, padding: 5)
            name.index = i
            name.target = self
            name.action = #selector(crumbClicked(_:))
            let chevron = ToolButton(symbol: "chevron.right", tip: "Folders in \(part.title)", iconSize: 9, height: 24, padding: 4)
            chevron.index = i
            chevron.target = self
            chevron.action = #selector(chevronClicked(_:))
            crumbs.addArrangedSubview(name)
            crumbs.addArrangedSubview(chevron)
        }
        firstVisible = -1
        needsLayout = true
        if isEditing { field.stringValue = editingText }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fitCrumbs()
    }

    /// When the path is wider than the bar, the leading parts fold into «, as in Windows.
    private func fitCrumbs() {
        let views = crumbs.arrangedSubviews.filter { $0 !== overflow }
        guard views.count == parts.count * 2, !parts.isEmpty else { return }
        let available = bounds.width - 32 - overflow.intrinsicContentSize.width
        var used: CGFloat = 0
        var first = parts.count - 1
        for i in stride(from: parts.count - 1, through: 0, by: -1) {
            let w = views[i * 2].intrinsicContentSize.width + views[i * 2 + 1].intrinsicContentSize.width
            if used + w > available && i < parts.count - 1 { break }
            used += w
            first = i
        }
        guard first != firstVisible else { return }
        firstVisible = first
        for (n, view) in views.enumerated() { view.isHidden = n / 2 < first }
        overflow.isHidden = first == 0
    }

    /// Menus use plain file names: asking Finder for display names costs a
    /// lookup per item, and would not match the crumbs anyway.
    private func menuItem(_ location: Location, title: String? = nil) -> NSMenuItem {
        let name = title ?? location.url.map { isVolumeRoot($0) ? volumeName($0) : $0.lastPathComponent } ?? location.title
        let item = NSMenuItem(title: name, action: #selector(menuPicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = location
        item.image = menuIcon(location.icon)
        return item
    }

    @objc private func crumbClicked(_ sender: ToolButton) {
        onNavigate?(parts[sender.index].location)
    }

    @objc private func chevronClicked(_ sender: ToolButton) {
        let place = parts[sender.index].location
        let children: [Location]
        switch place {
        case .thisMac: children = FileItem.volumes().map { .folder($0.url) }
        case .folder(let url): children = Folders.subfolders(of: url).map { .folder($0) }
        }
        let menu = NSMenu()
        let next = sender.index + 1 < parts.count ? parts[sender.index + 1].location : nil
        for child in children {
            let item = menuItem(child)
            if child == next { item.state = .on }
            menu.addItem(item)
        }
        if children.isEmpty {
            let empty = NSMenuItem(title: "No folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        sender.popUp(menu)
    }

    @objc private func showOverflow(_ sender: ToolButton) {
        let menu = NSMenu()
        for part in parts.prefix(max(firstVisible, 0)).reversed() { menu.addItem(menuItem(part.location, title: part.title)) }
        sender.popUp(menu)
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        if let location = sender.representedObject as? Location { onNavigate?(location) }
    }

    // MARK: Typing a path

    private var editingText: String {
        guard let url = location.url else { return "This Mac" }
        if let archive = ArchiveFolders.context(of: url) {
            return archive.archive.path + url.key.dropFirst(archive.root.key.count)
        }
        return url.path
    }

    func beginEditing() {
        if !isEditing {
            isEditing = true
            field.stringValue = editingText
            field.isHidden = false
            crumbs.isHidden = true
            needsDisplay = true
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        crumbs.isHidden = false
        needsDisplay = true
        needsLayout = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            endEditing()
            onSubmit?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            onCancel?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            return complete(textView)
        default:
            return false
        }
    }

    /// Tab finishes a folder name, as far as it is unambiguous.
    private func complete(_ textView: NSTextView) -> Bool {
        let typed = (field.stringValue as NSString).expandingTildeInPath
        guard typed.hasPrefix("/") else { return false }
        let folder = typed.hasSuffix("/") ? typed : (typed as NSString).deletingLastPathComponent
        let prefix = typed.hasSuffix("/") ? "" : (typed as NSString).lastPathComponent
        let names = Folders.subfolders(of: URL(fileURLWithPath: folder))
            .map(\.lastPathComponent)
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
        guard let first = names.first else { return true }
        var common = first
        for name in names.dropFirst() {
            while !name.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        var completed = (folder as NSString).appendingPathComponent(common.count >= prefix.count ? common : prefix)
        if names.count == 1 { completed += "/" }
        field.stringValue = completed
        textView.selectedRange = NSRange(location: (completed as NSString).length, length: 0)
        return true
    }
}
