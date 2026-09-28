import AppKit
import Network

/// Quick access: the folders and files you pin, in your order, kept in the app's defaults.
enum Pins {
    static var urls: [URL] {
        get {
            if let paths = UserDefaults.standard.stringArray(forKey: "pinned") {
                return paths.map { URL(fileURLWithPath: $0) }
            }
            return defaults
        }
        set {
            UserDefaults.standard.set(newValue.map(\.path), forKey: "pinned")
            NotificationCenter.default.post(name: .explorerPinsChanged, object: nil)
        }
    }

    private static var defaults: [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var urls = ["Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        urls.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    static func isPinned(_ url: URL) -> Bool { urls.contains { $0.key == url.key } }

    /// Adds the ones not pinned yet, at `index` or at the end.
    static func pin(_ added: [URL], at index: Int? = nil) {
        var list = urls
        let new = added.filter { url in !list.contains { $0.key == url.key } }
        guard !new.isEmpty else { return }
        list.insert(contentsOf: new, at: min(max(index ?? list.count, 0), list.count))
        urls = list
    }

    static func unpin(_ removed: [URL]) {
        let keys = Set(removed.map(\.key))
        urls = urls.filter { !keys.contains($0.key) }
    }

    /// Drag to reorder: `url` goes to `index` (counted before it was taken out).
    static func move(_ url: URL, to index: Int) {
        var list = urls
        guard let from = list.firstIndex(where: { $0.key == url.key }) else { return }
        let item = list.remove(at: from)
        list.insert(item, at: min(from < index ? index - 1 : index, list.count))
        urls = list
    }
}

/// Places that are not on a pinned list: iCloud Drive, the drives cloud
/// apps add (SeaDrive, OneDrive, Google Drive, Dropbox…), the Trash, AirDrop.
enum Places {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let trash = home.appendingPathComponent(".Trash", isDirectory: true)
    static let airDrop = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")

    static var iCloudDrive: URL? {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// File Provider drives live in ~/Library/CloudStorage as "Provider-account";
    /// Finder shows just the provider, as does this (the account is in the tooltip).
    static let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)

    static var cloudDrives: [(title: String, url: URL, detail: String)] {
        let root = cloudStorage
        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let named = folders.map { url -> (String, URL, String) in
            let full = url.lastPathComponent
            let provider = String(full.split(separator: "-", maxSplits: 1).first ?? Substring(full))
            let title = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Box": "Box"][provider] ?? provider
            return (title, url, full)
        }
        // Two accounts of one provider: tell them apart.
        return named.map { entry in
            let twins = named.filter { $0.0 == entry.0 }.count > 1
            let account = entry.2.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return (twins && !account.isEmpty ? "\(entry.0) (\(account))" : entry.0, entry.1, entry.2)
        }
    }
}

/// File servers announced on the network (SMB and AFP over Bonjour), for
/// the Network entry. Browsing starts only when Network is opened, so the
/// Local Network permission is asked for then, not at launch.
final class NetworkNeighbourhood {
    struct Server: Equatable {
        let name: String
        let url: URL
    }

    private(set) var servers: [Server] = []
    var onChange: (() -> Void)?
    private var browsers: [NWBrowser] = []
    private var found: [String: [Server]] = [:]

    var isBrowsing: Bool { !browsers.isEmpty }

    func start() {
        guard browsers.isEmpty else { return }
        for (type, scheme) in [("_smb._tcp", "smb"), ("_afpovertcp._tcp", "afp")] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let servers = results.compactMap { result -> Server? in
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else { return nil }
                    let host = "\(encoded).\(type).\(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
                    return URL(string: "\(scheme)://\(host)").map { Server(name: name, url: $0) }
                }
                self?.found[scheme] = servers
                self?.merge()
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    /// One entry per server, SMB preferred when it offers both.
    private func merge() {
        var byName: [String: Server] = [:]
        for server in (found["afp"] ?? []) + (found["smb"] ?? []) { byName[server.name] = server }
        let merged = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard merged != servers else { return }
        servers = merged
        onChange?()
    }

    deinit { browsers.forEach { $0.cancel() } }
}

final class SidebarNode {
    enum Section { case quickAccess, locations }
    enum Kind: Equatable { case section(Section), pinned, cloud, home, thisMac, volume, folder, airDrop, network, server, trash }

    let kind: Kind
    let url: URL?
    let title: String
    var detail: String?
    var children: [SidebarNode]?
    private var expandable: Bool?

    init(_ kind: Kind, url: URL? = nil, title: String, detail: String? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
        self.detail = detail
    }

    var isSection: Bool { if case .section = kind { return true } else { return false } }

    /// A pinned file rather than a folder: opens instead of navigating.
    /// Asked on every navigation, so the disk is asked only once.
    lazy var isFile: Bool = kind == .pinned && url.map { !FileOps.isFolder($0) } == true

    var location: Location? {
        switch kind {
        case .thisMac: return .thisMac
        case .section, .airDrop, .network, .server: return nil
        default: return isFile ? nil : url.map { .folder($0) }
        }
    }

    var icon: NSImage? {
        switch kind {
        case .section: return nil
        case .thisMac: return NSImage(named: NSImage.computerName)
        case .network: return NSImage(named: NSImage.networkName)
        case .server: return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        case .airDrop:
            return FileManager.default.fileExists(atPath: Places.airDrop.path)
                ? NSWorkspace.shared.icon(forFile: Places.airDrop.path)
                : NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
        case .trash: return NSImage(named: NSImage.trashEmptyName)
        default: return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    /// Top-level entries always offer to open: looking inside Desktop or
    /// Documents just to draw an arrow would ask for permission at launch.
    var isExpandable: Bool {
        switch kind {
        case .section, .thisMac, .network, .home, .volume, .cloud: return true
        case .pinned: return !isFile
        case .airDrop, .server, .trash: return false
        case .folder:
            if let expandable { return expandable }
            let answer = url.map(Folders.hasSubfolder) ?? false
            expandable = answer
            return answer
        }
    }
}

final class SidebarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SidebarCell")
    let pin = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        pin.contentTintColor = .tertiaryLabelColor
        for v in [image, text, pin] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 4),
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A section title: Quick access, Locations.
final class SidebarHeader: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SidebarHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: Sidebar?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SidebarNode else { return nil }
        return sidebar?.menu(for: node)
    }

    /// Middle-click opens a folder in a new tab, as in Windows.
    override func otherMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? SidebarNode, let location = node.location else {
            return super.otherMouseDown(with: event)
        }
        (NSApp.delegate as? AppDelegate)?.openWindow(location, tabbedWith: window, activate: false)
    }
}

/// The navigation pane, in two sections as Finder has them. Quick access:
/// the pinned folders and files (drag to reorder, drop a folder in to pin
/// it). Locations: iCloud Drive and the other cloud drives, home, This Mac
/// with its drives, AirDrop, the servers on the network, the Trash.
final class Sidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = SidebarOutlineView()
    let scroll = NSScrollView()
    var onNavigate: ((Location) -> Void)?
    var onDrop: (([URL], URL, _ move: Bool) -> Void)?
    var onConnect: ((URL) -> Void)?

