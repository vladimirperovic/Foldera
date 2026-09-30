import AppKit

/// Successful visits, shared by windows and kept between launches.
enum RecentFolders {
    static let key = "recentFolders"
    static let limit = 50

    static func urls(in defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func remember(_ url: URL, in defaults: UserDefaults = .standard) {
        guard !ArchiveFolders.isInside(url) else { return }
        let paths = [url.key] + urls(in: defaults).filter { $0.key != url.key }.map(\.key)
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }
}

struct QuickOpenItem {
    enum Kind { case folder, tab, command }
    enum Destination {
        case folder(URL)
        case tab(ExplorerTab)
        case command(NSMenuItem, NSObject)
    }
    let title: String
    let detail: String
    var keywords = ""
    let kind: Kind
    let destination: Destination
    var enabled = true

    var id: String {
        switch destination {
        case .folder(let url): return "folder:" + url.key
        case .tab(let tab): return "tab:\(ObjectIdentifier(tab))"
        case .command(let item, _): return "command:\(item.action.map(NSStringFromSelector) ?? ""):\(item.title):\(item.tag)"
        }
    }

    var symbol: String {
        switch kind {
        case .folder: return "folder"
        case .tab: return "rectangle.on.rectangle"
        case .command: return "command"
        }
    }

    /// Each word must match. Prefer the name over matches buried in a path.
    func score(for query: String) -> Int? {
        let words = Self.fold(query).split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return 0 }
        let name = Self.fold(title)
        let all = Self.fold(title + " " + detail + " " + keywords)
        guard words.allSatisfy({ all.contains($0) }) else { return nil }
        let phrase = words.joined(separator: " ")
        if name == phrase { return 0 }
        if name.hasPrefix(phrase) { return 1 }
        if words.allSatisfy({ name.contains($0) }) { return 2 }
        return 3
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Called off the main thread: a disconnected pinned drive must not freeze typing.
    static func folders(pinned: [URL], recent: [URL]) -> [QuickOpenItem] {
        var seen = Set<String>()
        var result: [QuickOpenItem] = []
        for (urls, source) in [(pinned, "Quick access"), (recent, "Recent folder")] {
            for url in urls where seen.insert(url.key).inserted && !ArchiveFolders.isInside(url) {
                let file = FileItem(url: url)
                guard file.isFolder else { continue }
                result.append(QuickOpenItem(title: file.name, detail: source + " · " + Format.path(url),
                                           kind: .folder, destination: .folder(url)))
            }
        }
        return result
    }

