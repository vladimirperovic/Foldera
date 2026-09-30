import AppKit

/// A window of tabs, as Windows 11's File Explorer has them: in the title
/// bar, about 220 points (4–5 cm on a MacBook) each, and a + right after the
/// last one. Every tab is an ExplorerTab with its own place and history;
/// the ones not on screen keep their state but draw nothing.
final class ExplorerWindow: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [ExplorerTab] = []
    private(set) weak var selected: ExplorerTab?
    let strip = TabStrip()
    private let container = NSView()
    private lazy var stripHeight = strip.heightAnchor.constraint(equalToConstant: 40)
    private var keyMonitor: Any?
    private var quickOpenController: QuickOpenController?
    var onClose: (() -> Void)?

    init(first: ExplorerTab) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        if let content = window.contentView {
            strip.host = self
            for v in [strip, container] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(v)
            }
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: content.topAnchor),
                strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stripHeight,
                container.topAnchor.constraint(equalTo: strip.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        add(first)
        // ⌃⇥ and ⌃⇧⇥ walk the tabs, as in every tabbed app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 48,
                  event.modifierFlags.contains(.control) else { return event }
            event.modifierFlags.contains(.shift) ? self.selectPreviousTab(nil) : self.selectNextTab(nil)
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Once on screen: the tabs start just right of the window buttons and
    /// line up with them.
    func windowShown() {
        guard let window, let zoom = window.standardWindowButton(.zoomButton), let bar = zoom.superview else { return }
        let frame = bar.convert(zoom.frame, to: nil)
        strip.leadingInset = frame.maxX + 14
        let centre = window.frame.height - frame.midY
        stripHeight.constant = max(36, (centre + TabStrip.tabHeight / 2).rounded())
    }

    // MARK: Tabs

    func add(_ tab: ExplorerTab, select: Bool = true) {
        tab.host = self
        tabs.append(tab)
        if select || selected == nil { self.select(tab) } else { strip.reload(tabs, selected: selected) }
    }

    func select(_ tab: ExplorerTab) {
        guard selected !== tab, tabs.contains(where: { $0 === tab }) else { return }
        selected?.view.removeFromSuperview()
        selected = tab
        let view = tab.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Menu commands find the tab through the responder chain: view → tab → container.
        view.nextResponder = tab
        tab.nextResponder = container
        tab.didAttach()
        tab.focusList()
        tab.updateCommandStates()
        tabDidChange(tab)
    }

    func close(_ tab: ExplorerTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else {
            window?.performClose(nil)
            return
        }
        tab.tearDown()
        tabs.remove(at: index)
        if selected === tab {
            tab.view.removeFromSuperview()
            selected = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            strip.reload(tabs, selected: selected)
        }
    }

    /// Takes a tab out without closing it, to move it to another window.
    func detach(_ tab: ExplorerTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if selected === tab {
            tab.view.removeFromSuperview()
            selected = nil
            select(tabs[min(index, tabs.count - 1)])
        } else {
            strip.reload(tabs, selected: selected)
        }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        tabs.insert(tabs.remove(at: from), at: to)
    }

    /// A tab went somewhere new: its title and icon, and the window's.
    func tabDidChange(_ tab: ExplorerTab) {
        strip.reload(tabs, selected: selected)
        guard tab === selected, let window else { return }
        window.title = tab.tabTitle
        window.representedURL = tab.representedURL
    }

    // MARK: Commands

    func showQuickOpen(scope: QuickOpenController.Scope, query: String = "") {
        guard let selected, let window, window.attachedSheet == nil else { return }
        let controller = QuickOpenController(tab: selected, scope: scope)
        controller.setQuery(query)
        quickOpenController = controller
        controller.present(in: window) { [weak self] in self?.quickOpenController = nil }
    }

    @objc func newTab(_ sender: Any?) {
        add(ExplorerTab(location: .folder(FileManager.default.homeDirectoryForCurrentUser)))
    }

    override func newWindowForTab(_ sender: Any?) { newTab(sender) }

    @objc func closeTab(_ sender: Any?) {
        if let selected { close(selected) }
    }

    @objc func selectNextTab(_ sender: Any?) { step(1) }
    @objc func selectPreviousTab(_ sender: Any?) { step(-1) }

    private func step(_ delta: Int) {
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0 === selected }) else { return }
        select(tabs[(current + delta + tabs.count) % tabs.count])
    }

    func duplicate(_ tab: ExplorerTab) {
        add(ExplorerTab(location: tab.location, select: tab.selectedURLs))
    }

    func closeOthers(_ tab: ExplorerTab) {
        for other in tabs where other !== tab { close(other) }
    }

    func closeToTheRight(of tab: ExplorerTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        for other in tabs[(index + 1)...] { close(other) }
    }

    func moveToNewWindow(_ tab: ExplorerTab) {
        guard tabs.count > 1 else { return }
        detach(tab)
        (NSApp.delegate as? AppDelegate)?.adopt(tab)
    }

    /// Anything the window can't do, the tab on screen may: menu commands
    /// still reach it when nothing inside it has the keyboard focus.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let selected, selected.responds(to: action) { return selected }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        selected?.undoManager(in: window) ?? FileUndo.manager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        selected?.updateCommandStates()
    }

    func windowWillClose(_ notification: Notification) {
        tabs.forEach { $0.tearDown() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onClose?()
    }
}