    private let quickAccess = SidebarNode(.section(.quickAccess), title: "Quick access")
    private let locations = SidebarNode(.section(.locations), title: "Locations")
    private let thisMac = SidebarNode(.thisMac, title: "This Mac")
    private let network = SidebarNode(.network, title: "Network")
    private let neighbourhood = NetworkNeighbourhood()
    private var current: Location = .thisMac
    private var syncing = false

    private static let pinDrag = NSPasteboard.PasteboardType("com.vladimirperovic.foldera.pin")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.sidebar = self
        outline.registerForDraggedTypes([.fileURL, Self.pinDrag])
        outline.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask([.move, .generic], forLocal: true)

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        neighbourhood.onChange = { [weak self] in
            guard let self else { return }
            self.network.children = nil
            self.outline.reloadItem(self.network, reloadChildren: true)
        }

        outline.reloadData()
        outline.expandItem(quickAccess)
        outline.expandItem(locations)
        outline.expandItem(thisMac)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: .explorerPinsChanged, object: nil)
        // Cloud apps add their drives to ~/Library/CloudStorage without
        // mounting anything; look there when it changes and when Foldera
        // comes to the front (in case the folder itself was only just made).
        cloudWatcher.onChange = { [weak self] in self?.placesChanged() }
        cloudWatcher.watch(FileOps.exists(Places.cloudStorage) ? Places.cloudStorage : nil)
        NotificationCenter.default.addObserver(self, selector: #selector(placesChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func sectionChildren(_ section: SidebarNode.Section) -> [SidebarNode] {
        let fm = FileManager.default
        switch section {
        case .quickAccess:
            return Pins.urls.filter { fm.fileExists(atPath: $0.path) }.map {
                SidebarNode(.pinned, url: $0, title: fm.displayName(atPath: $0.path), detail: Format.path($0))
            }
        case .locations:
            shownPlaces = Self.placesKey()
            var nodes: [SidebarNode] = []
            if let iCloud = Places.iCloudDrive { nodes.append(SidebarNode(.cloud, url: iCloud, title: "iCloud Drive")) }
            nodes += Places.cloudDrives.map { SidebarNode(.cloud, url: $0.url, title: $0.title, detail: $0.detail) }
            nodes.append(SidebarNode(.home, url: Places.home, title: fm.displayName(atPath: Places.home.path)))
            nodes.append(thisMac)
            nodes.append(SidebarNode(.airDrop, title: "AirDrop"))
            nodes.append(network)
            nodes.append(SidebarNode(.trash, url: Places.trash, title: "Trash"))
            return nodes
        }
    }

    private func children(of node: SidebarNode?) -> [SidebarNode] {
        guard let node else { return [quickAccess, locations] }
        if case .section(let section) = node.kind {
            if node.children == nil { node.children = sectionChildren(section) }
            return node.children ?? []
        }
        if let children = node.children { return children }
        let made: [SidebarNode]
        switch node.kind {
        case .thisMac:
            made = FileItem.volumes().map { SidebarNode(.volume, url: $0.url, title: $0.name) }
        case .network:
            made = neighbourhood.servers.map { SidebarNode(.server, url: $0.url, title: $0.name) }
        case .airDrop, .server, .trash, .section:
            made = []
        default:
            let url = node.url.map { node.kind == .pinned ? $0.resolvingSymlinksInPath() : $0 }
            made = url.map { Folders.subfolders(of: $0).map { SidebarNode(.folder, url: $0, title: $0.lastPathComponent) } } ?? []
        }
        node.children = made
        return made
    }

    @objc private func volumesChanged() {
        thisMac.children = nil
        outline.reloadItem(thisMac, reloadChildren: true)
        placesChanged()
    }

    /// The cloud drives, and iCloud Drive, as the Locations section last showed them.
    private var shownPlaces: [String] = []
    private let cloudWatcher = DirectoryWatcher()

    private static func placesKey() -> [String] {
        [Places.iCloudDrive?.path ?? ""] + Places.cloudDrives.map { $0.url.path + "|" + $0.title }
    }

    @objc private func placesChanged() {
        if cloudWatcher.isIdle, FileOps.exists(Places.cloudStorage) {
            cloudWatcher.watch(Places.cloudStorage)
        }
        guard locations.children != nil, Self.placesKey() != shownPlaces else { return }
        let wasOpen = outline.isItemExpanded(thisMac)
        locations.children = nil
        outline.reloadItem(locations, reloadChildren: true)
        if wasOpen { outline.expandItem(thisMac) }
        sync(to: current)
    }

    @objc private func pinsChanged() {
        quickAccess.children = nil
        outline.reloadItem(quickAccess, reloadChildren: true)
        sync(to: current)
    }

    /// Highlights the entry for `location` when there is one, without navigating.
    func sync(to location: Location) {
        current = location
        syncing = true
        defer { syncing = false }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, !node.isSection, node.location == location {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? SidebarNode).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? SidebarNode)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isSection {
            let header = outlineView.makeView(withIdentifier: SidebarHeader.id, owner: self) as? SidebarHeader ?? SidebarHeader()
            header.label.stringValue = node.title
            return header
        }
        let cell = outlineView.makeView(withIdentifier: SidebarCell.id, owner: self) as? SidebarCell ?? SidebarCell()
        cell.textField?.stringValue = node.title
        cell.imageView?.image = node.icon
        cell.pin.isHidden = node.kind != .pinned
        cell.toolTip = node.detail
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.isSection == true ? 30 : 26
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection == false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        if (notification.userInfo?["NSObject"] as? SidebarNode)?.kind == .network { neighbourhood.start() }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        switch node.kind {
        case .airDrop:
            NSWorkspace.shared.open(Places.airDrop)
            sync(to: current)
        case .network:
            neighbourhood.start()
            outline.expandItem(node)
            sync(to: current)
        case .server:
            if let url = node.url { onConnect?(url) }
            sync(to: current)
        default:
            if node.isFile, let url = node.url {
                NSWorkspace.shared.open(url)
                sync(to: current)
            } else if let location = node.location {
                onNavigate?(location)
            }
        }
    }

    // MARK: Dragging: pin, reorder, move files, throw away

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, let url = node.url,
              [.pinned, .folder, .home, .cloud].contains(node.kind) else { return nil }
        let entry = NSPasteboardItem()
        entry.setString(url.absoluteString, forType: .fileURL)
        if node.kind == .pinned { entry.setString(url.path, forType: Self.pinDrag) }
        return entry
    }

    private func pinIndex(_ item: Any?, _ index: Int) -> Int? {
        guard (item as? SidebarNode) === quickAccess, index != NSOutlineViewDropOnItemIndex else { return nil }
        // Rows above the drop point that are pinned entries, so the index matches Pins.urls.
        let shown = children(of: quickAccess)
        guard index < shown.count, let url = shown[index].url else { return Pins.urls.count }
        return Pins.urls.firstIndex { $0.key == url.key } ?? Pins.urls.count
    }

    private func dropFolder(_ item: Any?, _ index: Int) -> URL? {
        guard index == NSOutlineViewDropOnItemIndex, let node = item as? SidebarNode, !node.isFile,
              ![.thisMac, .network, .server, .airDrop, .trash].contains(node.kind), !node.isSection else { return nil }
        return node.url
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if pinIndex(item, index) != nil {
            return info.draggingPasteboard.string(forType: Self.pinDrag) != nil ? .move : .link
        }
        if index == NSOutlineViewDropOnItemIndex, (item as? SidebarNode)?.kind == .trash {
            let urls = DragOps.urls(from: info)
            return urls.isEmpty || urls.contains(where: ArchiveFolders.isInside) ? [] : .delete
        }
        guard info.draggingPasteboard.string(forType: Self.pinDrag) == nil, let folder = dropFolder(item, index) else { return [] }
        return DragOps.operation(for: info, into: folder)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let at = pinIndex(item, index) {
            if let path = info.draggingPasteboard.string(forType: Self.pinDrag) {
                Pins.move(URL(fileURLWithPath: path), to: at)
            } else {
                Pins.pin(DragOps.urls(from: info), at: at)
            }
            return true
        }
        if index == NSOutlineViewDropOnItemIndex, (item as? SidebarNode)?.kind == .trash {
            FileOps.trash(DragOps.urls(from: info)) {}
            return true
        }
        guard let folder = dropFolder(item, index) else { return false }
        let operation = DragOps.operation(for: info, into: folder)
        guard !operation.isEmpty else { return false }
        onDrop?(DragOps.urls(from: info), folder, operation == .move)
        return true
    }

    // MARK: Right-click

    func menu(for node: SidebarNode) -> NSMenu? {
        guard !node.isSection else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String?, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if node.kind == .trash {
            add("Open", "trash", #selector(openNode(_:)))
            add("Empty Trash…", "trash.slash", #selector(emptyTrash(_:)))
            return menu
        }
        if node.location != nil {
            add("Open in New Tab", "plus.square.on.square", #selector(openInTab(_:)))
            add("Open in New Window", "macwindow.badge.plus", #selector(openInWindow(_:)))
        } else if node.isFile {
            add("Open", "arrow.up.forward.app", #selector(openNode(_:)))
        }
        guard let url = node.url, node.kind != .server else { return menu.items.isEmpty ? nil : menu }
        menu.addItem(.separator())
        if node.kind == .pinned {
            add("Remove from Quick access", "pin.slash", #selector(unpin(_:)))
        } else if !Pins.isPinned(url) {
            add("Add to Quick access", "pin", #selector(pin(_:)))
        }
        if node.kind == .volume, url.key != "/" {
            add("Eject", "eject", #selector(eject(_:)))
        }
        menu.addItem(.separator())
        add("Copy as Path", "link", #selector(copyPath(_:)))
        if !node.isFile { add("Open in Terminal", "terminal", #selector(openTerminal(_:))) }
        add("Show in Finder", "folder", #selector(showInFinder(_:)))
        menu.addItem(.separator())
        add("Properties", "info.circle", #selector(properties(_:)))
        return menu
    }

    private func node(_ sender: Any?) -> SidebarNode? { (sender as? NSMenuItem)?.representedObject as? SidebarNode }

    @objc private func openNode(_ sender: Any?) {
        guard let node = node(sender), let url = node.url else { return }
        if let location = node.location { onNavigate?(location) } else { NSWorkspace.shared.open(url) }
    }

    @objc private func openInTab(_ sender: Any?) {
        guard let location = node(sender)?.location else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(location, tabbedWith: outline.window)
    }

    @objc private func openInWindow(_ sender: Any?) {
        guard let location = node(sender)?.location else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(location)
    }

    @objc private func pin(_ sender: Any?) { if let url = node(sender)?.url { Pins.pin([url]) } }
    @objc private func unpin(_ sender: Any?) { if let url = node(sender)?.url { Pins.unpin([url]) } }
    @objc private func copyPath(_ sender: Any?) { if let url = node(sender)?.url { FileOps.copyPaths([url]) } }
    @objc private func openTerminal(_ sender: Any?) { if let url = node(sender)?.url { FileOps.openTerminal(at: url) } }
    @objc private func showInFinder(_ sender: Any?) { if let url = node(sender)?.url { FileOps.showInFinder([url]) } }
    @objc private func properties(_ sender: Any?) { if let url = node(sender)?.url { PropertiesWindow.show([url]) } }

    /// Empties ~/.Trash for good, after asking. Reading the Trash needs Full Disk Access.
    @objc private func emptyTrash(_ sender: Any?) {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: Places.trash, includingPropertiesForKeys: nil)
        } catch {
            FileOps.report(["Foldera can't look into the Trash. Give it Full Disk Access in System Settings › Privacy & Security, or empty the Trash from Finder."])
            return
        }
        guard !contents.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently erase the \(Format.items(contents.count)) in the Trash?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            for url in contents {
                do { try fm.removeItem(at: url) } catch { failures.append(error.localizedDescription) }
            }
            DispatchQueue.main.async { FileOps.report(failures) }
        }
    }

    @objc private func eject(_ sender: Any?) {
        guard let url = node(sender)?.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }
}