    /// Reuse the real menu actions and their senders, including sort tags and formats.
    static func commands(in menu: NSMenu, for tab: ExplorerTab) -> [QuickOpenItem] {
        var result: [QuickOpenItem] = []
        func visit(_ menu: NSMenu, path: String) {
            for original in menu.items where !original.isHidden && !original.isSeparatorItem {
                if let submenu = original.submenu {
                    visit(submenu, path: path.isEmpty ? original.title : path + " › " + original.title)
                    continue
                }
                guard let action = original.action,
                      action != #selector(ExplorerTab.quickOpen(_:)), action != #selector(ExplorerTab.findCommand(_:)) else { continue }
                let targets: [NSObject?] = [tab, tab.host, tab.window, tab.appDelegate]
                guard let target = targets.compactMap({ $0 }).first(where: { $0.responds(to: action) }),
                      let item = original.copy() as? NSMenuItem else { continue }
                let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
                let detail = "Command · " + path + (enabled ? "" : " · Unavailable here")
                result.append(QuickOpenItem(title: item.title, detail: detail,
                                           keywords: aliases[NSStringFromSelector(action)] ?? "",
                                           kind: .command, destination: .command(item, target), enabled: enabled))
            }
        }
        // System-wide application controls do not belong among file commands.
        for item in menu.items where ["File", "Edit", "View", "Go", "Window"].contains(item.title) {
            if let submenu = item.submenu { visit(submenu, path: item.title) }
        }
        // These file commands live in the context menu rather than the main menu.
        for (title, action) in [("Open in Terminal", #selector(ExplorerTab.openInTerminal(_:))),
                                ("Quick Access", #selector(ExplorerTab.togglePin(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            let enabled = tab.validateMenuItem(item)
            result.append(QuickOpenItem(title: item.title, detail: "Command · Folder" + (enabled ? "" : " · Unavailable here"),
                                       keywords: aliases[NSStringFromSelector(action)] ?? "", kind: .command,
                                       destination: .command(item, tab), enabled: enabled))
        }
        return result
    }

    private static let aliases = [
        "compress:": "zip arhiva arhiviraj zapakuj kompresuj",
        "extract:": "unzip raspakuj arhiva", "extractTo:": "unzip raspakuj arhiva",
        "syncFolders:": "sync sinhronizacija sinkronizacija uskladi uporedi foldere",
        "toggleHidden:": "skriveni skrivene prikazi sakrij fajlovi datoteke",
        "copyTextFromImage:": "ocr tekst slika screenshot prepoznaj kopiraj",
        "openInTerminal:": "terminal shell konzola", "togglePin:": "omiljeni favoriti zakaci otkaci",
        "newFolder:": "novi folder direktorijum", "newTextDocument:": "novi tekst dokument",
        "renameSelection:": "preimenuj naziv ime", "copyPath:": "kopiraj putanju adresu",
        "setUsageView:": "prostor zauzece disk velicina", "toggleFolderSizes:": "velicina foldera",
        "togglePreviewPane:": "pregled detalji preview", "showProperties:": "svojstva osobine detalji",
        "setDetailsView:": "lista detalji", "setIconsView:": "ikone slike", "setColumnsView:": "kolone",
        "refresh:": "osvezi osvjezi", "focusSearch:": "pretraga pronadji trazi",
    ]
}

final class QuickOpenController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Scope: Int { case all, places, commands }
    private weak var source: ExplorerTab?
    private let searchField = NSSearchField()
    private let scopeControl = NSSegmentedControl(labels: ["All", "Folders & Tabs", "Commands"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = QuickOpenTable()
    private let footer = NSTextField(labelWithString: "")
    private var items: [QuickOpenItem] = []
    private var matches: [QuickOpenItem] = []
    private var chosen: QuickOpenItem?
    private var loadingFolders = true

    init(tab: ExplorerTab, scope: Scope) {
        source = tab
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Quick Open"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build()
        scopeControl.selectedSegment = scope.rawValue
        let hosts = ([tab.host].compactMap { $0 } + NSApp.windows.compactMap { $0.windowController as? ExplorerWindow })
        var seen = Set<ObjectIdentifier>()
        for host in hosts where seen.insert(ObjectIdentifier(host)).inserted {
            for openTab in host.tabs {
                items.append(QuickOpenItem(title: openTab.tabTitle,
                                          detail: "Open tab · " + (openTab.location.url.map(Format.path) ?? "This Mac"),
                                          kind: .tab, destination: .tab(openTab)))
            }
        }
        if let menu = NSApp.mainMenu { items += QuickOpenItem.commands(in: menu, for: tab) }
        filter()
        let pinned = Pins.urls
        let recent = RecentFolders.urls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders = QuickOpenItem.folders(pinned: pinned, recent: recent)
            DispatchQueue.main.async {
                guard let self else { return }
                let selection = self.matches.indices.contains(self.table.selectedRow) ? self.matches[self.table.selectedRow].id : nil
                self.items = self.items.filter { $0.kind == .tab } + folders + self.items.filter { $0.kind == .command }
                self.loadingFolders = false
                self.filter(preserving: selection)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setQuery(_ query: String) {
        searchField.stringValue = query
        filter()
    }

    func present(in parent: NSWindow, completion: @escaping () -> Void) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in
            window.orderOut(nil)
            let selected = self?.chosen
            let tab = self?.source
            completion()
            guard let tab else { return }
            tab.focusList()
            if let selected { Self.activate(selected, from: tab) }
        }
        window.makeFirstResponder(searchField)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        searchField.placeholderString = "Search folders, tabs, or commands…"
        searchField.font = .systemFont(ofSize: 16)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search folders, tabs, or commands")
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("result")))
        table.headerView = nil
        table.rowHeight = 48
        table.intercellSpacing = .zero
        table.style = .fullWidth
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsTypeSelect = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(accept(_:))
        table.onAccept = { [weak self] in self?.accept(nil) }
        table.onCancel = { [weak self] in self?.dismiss() }
        table.setAccessibilityLabel("Quick Open results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        for view in [searchField, scopeControl, scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 30),
            scopeControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scopeControl.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func controlTextDidChange(_ obj: Notification) { filter() }
    @objc private func scopeChanged(_ sender: Any?) { filter(); window?.makeFirstResponder(searchField) }

    private func filter(preserving selection: String? = nil) {
        let scope = Scope(rawValue: scopeControl.selectedSegment) ?? .all
        matches = items.enumerated().compactMap { index, item -> (Int, Int, QuickOpenItem)? in
            if scope == .places && item.kind == .command || scope == .commands && item.kind != .command { return nil }
            guard let score = item.score(for: searchField.stringValue) else { return nil }
            return (score, index, item)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
        table.reloadData()
        if !matches.isEmpty {
            let row = selection.flatMap { id in matches.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        footer.stringValue = matches.isEmpty
            ? (loadingFolders && scope != .commands ? "Loading folders…" : "No matching results")
            : "↑ ↓ Choose    Return Open / Run    Esc Close" + (loadingFolders && scope != .commands ? "    Loading folders…" : "")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): accept(nil)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = (max(table.selectedRow, 0) + delta + matches.count) % matches.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func accept(_ sender: Any?) {
        guard matches.indices.contains(table.selectedRow), matches[table.selectedRow].enabled else { NSSound.beep(); return }
        chosen = matches[table.selectedRow]
        dismiss()
    }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    static func activate(_ item: QuickOpenItem, from source: ExplorerTab) {
        switch item.destination {
        case .folder(let url):
            source.navigate(to: .folder(url))
            source.focusList()
        case .tab(let tab):
            guard let host = tab.host, host.tabs.contains(where: { $0 === tab }) else { return }
            host.select(tab)
            host.window?.makeKeyAndOrderFront(nil)
            tab.focusList()
        case .command(let menuItem, let target):
            guard let action = menuItem.action,
                  (target as? NSMenuItemValidation)?.validateMenuItem(menuItem) != false else { NSSound.beep(); return }
            NSApp.sendAction(action, to: target, from: menuItem)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("QuickOpenCell")
        let cell = table.makeView(withIdentifier: id, owner: self) as? QuickOpenCell ?? QuickOpenCell()
        cell.identifier = id
        cell.configure(matches[row])
        return cell
    }
}

private final class QuickOpenTable: NSTableView {
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onAccept?() }
        else if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

private final class QuickOpenCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        for view in [icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        textField = title
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func configure(_ item: QuickOpenItem) {
        title.stringValue = item.title
        detail.stringValue = item.detail
        title.textColor = item.enabled ? .labelColor : .disabledControlTextColor
        detail.textColor = item.enabled ? .secondaryLabelColor : .disabledControlTextColor
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.contentTintColor = item.enabled ? .controlAccentColor : .disabledControlTextColor
        toolTip = item.title + "\n" + item.detail
    }
}

extension ExplorerTab {
    @objc func quickOpen(_ sender: Any?) { host?.showQuickOpen(scope: .all) }
    @objc func findCommand(_ sender: Any?) { host?.showQuickOpen(scope: .commands) }
}