/// The row of tabs in the title bar. Its empty part moves the window and
/// a double-click there zooms it, as the title bar would.
final class TabStrip: NSView {
    weak var host: ExplorerWindow?
    /// About 4–5 cm on a MacBook screen; tabs shrink below it only when many are open.
    static let tabWidth: CGFloat = 220
    static let minimumTabWidth: CGFloat = 32
    static let tabHeight: CGFloat = 30

    var leadingInset: CGFloat = 80 { didSet { needsLayout = true } }
    private var buttons: [TabButton] = []
    private weak var dragged: TabButton?
    private let scroll = NSScrollView()
    private let tabCanvas = NSView()
    private let plus = ToolButton(symbol: "plus", tip: "New tab (⌘T)", iconSize: 13, height: 28, padding: 8)

    /// A shade darker than the window, so the selected tab reads as part of what is below it.
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.86, alpha: 1)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.target = self
        plus.action = #selector(newTab(_:))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = tabCanvas
        addSubview(scroll)
        addSubview(plus)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload(_ tabs: [ExplorerTab], selected: ExplorerTab?) {
        while buttons.count < tabs.count {
            let button = TabButton()
            button.strip = self
            tabCanvas.addSubview(button)
            buttons.append(button)
        }
        while buttons.count > tabs.count { buttons.removeLast().removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let button = buttons[index]
            button.tab = tab
            button.title = tab.tabTitle
            button.icon = tab.tabIcon
            button.isSelected = tab === selected
            button.toolTip = tab.location.url.map(Format.path) ?? tab.tabTitle
        }
        needsLayout = true
    }

    /// Shrink to icons before scrolling. The add button always has its own space.
    static func widthForTabs(count: Int, room: CGFloat) -> CGFloat {
        max(minimumTabWidth, min(tabWidth, floor(max(room, 0) / CGFloat(max(count, 1)))))
    }

    private var tabWidth: CGFloat { Self.widthForTabs(count: buttons.count, room: bounds.width - leadingInset - 44) }

    override func layout() {
        super.layout()
        let width = tabWidth
        let contentWidth = width * CGFloat(buttons.count)
        let viewport = min(contentWidth, max(bounds.width - leadingInset - 44, 0))
        scroll.frame = NSRect(x: leadingInset, y: 0, width: viewport, height: Self.tabHeight)
        tabCanvas.frame = NSRect(x: 0, y: 0, width: contentWidth, height: Self.tabHeight)
        var x: CGFloat = 0
        for button in buttons {
            if button !== dragged {
                button.frame = NSRect(x: x, y: 0, width: width, height: Self.tabHeight)
            }
            x += width
        }
        plus.frame = NSRect(x: leadingInset + viewport + 4, y: (Self.tabHeight - 28) / 2, width: 30, height: 28)
        if dragged == nil, let selected = buttons.first(where: \.isSelected) {
            tabCanvas.scrollToVisible(selected.frame)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func newTab(_ sender: Any?) { host?.newTab(sender) }

    /// Dragging a tab along the row: the others make room as it passes them.
    func drag(_ button: TabButton, to x: CGFloat) {
        dragged = button
        let width = tabWidth
        button.frame.origin.x = min(max(x, 0), width * CGFloat(buttons.count - 1))
        tabCanvas.addSubview(button, positioned: .above, relativeTo: nil)
        tabCanvas.scrollToVisible(button.frame)
        let slot = min(max(Int(button.frame.midX / width), 0), buttons.count - 1)
        if let from = buttons.firstIndex(where: { $0 === button }), from != slot {
            buttons.insert(buttons.remove(at: from), at: slot)
            host?.moveTab(from: from, to: slot)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                self.layoutSubtreeIfNeeded()
                self.needsLayout = true
            }
        }
    }

    func endDrag() {
        dragged = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            // What a double-click on the title bar does, as set in System Settings.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// One tab: icon, name, and a × to close it (on the selected tab, and on the one under the pointer).
final class TabButton: NSView {
    weak var strip: TabStrip?
    weak var tab: ExplorerTab?
    var title = "" { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var overClose = false { didSet { needsDisplay = true } }

    private var closeRect: NSRect {
        NSRect(x: compact ? (bounds.width - 18) / 2 : bounds.maxX - 28,
               y: (bounds.height - 18) / 2, width: 18, height: 18)
    }
    private var compact: Bool { bounds.width < 76 }
    // An icon must remain clickable to select a compact tab. Close it with
    // the context menu, middle click or ⌘W when there is no room for a separate ×.
    private var showsClose: Bool { !compact && (isSelected || hovering) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = bounds.insetBy(dx: 1, dy: 0)
        // Rounded at the top only: the bottom runs into the view below.
        let path = NSBezierPath(roundedRect: NSRect(x: shape.minX, y: shape.minY - 8, width: shape.width, height: shape.height + 8),
                                xRadius: 8, yRadius: 8)
        if isSelected {
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: shape.minX + 0.5, y: 0, width: shape.width - 1, height: 1.5).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.maxX - 1, y: 8, width: 1, height: bounds.height - 16).fill()
        }
        if compact {
            let rect = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            if showsClose, let cross = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab") {
                tinted(cross, .secondaryLabelColor).draw(in: rect)
            } else {
                icon?.draw(in: rect)
            }
            return
        }
        var x: CGFloat = 12
        if let icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let right = (showsClose ? closeRect.minX : bounds.maxX) - 6
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - height) / 2, width: max(right - x, 0), height: height),
                                 withAttributes: attributes)
        if showsClose, let cross = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            if overClose {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: closeRect, xRadius: 4, yRadius: 4).fill()
            }
            let size = cross.size
            tinted(cross, .secondaryLabelColor).draw(in: NSRect(x: closeRect.midX - size.width / 2, y: closeRect.midY - size.height / 2,
                                                              width: size.width, height: size.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        overClose = false
    }

    override func mouseMoved(with event: NSEvent) {
        overClose = showsClose && closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let strip, let tab, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if showsClose && closeRect.contains(point) {
            // A button: letting go outside the × cancels.
            var inside = true
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                inside = closeRect.contains(convert(next.locationInWindow, from: nil))
                overClose = inside
                if next.type == .leftMouseUp { break }
            }
            if inside { strip.host?.close(tab) }
            return
        }
        strip.host?.select(tab)
        let origin = frame.origin.x
        let start = event.locationInWindow.x
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let dx = next.locationInWindow.x - start
            if !dragging && abs(dx) < 4 { continue }
            dragging = true
            strip.drag(self, to: origin + dx)
        }
        if dragging { strip.endDrag() }
    }

    /// Middle-click closes, as in Windows and every browser.
    override func otherMouseDown(with event: NSEvent) {
        if let tab { strip?.host?.close(tab) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("New Tab", #selector(newTab(_:))), ("Duplicate Tab", #selector(duplicate(_:))),
                                ("Move to New Window", #selector(moveToNewWindow(_:))), ("", nil),
                                ("Close Tab", #selector(closeTab(_:))), ("Close Other Tabs", #selector(closeOthers(_:))),
                                ("Close Tabs to the Right", #selector(closeToTheRight(_:)))] as [(String, Selector?)] {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func newTab(_ sender: Any?) { strip?.host?.newTab(sender) }
    @objc private func duplicate(_ sender: Any?) { if let tab { strip?.host?.duplicate(tab) } }
    @objc private func moveToNewWindow(_ sender: Any?) { if let tab { strip?.host?.moveToNewWindow(tab) } }
    @objc private func closeTab(_ sender: Any?) { if let tab { strip?.host?.close(tab) } }
    @objc private func closeOthers(_ sender: Any?) { if let tab { strip?.host?.closeOthers(tab) } }
    @objc private func closeToTheRight(_ sender: Any?) { if let tab { strip?.host?.closeToTheRight(of: tab) } }
}
