import AppKit
import Quartz

/// One Foldera tab: the address row, the command bar, the navigation
/// pane, the file list and the status bar, top to bottom, as in Windows 11.
/// ExplorerWindow holds the tabs and their strip.
final class ExplorerTab: NSViewController, NSSplitViewDelegate {
    enum ViewMode: String { case details, icons, columns, usage }

    weak var host: ExplorerWindow?
    /// The window this tab is shown in, while it is the selected one.
    var window: NSWindow? { view.window }

    // Where the window is and has been.
    var location: Location
    var backStack: [Location] = []
    var forwardStack: [Location] = []

    // What the list shows.
    var items: [FileItem] = [] { didSet { itemsRevision &+= 1 } }
    private(set) var itemsRevision = 0
    var loadError: Error?
    var sort = SortSpec.saved
    var viewMode: ViewMode
    var searchQuery = ""
    var filters = SearchFilters()
    var showsFilterBar = false
    /// Every file in the folder and the folders inside it, in one list, as
    /// Total Commander's branch view (Ctrl+B) shows them. Made by the search.
    var flatView = false
    /// Showing search results: a query was typed, a search option is set, or the flat view is on.
    var isSearching: Bool { !searchQuery.isEmpty || filters.isActive || flatView }
    var searchRunning = false
    var searchTruncated = false
    /// Folders the search couldn't look into.
    var searchUnreadable = 0
    var busyText: String?

    // Bookkeeping between a request and the list catching up with it.
    let search = FolderSearch()
    let watcher = DirectoryWatcher()
    private static let folderReads = BackgroundTask.queue("Foldera.folder-listings", limit: 2)
    private let folderLoading = BackgroundTask(queue: ExplorerTab.folderReads)
    var loadGeneration = 0
    /// The folder read under way, whether the folder changed meanwhile, and
    /// the pause before reading it again: a folder that keeps changing (a
    /// download, a script writing thousands of files) is read one time after
    /// another with rests between, not again every few tenths of a second
    /// with each read on a slow disk queued behind the last.
    private var folderRead: (generation: Int, started: Date)?
    private var changedDuringRead = false
    private var changeReload: DispatchWorkItem?
    /// A folder opened but not read yet. After a moment the one left behind
    /// goes from the screen, so a slow disk doesn't show it under the new
    /// address; a fast one reads the folder first and nothing blinks.
    private var opening: DispatchWorkItem?
    private(set) var waitingForFolder = false
    /// Reads a folder for the list, handing over what it has so far as it
    /// goes; tests stand a slow disk in for it.
    static var readFolderInSteps: (URL, Bool, CancelFlag, @escaping ([FileItem]) -> Void) throws -> [FileItem] = { url, hidden, cancelled, step in
        try FileItem.contents(of: url, showHidden: hidden, cancelled: cancelled, step: step)
    }
    /// The same without the steps, as most tests stand it in.
    static var readFolder: (URL, Bool) throws -> [FileItem] {
        get {
            let steps = readFolderInSteps
            return { url, hidden in try steps(url, hidden, CancelFlag(), { _ in }) }
        }
        set { readFolderInSteps = { url, hidden, _, _ in try newValue(url, hidden) } }
    }
    /// The read whose items so far are on screen, a folder still being read.
    private var shownSoFar = 0
    /// Items taken off the list as they went to the Trash. A read begun
    /// before, or a slow disk's stale answer, that still has one leaves it
    /// out when it is no longer on the disk (one put back is shown again).
    private var justRemoved: [String: Int] = [:]
    private var removalGeneration = 0
    private var navigationGeneration = 0
    private var pendingRecentVisit = false
    var sortGeneration = 0
    /// A column was clicked while this search runs: later results go in order too.
    var searchSorted = false
    var pendingSelection: Set<String>?
    var scrollToTop = false
    var scrollToSelection = false
    var renameAfterLoad: String?
    var renamingKey: String?
    var cancelRename = false
    var reloadDeferred = false
    var keyMonitor: Any?
    var typeSelection = TypeSelection()
    /// The item a Shift+click extends from, as Windows Explorer keeps it:
    /// the item the last click without modifiers landed on.
    private(set) var selectionAnchor: String?
    /// Picture pixel sizes for the status bar, read in the background once
    /// per version of a file; nil where the file held no size to read.
    private var pictureSizes: [String: (stamp: String, text: String?)] = [:]
    private var pictureSizeReads: Set<String> = []
    private static let pictureSizeQueue = BackgroundTask.queue("Foldera.picture-sizes")
    var observers: [NSObjectProtocol] = []
    /// Thumbnails asked for ahead of the scroll, by picture and size.
    private(set) var thumbnailsAhead: [String: Thumbnails.Ticket] = [:]
    private lazy var thumbnailScroll = CoalescedTask(delay: 0.05) { [weak self] in self?.makeThumbnailsAhead() }
    /// Lists that missed a reload while hidden; they catch up when shown.
    var staleViews: Set<ViewMode> = []
    var cloudRefresh: DispatchWorkItem?
    let textUndo = UndoManager()
    /// The search waiting for the typing to pause.
    private var searchDelay: DispatchWorkItem?
    /// Rows whose Finder tags are to be read in the background, and whether that is on its way.
    private var tagRows = IndexSet()
    private var tagReadQueued = false
    private static let tagQueue = DispatchQueue(label: "Foldera.tags", qos: .userInitiated)

    // Row 1: where you are.
    let backButton = ToolButton(symbol: "arrow.left", tip: "Back (⌥←)")
    let forwardButton = ToolButton(symbol: "arrow.right", tip: "Forward (⌥→)")
    let upButton = ToolButton(symbol: "arrow.up", tip: "Up to the parent folder (⌥↑)")
    let refreshButton = ToolButton(symbol: "arrow.clockwise", tip: "Refresh (F5)")
    let addressBar = AddressBar()
    let searchField = NSSearchField()
    let filterButton = ToolButton(symbol: "line.3.horizontal.decrease.circle", tip: "Search options: kind, size, date (⌥⌘F)")
    let filterBar = FilterBar()
    lazy var filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)

    // Row 2: what you can do.
    let newButton = ToolButton(symbol: "plus.circle.fill", label: "New", tip: "Create a new folder or document", dropdown: true, tint: .controlAccentColor)
    let cutButton = ToolButton(symbol: "scissors", tip: "Cut (⌘X)")
    let copyButton = ToolButton(symbol: "doc.on.doc", tip: "Copy (⌘C)")
    let pasteButton = ToolButton(symbol: "doc.on.clipboard", tip: "Paste (⌘V)")
    let renameButton = ToolButton(symbol: "character.cursor.ibeam", tip: "Rename (F2)")
    let shareButton = ToolButton(symbol: "square.and.arrow.up", tip: "Share")
    let deleteButton = ToolButton(symbol: "trash", tip: "Move to Trash (Delete)")
    let sortButton = ToolButton(symbol: "arrow.up.arrow.down", label: "Sort", tip: "Sort", dropdown: true)
    let viewButton = ToolButton(symbol: "rectangle.grid.1x2", label: "View", tip: "Layout and hidden items", dropdown: true)
    let detailsButton = ToolButton(symbol: "list.bullet", tip: "Details view (⌘1)")
    let syncButton = ToolButton(label: "Sync folder", tip: "Sync folders…")
    let moreButton = ToolButton(symbol: "ellipsis", tip: "See more")
    let paneButton = ToolButton(symbol: "sidebar.right", label: "Details", tip: "Preview and details pane (⇧⌘P)")
    let extractButton = ToolButton(symbol: "archivebox", label: "Extract all", tip: "Unpack this archive into a folder beside it")
    // The switch between one pane with tabs and two panes side by side.
    let onePaneButton = ToolButton(symbol: "rectangle", tip: "One pane, with tabs (⌥⌘1)", iconSize: 16)
    let twoPanesButton = ToolButton(symbol: "rectangle.split.2x1", tip: "Two panes side by side, as in Total Commander (⌥⌘2)", iconSize: 16)
    private var fileCommandDividers: [NSBox] = []
    /// The second of two panes has its own navigation tree.
    let isSecondPane: Bool
    /// With two panes, a line in the accent colour along the top of the one at work.
    let activeMark = NSBox()

    // The middle and the bottom.
    let sidebar = Sidebar()
    let split = NSSplitView()
    let table = FileTableView()
    let tableScroll = NSScrollView()
    let grid = FileCollectionView()
    let gridScroll = NSScrollView()
    let columns = Columns()
    let previewPane = PreviewPane()
    private(set) var previewWindow: PreviewWindow?
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let privacyButton = NSButton(title: "Open Privacy Settings…", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let detailsToggle = ToolButton(symbol: "list.bullet", tip: "Details (⌘1)", iconSize: 12, height: 22)
    let iconsToggle = ToolButton(symbol: "square.grid.2x2", tip: "Large icons (⌘2)", iconSize: 12, height: 22)
    let columnsToggle = ToolButton(symbol: "rectangle.split.3x1", tip: "Columns (⌘3)", iconSize: 12, height: 22)
    let usageToggle = ToolButton(symbol: "square.split.2x2", tip: "Disk usage (⌘4)", iconSize: 12, height: 22)
    let iconSlider = NSSlider(value: Double(Prefs.iconSize), minValue: Double(ExplorerTab.listNotch), maxValue: Double(IconGeometry.largest), target: nil, action: nil)
    let treemap = TreemapView()

    // Disk usage: the measuring under way, and who is waiting for it.
    var usageScanner: UsageScanner?
    private static let usageReads = BackgroundTask.queue("Foldera.usage-scans", limit: 2)
    private let usageLoading = BackgroundTask(queue: ExplorerTab.usageReads)
    var measuring: Location?
    var waitingForUsage: [(UsageNode) -> Void] = []
    private var iconReload: DispatchWorkItem?
    /// The size the pictures were last asked for at, and whether with names.
    private var iconPictures: (CGFloat, Bool)?
    /// Folder sizes are already waiting for the scan under way.
    var waitingForFolderSizes = false
    /// Selecting from code, which the selection callbacks should let pass.
    private var selectingQuietly = false
    var usageNote: String?
    var usageItem: FileItem?
    var usageHover: UsageNode?

    init(location: Location, select: [URL] = [], secondPane: Bool = false) {
        self.location = location
        isSecondPane = secondPane
        viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .details
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 620))
        buildLayout()
        previewPane.onToggleDetached = { [weak self] in self?.togglePreviewDetachment(nil) }
        wire()
        applyViewMode()
        navigate(to: location, record: false, select: select)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildLayout() {
        let root = view

        let buttons: [(ToolButton, Selector)] = [
            (backButton, #selector(goBack(_:))), (forwardButton, #selector(goForward(_:))),
            (upButton, #selector(goUp(_:))), (refreshButton, #selector(refresh(_:))),
            (newButton, #selector(showNewMenu(_:))), (cutButton, #selector(cut(_:))),
            (copyButton, #selector(copy(_:))), (pasteButton, #selector(paste(_:))),
            (renameButton, #selector(renameSelection(_:))), (shareButton, #selector(share(_:))),
            (deleteButton, #selector(delete(_:))), (sortButton, #selector(showSortMenu(_:))),
            (viewButton, #selector(showViewMenu(_:))), (syncButton, #selector(openSync(_:))), (moreButton, #selector(showMoreMenu(_:))),
            (detailsButton, #selector(setDetailsView(_:))),
            (detailsToggle, #selector(setDetailsView(_:))), (iconsToggle, #selector(setIconsView(_:))),
            (columnsToggle, #selector(setColumnsView(_:))), (paneButton, #selector(togglePreviewPane(_:))),
            (usageToggle, #selector(setUsageView(_:))),
            (extractButton, #selector(extract(_:))), (filterButton, #selector(toggleFilters(_:))),
            (onePaneButton, #selector(setOnePane(_:))), (twoPanesButton, #selector(setTwoPanes(_:))),
        ]
        for (button, action) in buttons {
            button.target = self
            button.action = action
        }

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.controlSize = .large
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 250)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([searchWidth, searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)])

        addressBar.setContentHuggingPriority(.init(1), for: .horizontal)
        addressBar.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let nav = NSStackView(views: [backButton, forwardButton, upButton, refreshButton, addressBar, searchField, filterButton])
        nav.orientation = .horizontal
        nav.distribution = .fill
        nav.alignment = .centerY
        nav.spacing = 2
        nav.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        nav.setCustomSpacing(8, after: refreshButton)
        nav.setCustomSpacing(8, after: addressBar)

        fileCommandDividers = [divider(), divider()]
        let commandViews: [NSView] = [
            newButton, fileCommandDividers[0], cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton,
            fileCommandDividers[1], sortButton, viewButton, detailsButton, divider(), syncButton, moreButton,
        ]
        let command = NSStackView(views: commandViews)
        command.orientation = .horizontal
        command.alignment = .centerY
        command.spacing = 2
        command.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for view in commandViews where view is NSBox {
            command.setCustomSpacing(6, after: view)
            if let index = commandViews.firstIndex(of: view), index > 0 { command.setCustomSpacing(6, after: commandViews[index - 1]) }
        }
        // At the far right, as Windows 11 has it; before it, the one or two panes switch.
        command.addView(extractButton, in: .trailing)
        command.addView(onePaneButton, in: .trailing)
        command.addView(twoPanesButton, in: .trailing)
        let switchEnd = divider()
        command.addView(switchEnd, in: .trailing)
        command.addView(paneButton, in: .trailing)
        command.setCustomSpacing(8, after: extractButton)
        command.setCustomSpacing(6, after: twoPanesButton)
        command.setCustomSpacing(6, after: switchEnd)
        extractButton.isHidden = true
        // The details pane follows the first pane; the second has none.
        paneButton.isHidden = isSecondPane
        switchEnd.isHidden = isSecondPane
        command.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let sideBackground = NSVisualEffectView()
        sideBackground.material = .sidebar
        sideBackground.blendingMode = .behindWindow
        sideBackground.state = .followsWindowActiveState
        pin(sidebar.scroll, in: sideBackground)

        setupTable()
        setupGrid()
        setupColumns()
        let contents = NSView()
        pin(tableScroll, in: contents)
        pin(gridScroll, in: contents)
        pin(columns.browser, in: contents)
        pin(treemap, in: contents)
        treemap.host = self
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        privacyButton.bezelStyle = .push
        privacyButton.target = self
        privacyButton.action = #selector(openPrivacySettings(_:))
        privacyButton.isHidden = true
        for v in [emptyLabel, privacyButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contents.addSubview(v)
        }
        NSLayoutConstraint.activate([
            emptyLabel.topAnchor.constraint(equalTo: contents.topAnchor, constant: 64),
            emptyLabel.centerXAnchor.constraint(equalTo: contents.centerXAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contents.leadingAnchor, constant: 16),
            privacyButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 14),
            privacyButton.centerXAnchor.constraint(equalTo: contents.centerXAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sideBackground)
        split.addArrangedSubview(contents)
        if Prefs.previewPane && !isSecondPane { split.addArrangedSubview(previewPane) }
        paneButton.isOn = Prefs.previewPane

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        iconSlider.controlSize = .small
        iconSlider.target = self
        iconSlider.action = #selector(iconSizeChanged(_:))
        iconSlider.toolTip = "Drag right for pictures, bigger the further you go; all the way left for the list (⌘+ / ⌘−)"
        iconSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let status = NSStackView(views: [iconSlider, statusLabel, spacer, detailsToggle, iconsToggle, columnsToggle, usageToggle])
        status.setCustomSpacing(14, after: iconSlider)
        status.orientation = .horizontal
        status.distribution = .fill
        status.alignment = .centerY
        status.spacing = 2
        status.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)

        let topLine = hairline()
        let bottomLine = hairline()
        filterBar.isHidden = true
        filterBar.onChange = { [weak self] filters in self?.filtersChanged(filters) }
        for v in [nav, command, filterBar, topLine, split, bottomLine, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            nav.heightAnchor.constraint(equalToConstant: 42),
            command.topAnchor.constraint(equalTo: nav.bottomAnchor),
            command.heightAnchor.constraint(equalToConstant: 40),
            filterBar.topAnchor.constraint(equalTo: command.bottomAnchor),
            filterBarHeight,
            topLine.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            split.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            bottomLine.topAnchor.constraint(equalTo: split.bottomAnchor),
            status.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        activeMark.boxType = .custom
        activeMark.borderWidth = 0
        activeMark.fillColor = .controlAccentColor
        activeMark.isHidden = true
        activeMark.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(activeMark)
        NSLayoutConstraint.activate([
            activeMark.topAnchor.constraint(equalTo: root.topAnchor),
            activeMark.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activeMark.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activeMark.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    /// With two panes, the one at work is marked and the other's address
    /// dimmed; nil, with one pane, shows neither.
    func markActive(_ active: Bool?) {
        activeMark.isHidden = active != true
        addressBar.alphaValue = active == false ? 0.55 : 1
    }

    /// The one or two panes switch shows how the window is now.
    func updatePaneSwitch() {
        let two = host?.partner != nil
        onePaneButton.isOn = !two
        twoPanesButton.isOn = two
        // Keep navigation, layout, overflow and the pane switch reachable in
        // each half of the window. File commands stay in menus and shortcuts.
        for button in [cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton] {
            button.isHidden = two
        }
        fileCommandDividers.forEach { $0.isHidden = two }
        paneButton.label = two ? nil : "Details"
    }

    private var sidebarWidthKey: String { isSecondPane ? "secondSidebarWidth" : "sidebarWidth" }

    private var placed = false

    /// The first time the tab is on screen: panes get their widths.
    func didAttach() {
        updatePaneSwitch()
        guard !placed else { return }
        placed = true
        view.layoutSubtreeIfNeeded()
        let sidebarWidth = UserDefaults.standard.double(forKey: sidebarWidthKey)
        split.setPosition(sidebarWidth >= 150 ? sidebarWidth : 220, ofDividerAt: 0)
        if previewPane.superview === split { placePreviewPane() }
    }

    var tabTitle: String { label.title }
    var tabIcon: NSImage { label.icon }
    /// The tab's name and icon, worked out once per place. Every tab's are
    /// asked for whenever any tab goes somewhere, and working them out asks
    /// the disk (a drive's name, the icon, whether it is an opened archive).
    var labelled: (location: Location, title: String, icon: NSImage)?
    private var label: (title: String, icon: NSImage) {
        if let labelled, labelled.location == location { return (labelled.title, labelled.icon) }
        let made = (location: location, title: location.title, icon: location.icon)
        labelled = made
        return (made.title, made.icon)
    }
    var representedURL: URL? { location.url.flatMap(ArchiveFolders.context(of:))?.archive ?? location.url }

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

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 22),
        ])
        return box
    }

    private func hairline() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func setupTable() {
        table.host = self
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        // Typing a name is handled for every layout alike (see handleTypeSelection).
        table.allowsTypeSelect = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        var columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, SortKey?, Bool)] = [
            (.nameColumn, "Name", 320, .name, false),
            (.statusColumn, "Status", 56, nil, false),
            (.locationColumn, "Folder", 260, .location, false),
            (.modifiedColumn, "Date modified", 150, .modified, false),
            (.kindColumn, "Type", 170, .kind, false),
            (.sizeColumn, "Size", 100, .size, true),
            (.freeColumn, "Free space", 190, nil, false),
        ]
        for extra in Self.extraColumns { columns.append((extra.id, extra.title, extra.width, extra.key, false)) }
        for (id, title, width, key, rightAligned) in columns {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = id == .nameColumn ? 140 : 60
            column.resizingMask = .userResizingMask
            if let key { column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true) }
            if rightAligned { column.headerCell.alignment = .right }
            if id == .statusColumn {
                column.minWidth = 44
                column.headerCell.alignment = .center
            }
            table.addTableColumn(column)
        }
        table.autosaveName = "ExplorerColumns"
        table.autosaveTableColumns = true
        // Right-clicking the headers chooses the columns, as in Windows.
        let headerMenu = NSMenu()
        for extra in Self.extraColumns {
            headerMenu.addItem(item(extra.title, nil, #selector(toggleColumn(_:)), object: extra.id.rawValue))
        }
        table.headerView?.menu = headerMenu
        table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .noBorder
    }

    private func setupGrid() {
        let layout = IconLayout()
        layout.side = Prefs.iconSize
        layout.onChange = { [weak self] geometry in self?.iconGeometryChanged(geometry) }
        grid.host = self
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.controlBackgroundColor]
        grid.dataSource = self
        grid.delegate = self
        grid.register(IconItem.self, forItemWithIdentifier: .iconItem)
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)

        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.borderType = .noBorder
        gridScroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: gridScroll.contentView, queue: .main) { [weak self] _ in
            self?.scheduleThumbnailsAhead()
        })
    }

    /// Scroll notifications can arrive several times in a single frame.
    /// Keep one pending pass, using the latest viewport when it runs.
    func scheduleThumbnailsAhead() {
        thumbnailScroll.request()
    }

    /// Thumbnails asked for a screenful above and below what is in sight,
    /// as FastStone reads ahead: scrolling finds them made, rather than tiles
    /// waiting for theirs as they come in. Given up when they fall out of reach.
    func makeThumbnailsAhead() {
        guard shownMode == .icons, !items.isEmpty, let layout = grid.collectionViewLayout as? IconLayout else {
            return cancelThumbnailsAhead()
        }
        let seen = grid.visibleRect
        guard seen.height > 0 else { return }
        let reach = seen.insetBy(dx: 0, dy: -seen.height)
        let side = layout.geometry.thumbnailSide
        let scale = view.window?.backingScaleFactor ?? 2
        // By picture and size: a new size asks again, and drops what was asked at the old one.
        var wanted: [String: FileItem] = [:]
        for attributes in layout.layoutAttributesForElements(in: reach) {
            guard let path = attributes.indexPath, path.item < items.count else { continue }
            let item = items[path.item]
            guard !item.isFolder, item.volume == nil else { continue }
            wanted[Thumbnails.cacheKey(for: item.url, side: side, scale: scale, version: item.modified) as String] = item
        }
        for (key, ticket) in thumbnailsAhead where wanted[key] == nil {
            Thumbnails.shared.cancel(ticket)
            thumbnailsAhead[key] = nil
        }
        for (key, item) in wanted where thumbnailsAhead[key] == nil {
            let ticket = Thumbnails.shared.image(for: item.url, side: side, scale: scale, version: item.modified,
                                                 isCloudOnly: item.cloud == nil ? false : nil) { [weak self] _ in
                self?.thumbnailsAhead[key] = nil
            }
            if let ticket { thumbnailsAhead[key] = ticket }
        }
    }

    private func cancelThumbnailsAhead() {
        thumbnailScroll.cancel()
        thumbnailsAhead.values.forEach(Thumbnails.shared.cancel)
        thumbnailsAhead = [:]
    }

    private func setupColumns() {
        columns.browser.host = self
        columns.onSelect = { [weak self] in self?.listSelectionDidChange() }
        columns.onOpen = { [weak self] in self?.openSelection(nil) }
        columns.onDrop = { [weak self] urls, folder, move in self?.transfer(urls, into: folder, move: move) }
    }

    private func wire() {
        watcher.onChange = { [weak self] in
            guard let self, !self.isSearching else { return }
            if let folder = self.location.url { UsageCache.changed(folder) }
            self.reloadForChange()
        }
        sidebar.onNavigate = { [weak self] location in self?.navigate(to: location) }
        sidebar.onDrop = { [weak self] urls, folder, move in self?.transfer(urls, into: folder, move: move) }
        sidebar.onConnect = { [weak self] server in
            Servers.mount(server) { result in
                switch result {
                case .success(let volume): self?.navigate(to: .folder(volume))
                case .failure(let error): if !(error is CancellationError) { self?.show(error) }
                }
            }
        }
        addressBar.onNavigate = { [weak self] location in
            self?.navigate(to: location)
            self?.focusList()
        }
        addressBar.onSubmit = { [weak self] text in self?.submitAddress(text) }
        addressBar.onCancel = { [weak self] in self?.focusList() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .explorerClipboardChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMarks()
        })
        observers.append(center.addObserver(forName: .explorerShowHiddenChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        })
        observers.append(center.addObserver(forName: .explorerFolderSizesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.folderSizesChanged()
        })
        observers.append(center.addObserver(forName: .explorerPreviewPaneChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyPreviewPane()
        })
        observers.append(center.addObserver(forName: .explorerItemsRemoved, object: nil, queue: .main) { [weak self] note in
            guard let urls = note.userInfo?["urls"] as? [URL] else { return }
            self?.drop(Set(urls.map(\.key)))
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.type != .keyDown {
                self?.typeSelection.reset()
                // With two panes, a click in one makes it the one at work.
                if let self, let window = self.view.window, event.window === window,
                   self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) {
                    self.host?.activate(self)
                }
                return event
            }
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    // MARK: Going places

    /// Where new things go and pasted things land: the folder on screen
    /// (in the column view, the last column), never a list of search results.
    var currentFolder: URL? {
        if isSearching || isInArchive { return nil }
        if shownMode == .columns { return columns.folder ?? location.url }
        return location.url
    }

    /// Inside an opened archive: the archive and the folder standing for it.
    var archiveContext: (archive: URL, root: URL)? { location.url.flatMap(ArchiveFolders.context(of:)) }
    var isInArchive: Bool { location.url.map(ArchiveFolders.isInside) ?? false }

    var parentLocation: Location? {
        guard let url = location.url else { return nil }
        if let archive = archiveContext, archive.root.key == url.key {
            return .folder(archive.archive.deletingLastPathComponent())
        }
        if isVolumeRoot(url) { return .thisMac }
        return .folder(url.deletingLastPathComponent())
    }

    func navigate(to target: Location, record: Bool = true, select: [URL] = []) {
        typeSelection.reset()
        pendingRecentVisit = true
        navigationGeneration += 1
        folderLoading.cancel()
        if renamingKey != nil { focusList() }
        addressBar.endEditing()
        let previous = location
        if record && target != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = target
        justRemoved = [:]
        cloudRefresh?.cancel()
        usageScanner?.cancel()
        usageScanner = nil
        usageLoading.cancel()
        measuring = nil
        waitingForUsage = []
        waitingForFolderSizes = false
        usageNote = nil
        usageItem = nil
        usageHover = nil
        searchDelay?.cancel()
        search.cancel()
        searchQuery = ""
        flatView = false
        filters = SearchFilters()
        filterBar.filters = filters
        applyFilterBar()
        searchRunning = false
        searchField.stringValue = ""
        // Coming back out of a folder selects it, as Windows does.
        var wanted = Set(select.map(\.key))
        if wanted.isEmpty, let from = previous.url { wanted.insert(from.key) }
        pendingSelection = wanted
        scrollToTop = true
        loadError = nil
        host?.tabDidChange(self)
        extractButton.isHidden = !isInArchive
        addressBar.location = target
        searchField.placeholderString = "Search \(target.url == nil ? "Home" : target.title)"
        sidebar.sync(to: target)
        // A folder opens in the layout it was last shown in, as in Windows;
        // one never set keeps the layout on screen. Disk usage stays on.
        if viewMode != .usage, let url = target.url,
           let remembered = Prefs.folderView(for: url).flatMap(ViewMode.init(rawValue:)),
           remembered != viewMode, remembered != .usage {
            viewMode = remembered
            layoutLists()
        }
        opening?.cancel()
        opening = nil
        // Invalidate the old folder immediately, including while open(2)
        // waits for a slow volume. Read once the watch covers new changes.
        loadGeneration += 1
        watcher.watch(target.url) { [weak self] in self?.load() }
        if target != previous || items.isEmpty { clearWhileOpening() }
    }

    private func clearWhileOpening() {
        let generation = navigationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.navigationGeneration, !self.isSearching else { return }
            self.opening = nil
            self.waitingForFolder = true
            self.items = []
            if self.shownMode != .usage {
                self.selectingQuietly = true
                self.reloadVisibleList()
                self.selectingQuietly = false
            }
            self.updateEmptyState()
            self.selectionChanged()
        }
        opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func submitAddress(_ text: String) {
        navigationGeneration += 1
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        focusList()
        guard !typed.isEmpty else { return }
        if Servers.isNetworkAddress(typed) {
            guard let address = Servers.address(typed) else {
                return show(OpError("Foldera couldn't read that server address."))
            }
            let generation = navigationGeneration
            Servers.mount(address) { [weak self] result in
                guard let self, self.navigationGeneration == generation else { return }
                switch result {
                case .success(let folder):
                    self.navigate(to: .folder(folder))
                    self.focusList()
                case .failure(let error):
                    if !(error is CancellationError) { self.show(error) }
                }
            }
            return
        }
        if typed.caseInsensitiveCompare("This Mac") == .orderedSame {
            navigate(to: .thisMac)
            return
        }
        var path = typed
        if typed.hasPrefix("file://"), let url = URL(string: typed) { path = url.path }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (location.url ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(path).path
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileOps.exists(url) else {
            let alert = NSAlert()
            alert.messageText = "Foldera can't find “\(typed)”."
            alert.informativeText = "Check the spelling and try again."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        if FileOps.isFolder(url) {
            navigate(to: .folder(url))
        } else {
            navigate(to: .folder(url.deletingLastPathComponent()), select: [url])
        }
    }

    // MARK: Loading

    /// Reads the folder (or the drive list) in the background and shows it.
    func load() {
        if renamingKey != nil {
            reloadDeferred = true
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        changeReload?.cancel()
        changeReload = nil
        folderRead = nil
        changedDuringRead = false
        switch location {
        case .thisMac:
            // A network drive that stopped answering can hold this up; keep it off the main thread too.
            folderLoading.run({ FileItem.volumes() }) { [weak self] volumes in
                guard let self, generation == self.loadGeneration else { return }
                self.apply(volumes, error: nil)
            }
        case .folder(let url):
            let hidden = Prefs.showHidden
            let order = sort
            // Folder sizes measured before go in here too, so sorting by size is right the first time.
            let sizes = Prefs.folderSizes ? UsageCache.node(for: url).map(Self.folderSizes(in:)) : nil
            let read = Self.readFolderInSteps
            let removed = justRemoved
            let removedKeys = Set(removed.keys)
            folderRead = (generation, Date())
            // Sorting a big folder takes a while; it happens here, off the main thread.
            folderLoading.runCancellable({ [weak self] cancelled in
                Result { () -> [FileItem] in
                    var found = try read(url, hidden, cancelled) { soFar in
                        guard !cancelled.isSet else { return }
                        // Cache tag reads on the reader's instances too, so
                        // later snapshots do not fetch the same tags again.
                        if order.key == .tags {
                            for item in soFar {
                                if cancelled.isSet { return }
                                _ = item.tags
                            }
                        }
                        // The reader retains its objects until the final result.
                        // Publish separate snapshots so its later size writes
                        // cannot race with the table, preview or user sorting.
                        let shown = soFar.map { item in
                            FileItem(snapshot: item, folderSize: item.isFolder && item.volume == nil ? sizes?[item.name] : nil)
                        }.sorted(by: order)
                        if !cancelled.isSet {
                            DispatchQueue.main.async { self?.showSoFar(shown, generation: generation) }
                        }
                    }
                    if cancelled.isSet { throw CancellationError() }
                    if !removed.isEmpty {
                        found.removeAll { Self.isAmong($0, removedKeys) && !FileOps.exists($0.url) }
                    }
                    if let sizes { for item in found where item.isFolder && item.volume == nil { item.folderSize = sizes[item.name] } }
                    return found.sorted(by: order)
                }
            }) { [weak self] result in
                guard let self, generation == self.loadGeneration else { return }
                switch result {
                case .success(let loaded):
                    // A removal after this read began wins over its stale snapshot.
                    // Older tombstones were checked on disk above, so Undo can restore them.
                    let newer = Set(self.justRemoved.compactMap { key, revision in removed[key] != revision ? key : nil })
                    self.apply(loaded.filter { !Self.isAmong($0, newer) }, error: nil, sortedBy: order, sized: sizes != nil)
                case .failure(let error): self.apply([], error: error)
                }
                self.folderReadFinished()
            }
        }
    }

    /// A folder still being read on a slow disk shows what has been read so
    /// far, rather than "Working on it…" till the last item: the first
    /// pictures come while the rest are read. Only once the folder left
    /// behind has gone from the screen; a folder read again keeps its list
    /// till the read is done.
    private func showSoFar(_ soFar: [FileItem], generation: Int) {
        guard generation == loadGeneration, waitingForFolder, renamingKey == nil, !isSearching, !soFar.isEmpty else { return }
        shownSoFar = generation
        let selected = Set(selectedItems.map(\.key))
        let removed = Set(justRemoved.keys)
        items = soFar.filter { !Self.isAmong($0, removed) }
        if shownMode != .usage {
            selectingQuietly = true
            reloadVisibleList()
            select(keys: selected)
            selectingQuietly = false
        }
        updateEmptyState()
        selectionChanged()
    }

    /// Answers the folder watcher. A change seen while the folder is read, or
    /// while it rests after a read, is picked up by the next read.
    func reloadForChange() {
        if changeReload != nil { return }
        if folderRead?.generation == loadGeneration {
            changedDuringRead = true
            return
        }
        scheduleChangeReload(after: 0.3)
    }

    /// When the folder changed while it was read, it is read again after
    /// resting as long as that read took: on a slow disk (exFAT, a network
    /// share) the list stays current without the disk doing nothing else.
    private func folderReadFinished() {
        guard let read = folderRead, read.generation == loadGeneration else { return }
        folderRead = nil
        guard changedDuringRead else { return }
        changedDuringRead = false
        scheduleChangeReload(after: max(0.3, Date().timeIntervalSince(read.started)))
    }

    private func scheduleChangeReload(after delay: TimeInterval) {
        let generation = loadGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changeReload = nil
            guard generation == self.loadGeneration, !self.isSearching else { return }
            self.reload()
        }
        changeReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether `item` is one of those thrown away. Its key may have kept the
    /// "/private" before /var or /tmp, which standardizing drops only while
    /// the file is there; the key it was thrown away under hasn't.
    static func isAmong(_ item: FileItem, _ removed: Set<String>) -> Bool {
        let key = removalKey(item.key)
        return removed.contains(item.key) || removed.contains(key)
            || (hasPrivateAlias(key) && removed.contains("/private" + key))
    }

    private static func hasPrivateAlias(_ path: String) -> Bool {
        ["/var", "/tmp", "/etc"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func removalKey(_ path: String) -> String {
        guard path.hasPrefix("/private/") else { return path }
        let short = String(path.dropFirst("/private".count))
        return hasPrivateAlias(short) ? short : path
    }

    /// Takes items gone from the disk off the list at once, without reading
    /// the folder again: on a slow disk that takes seconds, and the pictures
    /// just thrown away stayed on screen till then. What was selected stays so.
    func drop(_ keys: Set<String>) {
        // Remembered even when a read got there first and the list no longer
        // has them: a stale answer after that would bring them back.
        removalGeneration += 1
        for key in keys { justRemoved[Self.removalKey(key)] = removalGeneration }
        let displayedKeys = Set(items.filter { Self.isAmong($0, keys) }.map(\.key))
        guard !displayedKeys.isEmpty else { return }
        if let editing = renamingKey {
            if !displayedKeys.contains(editing) {
                // Keep the field editor and its row stable. The tombstones
                // above still protect every pending read; refresh on finish.
                reloadDeferred = true
                return
            }
            // The edited file itself went away. End editing as cancellation,
            // never as an implicit request to rename another row.
            cancelRename = true
            window?.makeFirstResponder(nil)
            renamingKey = nil
            cancelRename = false
        }
        // Disk usage takes its own out of the map; the lists catch up when shown.
        guard shownMode != .usage else {
            items.removeAll { displayedKeys.contains($0.key) }
            staleViews.formUnion([.details, .icons, .columns])
            return
        }
        if pendingSelection == nil { pendingSelection = Set(selectedItems.map(\.key)).subtracting(displayedKeys) }
        items.removeAll { displayedKeys.contains($0.key) }
        showItems()
    }

    /// Loads again, keeping what is selected and where the list is scrolled.
    func reload() {
        if isSearching {
            runSearch()
            return
        }
        if pendingSelection == nil { pendingSelection = Set(selectedItems.map(\.key)) }
        load()
    }

    func apply(_ loaded: [FileItem], error: Error?, sortedBy order: SortSpec? = nil, sized: Bool = false) {
        if renamingKey != nil {
            reloadDeferred = true
            return
        }
        if shownSoFar == loadGeneration {
            // Picked while the folder was still being read: kept, and the list stays where it was scrolled to.
            let picked = Set(selectedItems.map(\.key))
            if !picked.isEmpty { pendingSelection = picked }
            if (pendingSelection ?? []).isEmpty { scrollToTop = false }
        }
        loadError = error
        opening?.cancel()
        opening = nil
        waitingForFolder = false
        if pendingRecentVisit, error == nil, !isSearching, let folder = location.url {
            RecentFolders.remember(folder)
            pendingRecentVisit = false
        }
        // Tags on screen stay there while they are read again (see readTags).
        var shown: [String: [String]] = [:]
        for item in items { if let tags = item.knownTags ?? item.previousTags { shown[item.key] = tags } }
        if !shown.isEmpty { for item in loaded where item.knownTags == nil { item.previousTags = shown[item.key] } }
        items = order == sort ? loaded : loaded.sorted(by: sort)
        // A scan that finished while the folder was being read: its sizes go
        // in before the list is drawn, not in a second pass.
        let measured = !sized && Prefs.folderSizes && !isSearching ? location.url.flatMap(UsageCache.node(for:)) : nil
        if let measured {
            assignFolderSizes(measured)
            if sort.key == .size { items = items.sorted(by: sort) }
        }
        showItems()
        watchCloud()
        if !sized && measured == nil { fillFolderSizes() }
    }

    /// While iCloud items are downloading or uploading, look at those items
    /// again every couple of seconds. New and removed files arrive through
    /// the folder watcher, so the folder itself is not read again.
    private func watchCloud() {
        cloudRefresh?.cancel()
        guard !isSearching else { return }
        let syncing = items.indices.filter { items[$0].cloud?.isSyncing == true }.map { ($0, items[$0].key, items[$0].url.path) }
        guard !syncing.isEmpty else { return }
        let generation = loadGeneration
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                // A fresh URL, since a URL keeps the values it has read.
                let fresh = syncing.map { ($0.0, $0.1, FileItem(url: URL(fileURLWithPath: $0.2))) }
                DispatchQueue.main.async {
                    guard let self, generation == self.loadGeneration, !self.isSearching else { return }
                    self.refreshItems(fresh)
                    self.watchCloud()
                }
            }
        }
        cloudRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Puts new readings of some items in their place and redraws just those.
    private func refreshItems(_ fresh: [(Int, String, FileItem)]) {
        var changed = IndexSet()
        for (index, key, item) in fresh where index < items.count && items[index].key == key {
            item.folderSize = items[index].folderSize
            item.previousTags = items[index].knownTags ?? items[index].previousTags
            items[index] = item
            changed.insert(index)
        }
        guard !changed.isEmpty else { return }
        let keys = Set(selectedItems.map(\.key))
        switch shownMode {
        case .details: table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
        case .icons: grid.reloadItems(at: Set(changed.map { IndexPath(item: $0, section: 0) }))
        case .columns, .usage: break
        }
        staleViews = Set([ViewMode.details, .icons, .columns, .usage]).subtracting([shownMode])
        selectQuietly(keys)
        if !keys.isDisjoint(with: fresh.map { $0.1 }) { selectionChanged() }
    }

    /// Puts `items` on screen, then the selection and scroll position that were asked for.
    func showItems() {
        configureColumns()
        let wanted = pendingSelection ?? []
        pendingSelection = nil
        layoutLists()
        selectingQuietly = true
        reloadVisibleList()
        select(keys: wanted)
        selectingQuietly = false
        if scrollToTop || scrollToSelection {
            if let first = firstSelectedIndex {
                scroll(to: first)
            } else if scrollToTop && !items.isEmpty {
                scroll(to: 0)
            }
        }
        scrollToTop = false
        scrollToSelection = false
        if let key = renameAfterLoad {
            renameAfterLoad = nil
            if wanted.contains(key) { DispatchQueue.main.async { self.renameSelection(nil) } }
        }
        updateEmptyState()
        selectionChanged()
        // Once the tiles are laid out.
        DispatchQueue.main.async { [weak self] in self?.makeThumbnailsAhead() }
    }

    /// Only the list on screen is reloaded; the others are marked to catch up when shown.
    func reloadVisibleList() {
        let mode = shownMode
        reload(mode)
        staleViews = Set([ViewMode.details, .icons, .columns, .usage]).subtracting([mode])
    }

    private func reload(_ mode: ViewMode) {
        switch mode {
        case .details: table.reloadData()
        case .icons: grid.reloadData()
        case .columns:
            columns.sort = sort
            if let url = location.url { columns.show(url, items: items) }
        case .usage:
            showUsage()
        }
    }

    func configureColumns() {
        table.tableColumn(withIdentifier: .statusColumn)?.isHidden = !items.contains { $0.cloud != nil }
        let drives = location == .thisMac && !isSearching
        table.tableColumn(withIdentifier: .locationColumn)?.isHidden = !isSearching
        table.tableColumn(withIdentifier: .modifiedColumn)?.isHidden = drives
        table.tableColumn(withIdentifier: .freeColumn)?.isHidden = !drives
        table.tableColumn(withIdentifier: .sizeColumn)?.title = drives ? "Total size" : "Size"
        let shown = Prefs.extraColumns
        for extra in Self.extraColumns {
            table.tableColumn(withIdentifier: extra.id)?.isHidden = drives || !shown.contains(extra.id.rawValue)
        }
    }

    /// Columns Details can show besides the usual ones, as Windows' can: off
    /// until switched on from the headers' right-click menu, or sorted by.
    static let extraColumns: [(id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, key: SortKey)] = [
        (.createdColumn, "Date created", 150, .created),
        (.accessedColumn, "Date accessed", 150, .accessed),
        (.extensionColumn, "File extension", 100, .fileExtension),
        (.tagsColumn, "Tags", 150, .tags),
    ]

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var shown = Prefs.extraColumns
        if shown.remove(id) == nil { shown.insert(id) }
        Prefs.extraColumns = shown
        configureColumns()
    }

    /// Sorting by a column that isn't shown shows it, as Windows does.
    func showColumn(for key: SortKey) {
        guard let extra = Self.extraColumns.first(where: { $0.key == key }), !Prefs.extraColumns.contains(extra.id.rawValue) else { return }
        Prefs.extraColumns.insert(extra.id.rawValue)
        configureColumns()
    }

    /// Finder tags are read off the main thread (a network drive can take its
    /// time), a screenful at a time, and the rows showing them drawn again.
    func readTags(row: Int) {
        tagRows.insert(row)
        guard !tagReadQueued else { return }
        tagReadQueued = true
        // The rest of the rows asked for in this pass come along.
        DispatchQueue.main.async { [weak self] in self?.readQueuedTags() }
    }

    private func readQueuedTags() {
        tagReadQueued = false
        let wanted = tagRows.filter { $0 < items.count }.map { ($0, items[$0]) }
        tagRows = IndexSet()
        guard !wanted.isEmpty else { return }
        Self.tagQueue.async { [weak self] in
            for (_, item) in wanted { _ = item.tags }
            DispatchQueue.main.async {
                guard let self, self.shownMode == .details, !self.staleViews.contains(.details) else { return }
                // Rows still showing the same file, and not one being renamed.
                let rows = IndexSet(wanted.compactMap { row, item -> Int? in
                    guard row < self.items.count, row < self.table.numberOfRows, self.items[row] === item,
                          item.key != self.renamingKey else { return nil }
                    return row
                })
                let columns = IndexSet([NSUserInterfaceItemIdentifier.nameColumn, .tagsColumn].map(self.table.column(withIdentifier:)).filter { $0 >= 0 })
                guard !rows.isEmpty, !columns.isEmpty else { return }
                self.table.reloadData(forRowIndexes: rows, columnIndexes: columns)
            }
        }
    }

    func updateEmptyState() {
        var message: String?
        var permission = false
        if let error = loadError {
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            permission = ns.code == NSFileReadNoPermissionError || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES)
            message = "Foldera can't open “\(location.title)”.\n\(error.localizedDescription)"
            if permission { message! += "\n\nmacOS protects this folder. Give Foldera Full Disk Access to open it." }
        } else if items.isEmpty {
            if isSearching {
                message = searchRunning ? nil : "No items match your search."
            } else if waitingForFolder {
                message = "Working on it…"
            } else if location != .thisMac {
                message = "This folder is empty."
            }
        }
        emptyLabel.stringValue = message ?? ""
        emptyLabel.isHidden = message == nil
        privacyButton.isHidden = !permission
    }

    @objc func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Selection

    /// The layout actually on screen. Search results and the drive list
    /// have no columns to open, so they show as details.
    var shownMode: ViewMode {
        if (viewMode == .columns || viewMode == .usage) && (isSearching || location.url == nil) { return .details }
        return viewMode
    }

    var activeList: NSView {
        switch shownMode {
        case .details: return table
        case .icons: return grid
        case .columns: return columns.browser
        case .usage: return treemap
        }
    }

    var selectedIndexes: [Int] {
        let indexes: [Int]
        switch shownMode {
        case .details: indexes = Array(table.selectedRowIndexes)
        case .icons: indexes = grid.selectionIndexPaths.map(\.item).sorted()
        case .columns, .usage: return []
        }
        return indexes.filter { $0 < items.count }
    }

    var selectedItems: [FileItem] {
        switch shownMode {
        case .columns: return columns.selectedItems
        case .usage: return usageItem.map { [$0] } ?? []
        default: return selectedIndexes.map { items[$0] }
        }
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }
    var firstSelectedIndex: Int? { selectedIndexes.first }

    /// Selects without the selection callbacks; the caller brings the rest up to date.
    func selectQuietly(_ keys: Set<String>) {
        selectingQuietly = true
        select(keys: keys)
        selectingQuietly = false
    }

    func select(keys: Set<String>) {
        let indexes = IndexSet(items.indices.filter { keys.contains(items[$0].key) })
        switch shownMode {
        case .details: table.selectRowIndexes(indexes, byExtendingSelection: false)
        case .icons: grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        case .columns: columns.select(keys: keys)
        case .usage: break
        }
    }

    /// A click in the list that AppKit has handled already: a plain click
    /// makes the item under it the anchor a later Shift+click extends from,
    /// a Command+click (a toggle) leaves the anchor where it was, and a
    /// click on empty space clears it.
    func listClicked(at index: Int?, command: Bool) {
        guard !command else { return }
        selectionAnchor = index.flatMap { items.indices.contains($0) ? items[$0].key : nil }
    }

    /// Windows' Shift+click: everything from the anchor (the item the last
    /// click without modifiers landed on) to this one. With no anchor, from
    /// the selected item, or the first in the list.
    @discardableResult
    func extendSelection(to index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        let from = selectionAnchor.flatMap { anchor in items.firstIndex { $0.key == anchor } }
            ?? firstSelectedIndex ?? 0
        let range = from <= index ? from...index : index...from
        selectQuietly(Set(range.map { items[$0].key }))
        listSelectionDidChange()
        return true
    }

    func scroll(to index: Int) {
        guard index < items.count else { return }
        switch shownMode {
        case .details: table.scrollRowToVisible(index)
        case .icons: grid.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
        case .columns, .usage: break
        }
    }

    func focusList() {
        typeSelection.reset()
        window?.makeFirstResponder(activeList)
    }

    /// The table and the grid report changes here; selections made from code
    /// in the middle of a reload are left for the caller.
    func listSelectionDidChange() {
        guard !selectingQuietly else { return }
        // Moving through the list with the keyboard (or a click AppKit has
        // handled) leaves one item chosen: it becomes the anchor a later
        // Shift+click extends from, as the focused item does in Windows.
        if let only = selectedIndexes.first, selectedIndexes.count == 1 { selectionAnchor = items[only].key }
        // A click while a listing or a sort is on its way is what it should select.
        if pendingSelection != nil { pendingSelection = Set(selectedItems.map(\.key)) }
        selectionChanged()
    }

    func selectionChanged() {
        if shownMode == .usage { rememberUsageSelection() }
        updateStatus()
        updateCommandStates()
        if Prefs.previewPane && !isSecondPane {
            previewPane.show(selectedItems, in: location, count: items.count)
            previewWindow?.show(selectedItems, in: location)
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
           (panel.dataSource as AnyObject?) === self {
            panel.reloadData()
        }
    }

    /// Cut items are drawn faded; redraw when the clipboard changes.
    func refreshMarks() {
        guard shownMode != .columns else { return updateCommandStates() }
        let keys = Set(selectedItems.map(\.key))
        reloadVisibleList()
        select(keys: keys)
        updateCommandStates()
    }

    func updateStatus() {
        var parts: [String] = []
        if shownMode == .usage {
            if let usageNote {
                parts.append(usageNote)
            } else if let root = treemap.root {
                parts.append("\(Format.bytes(root.size)) in \(Format.count(Int64(root.files))) files"
                             + (root.unreadable > 0 ? " (\(Format.count(Int64(root.unreadable))) items couldn't be read)" : ""))
            }
            if let node = usageHover ?? treemap.selected, let root = treemap.root, root.size > 0 {
                let share = Double(node.size) / Double(root.size) * 100
                parts.append("\(node.name): \(Format.bytes(node.size)) (\(share < 1 ? "<1" : String(Int(share.rounded())))%)")
            }
            if let busyText { parts.append(busyText) }
            statusLabel.stringValue = parts.joined(separator: "     ")
            return
        }
        if isSearching {
            let files = items.count == 1 ? "file" : "files"
            var found = "\(Format.items(items.count)) found"
            if flatView && searchQuery.isEmpty && !filters.isActive {
                found = "\(Format.count(Int64(items.count))) \(files) here and in all subfolders"
            }
            if searchRunning { found = "Searching… " + found }
            if searchTruncated { found += " (stopped at \(Format.count(Int64(FolderSearch.limit))))" }
            if searchUnreadable > 0 {
                found += " (\(searchUnreadable == 1 ? "1 folder" : "\(Format.count(Int64(searchUnreadable))) folders") couldn't be searched)"
            }
            parts.append(found)
        } else if !waitingForFolder {
            parts.append(Format.items(items.count))
        } else if !items.isEmpty {
            parts.append("Reading… \(Format.items(items.count)) so far")
        }
        let selected = selectedItems
        if selected.count == 1, let item = selected.first {
            var text = item.name
            if let dimensions = pictureSize(of: item) { text += "     " + dimensions }
            if let size = item.size ?? item.folderSize { text += "     " + Format.bytes(size) }
            if let volume = item.volume {
                text += "     " + item.kind + "     " + Format.bytes(volume.free) + " free"
            } else {
                text += "     " + item.kind
                if let modified = item.modified { text += "     " + Format.date.string(from: modified) }
            }
            parts.append(text)
        } else if !selected.isEmpty {
            var text = "\(Format.items(selected.count)) selected"
            let sizes = selected.compactMap { $0.size ?? $0.folderSize }
            if !sizes.isEmpty { text += "  " + Format.bytes(sizes.reduce(0, +)) }
            parts.append(text)
        }
        if let archive = archiveContext { parts.append("Inside “\(archive.archive.lastPathComponent)”, read-only") }
        if let usageNote, Prefs.folderSizes { parts.append(usageNote) }
        if let busyText { parts.append(busyText) }
        statusLabel.stringValue = parts.joined(separator: "     ")
    }

    /// The picture's pixel size for the status bar: the one read already, or
    /// nil while a background read starts, which brings the status bar up to
    /// date when it arrives. A camera RAW's header alone can take a moment
    /// on a slow disk, so the read stays off the main thread.
    private func pictureSize(of item: FileItem) -> String? {
        guard !item.isFolder, ImageFiles.isImage(item.url) else { return nil }
        let stamp = "\(item.modified?.timeIntervalSince1970 ?? 0)-\(item.size ?? -1)"
        if let read = pictureSizes[item.key], read.stamp == stamp { return read.text }
        let token = "\(item.key)|\(stamp)"
        guard pictureSizeReads.insert(token).inserted else { return nil }
        let url = item.url
        let key = item.key
        Self.pictureSizeQueue.addOperation { [weak self] in
            let text = PreviewPane.pictureDimensions(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pictureSizeReads.remove(token)
                if self.pictureSizes.count >= 500 {
                    for stale in self.pictureSizes.keys.prefix(100) { self.pictureSizes[stale] = nil }
                }
                self.pictureSizes[key] = (stamp, text)
                self.updateStatus()
            }
        }
        return nil
    }

    func updateCommandStates() {
        let selected = selectedItems
        let files = !selected.isEmpty && selected.allSatisfy { $0.volume == nil }
        cutButton.isEnabled = files && !isInArchive
        copyButton.isEnabled = files
        shareButton.isEnabled = files
        deleteButton.isEnabled = (files || sidebar.focusedFolder != nil) && !isInArchive
        renameButton.isEnabled = files && !isInArchive
        pasteButton.isEnabled = currentFolder != nil && FileClipboard.shared.hasFiles
        newButton.isEnabled = currentFolder != nil
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        upButton.isEnabled = parentLocation != nil
    }

    // MARK: Search

    /// A word being typed starts one search once the typing pauses, not one
    /// walk of the whole tree per letter. Enter searches at once.
    @objc func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        searchDelay?.cancel()
        searchDelay = nil
        guard query != searchQuery else { return }
        if query.isEmpty { return endSearch() }
        let enter = NSApp.currentEvent.map { $0.type == .keyDown && ($0.keyCode == 36 || $0.keyCode == 76) } ?? false
        if enter { return startSearch(query) }
        let work = DispatchWorkItem { [weak self] in self?.startSearch(query) }
        searchDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startSearch(_ query: String) {
        searchDelay?.cancel()
        searchDelay = nil
        searchQuery = query
        runSearch()
    }

    func runSearch() {
        folderLoading.cancel()
        let root = location.url ?? FileManager.default.homeDirectoryForCurrentUser
        // A folder listing still on its way must not land among the results.
        loadGeneration += 1
        waitingForFolder = false
        items = []
        loadError = nil
        searchRunning = true
        searchTruncated = false
        searchUnreadable = 0
        searchSorted = false
        pendingSelection = []
        scrollToTop = true
        showItems()
        search.start(in: root, for: searchQuery, filters: filters, showHidden: Prefs.showHidden, filesOnly: flatView, found: { [weak self] batch in
            self?.appendResults(batch)
        }, finished: { [weak self] truncated, unreadable in
            guard let self else { return }
            self.searchRunning = false
            self.searchTruncated = truncated
            self.searchUnreadable = unreadable
            self.updateEmptyState()
            self.updateStatus()
        })
    }

    /// Results are added in the order they are found; a column click sorts
    /// them, and then later ones are merged in where they belong. Either way
    /// only the new rows are inserted, not the whole list loaded again.
    private func appendResults(_ batch: [FileItem]) {
        let before = items.count
        let inserted: [Int]
        let keys = Set(selectedItems.map(\.key))
        if searchSorted {
            let result = items.merged(with: batch, by: sort)
            items = result.merged
            inserted = result.inserted
        } else {
            items += batch
            inserted = Array(before..<items.count)
        }
        // Only the visible list gets a proper insert; the hidden one may not
        // have asked for its rows yet, so it is simply told to start over.
        switch shownMode {
        case .details, .columns, .usage:
            table.insertRows(at: IndexSet(inserted), withAnimation: [])
            staleViews.insert(.icons)
        case .icons:
            // A grid that hasn't counted its items since it was loaded would
            // count the new ones twice; that one is loaded again instead.
            if grid.numberOfSections == 1 && grid.numberOfItems(inSection: 0) == before {
                grid.insertItems(at: Set(inserted.map { IndexPath(item: $0, section: 0) }))
            } else {
                grid.reloadData()
            }
            staleViews.insert(.details)
        }
        // Rows inserted above the selection move it; it stays on the same files.
        if !keys.isEmpty && (searchSorted || shownMode == .icons) { selectQuietly(keys) }
        updateEmptyState()
        updateStatus()
    }

    /// The search box was emptied. With a search option still set, the
    /// search goes on without words; otherwise the folder comes back.
    func endSearch() {
        searchDelay?.cancel()
        searchDelay = nil
        search.cancel()
        searchQuery = ""
        if !searchField.stringValue.isEmpty { searchField.stringValue = "" }
        if filters.isActive || flatView {
            runSearch()
            return
        }
        searchRunning = false
        searchTruncated = false
        searchUnreadable = 0
        pendingSelection = []
        scrollToTop = true
        load()
    }

    // MARK: Search options

    @objc func toggleFilters(_ sender: Any?) {
        showsFilterBar = !(showsFilterBar || filters.isActive)
        if !showsFilterBar && filters.isActive { filtersChanged(SearchFilters()) }
        applyFilterBar()
    }

    func applyFilterBar() {
        let visible = showsFilterBar || filters.isActive
        filterBar.isHidden = !visible
        filterBarHeight.constant = visible ? 36 : 0
        filterButton.isOn = visible
    }

    func filtersChanged(_ new: SearchFilters) {
        filters = new
        filterBar.filters = new
        applyFilterBar()
        // Words typed a moment ago, still waiting, go along now.
        let typed = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if searchDelay != nil && !typed.isEmpty { return startSearch(typed) }
        if isSearching { runSearch() } else { endSearch() }
    }

    // MARK: View mode

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let keys = Set(selectedItems.map(\.key))
        viewMode = mode
        // Disk usage is a look taken now and then, not how every folder should open.
        if mode != .usage {
            UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
            if let url = location.url, !isSearching { Prefs.rememberFolderView(mode.rawValue, for: url) }
        }
        applyViewMode()
        select(keys: keys)
        if let first = firstSelectedIndex { scroll(to: first) }
        focusList()
        selectionChanged()
    }

    /// Shows the list for the current layout, bringing it up to date if it missed reloads while hidden.
    func applyViewMode() {
        layoutLists()
        if staleViews.remove(shownMode) != nil { reload(shownMode) }
        DispatchQueue.main.async { [weak self] in self?.makeThumbnailsAhead() }
    }

    private func layoutLists() {
        let mode = shownMode
        tableScroll.isHidden = mode != .details
        gridScroll.isHidden = mode != .icons
        columns.browser.isHidden = mode != .columns
        treemap.isHidden = mode != .usage
        iconSlider.doubleValue = Double(viewMode == .icons ? Prefs.iconSize : Self.listNotch)
        detailsToggle.isOn = viewMode == .details
        detailsButton.isOn = viewMode == .details
        iconsToggle.isOn = viewMode == .icons
        columnsToggle.isOn = viewMode == .columns
        usageToggle.isOn = viewMode == .usage
    }

    // MARK: Picture size

    /// The left end of the size slider, which stands for the list (Details).
    static let listNotch: CGFloat = 32

    @objc func iconSizeChanged(_ sender: Any?) {
        setViewSize(CGFloat(iconSlider.doubleValue))
    }

    /// The slider at the bottom left: all the way left is Details; anywhere
    /// right of that is Large icons at that size, switched to at once.
    func setViewSize(_ value: CGFloat) {
        if value < 48 {
            if viewMode == .icons { setViewMode(.details) }
            return
        }
        guard viewMode != .icons else { return setIconSize(value) }
        // What was at the top of the list stays in sight among the pictures.
        let top = shownMode == .details ? table.rows(in: tableScroll.contentView.bounds).location : NSNotFound
        setIconSize(value)
        setViewMode(.icons)
        if firstSelectedIndex == nil, top != NSNotFound, top < items.count {
            grid.layoutSubtreeIfNeeded()
            grid.scrollToItems(at: [IndexPath(item: top, section: 0)], scrollPosition: .top)
        }
    }

    func setIconSize(_ side: CGFloat) {
        let side = min(max(side.rounded(), 48), IconGeometry.largest)
        Prefs.iconSize = side
        iconSlider.doubleValue = Double(side)
        guard let layout = grid.collectionViewLayout as? IconLayout, layout.side != side else { return }
        // The picture chosen, or else the first in sight, stays in sight as the size changes.
        let anchor = grid.selectionIndexPaths.min() ?? grid.indexPathsForVisibleItems().min()
        layout.side = side
        if let anchor, !gridScroll.isHidden, anchor.item < items.count {
            grid.layoutSubtreeIfNeeded()
            grid.scrollToItems(at: [anchor], scrollPosition: grid.selectionIndexPaths.isEmpty ? .top : .nearestHorizontalEdge)
        }
    }

    /// A new size, or the same size in a wider or narrower view. A wheel
    /// sends many sizes a second: the tiles on screen follow at once, and
    /// the pictures are drawn again at the new size when it stops.
    func iconGeometryChanged(_ geometry: IconGeometry) {
        for tile in grid.visibleItems() { (tile as? IconItem)?.geometry = geometry }
        let pictures = (geometry.thumbnailSide, geometry.names)
        guard iconPictures.map({ $0 != pictures }) ?? true else { return }
        iconPictures = pictures
        iconReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let selection = self.grid.selectionIndexPaths
            self.selectingQuietly = true
            self.grid.reloadData()
            self.grid.selectionIndexPaths = selection
            self.selectingQuietly = false
            // Pictures at the new size, ahead of the scroll too.
            self.makeThumbnailsAhead()
        }
        iconReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// ⌘+ from the list goes to pictures; ⌘− from the smallest pictures goes back to the list, as the slider does.
    @objc func biggerIcons(_ sender: Any?) { setViewSize(viewMode == .icons ? Prefs.iconSize * 1.25 : Prefs.iconSize) }
    @objc func smallerIcons(_ sender: Any?) { setViewSize(Prefs.iconSize <= 48 ? 0 : max(Prefs.iconSize / 1.25, 48)) }

    // MARK: Disk usage

    @objc func setUsageView(_ sender: Any?) { setViewMode(.usage) }

    /// Measures the folder on screen, or takes the measure already made;
    /// the treemap and the folder sizes share one scan.
    func measure(force: Bool = false, done: @escaping (UsageNode) -> Void) {
        measure(force: force, scan: { $0.scan($1) }, done: done)
    }

    func measure(force: Bool = false, scan read: @escaping (UsageScanner, URL) -> UsageNode?,
                 done: @escaping (UsageNode) -> Void) {
        guard let url = location.url else { return }
        if force {
            UsageCache.forget(url)
            usageScanner?.cancel()
            measuring = nil
        }
        if !force, let tree = UsageCache.node(for: url) { return done(tree) }
        waitingForUsage.append(done)
        guard measuring != location else { return }
        startMeasure(url, scan: read)
    }

    private func startMeasure(_ url: URL, scan read: @escaping (UsageScanner, URL) -> UsageNode?) {
        let scanner = UsageScanner()
        let cacheScan = UsageCache.beginScan(url)
        usageScanner = scanner
        measuring = location
        let target = location
        usageNote = "Measuring…"
        updateStatus()
        // Twice a second, how far the walk has got, and the folder a slow
        // disk keeps it on: the walk can wait on one for long, saying nothing.
        let ticker = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak scanner] timer in
            guard let self, let scanner, self.usageScanner === scanner, self.measuring == target else {
                return timer.invalidate()
            }
            self.usageNote = scanner.progress.note()
            self.treemap.message = self.usageNote
            self.updateStatus()
        }
        RunLoop.main.add(ticker, forMode: .common)
        usageLoading.run({ read(scanner, url) }) { [weak self] tree in
            ticker.invalidate()
            guard let self, self.location == target, self.usageScanner === scanner else { return }
            guard cacheScan.isCurrent else {
                self.startMeasure(url, scan: read)
                return
            }
            self.usageScanner = nil
            self.usageNote = nil
            self.measuring = nil
            let waiting = self.waitingForUsage
            self.waitingForUsage = []
            self.waitingForFolderSizes = false
            if let tree {
                UsageCache.store(tree)
                waiting.forEach { $0(tree) }
            } else {
                self.treemap.message = "Measurement stopped. Refresh to try again."
            }
            self.updateStatus()
        }
    }

    func showUsage(force: Bool = false) {
        guard location.url != nil else { return }
        treemap.root = nil
        treemap.message = "Measuring “\(location.title)”…"
        usageItem = nil
        measure(force: force) { [weak self] tree in
            guard let self, self.shownMode == .usage else { return }
            self.treemap.root = tree
            self.treemap.message = nil
            self.selectionChanged()
        }
    }

    /// View › Folder Sizes: the Size column shows what each folder holds.
    func fillFolderSizes() {
        guard Prefs.folderSizes, !isSearching, let url = location.url, items.contains(where: { $0.isFolder && $0.volume == nil }) else { return }
        if let tree = UsageCache.node(for: url) { return showFolderSizes(tree) }
        // Reloads while the scan runs would otherwise each queue another answer.
        guard !waitingForFolderSizes else { return }
        waitingForFolderSizes = true
        measure { [weak self] tree in
            self?.waitingForFolderSizes = false
            guard Prefs.folderSizes else { return }
            self?.showFolderSizes(tree)
        }
    }

    /// View › Folder Sizes was switched: only the Size column changes, so the folder isn't read again.
    func folderSizesChanged() {
        if Prefs.folderSizes { return fillFolderSizes() }
        for item in items { item.folderSize = nil }
        sizesChanged()
    }

    private func showFolderSizes(_ tree: UsageNode) {
        assignFolderSizes(tree)
        sizesChanged()
    }

    private func sizesChanged() {
        if sort.key == .size {
            resort()
        } else {
            let column = table.column(withIdentifier: .sizeColumn)
            if column >= 0 { table.reloadData(forRowIndexes: IndexSet(items.indices), columnIndexes: [column]) }
            updateStatus()
        }
    }

    static func folderSizes(in tree: UsageNode) -> [String: Int64] {
        Dictionary(tree.children.filter(\.isFolder).map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    private func assignFolderSizes(_ tree: UsageNode) {
        let sizes = Self.folderSizes(in: tree)
        for item in items where item.isFolder && item.volume == nil { item.folderSize = sizes[item.name] }
    }

    private func rememberUsageSelection() {
        guard let node = treemap.selected else {
            usageItem = nil
            return
        }
        guard usageItem?.key != node.url.key else { return }
        let item = FileItem(url: node.url)
        if node.isFolder { item.folderSize = node.size }
        usageItem = item
    }

    func usageHovered(_ node: UsageNode?) {
        usageHover = node
        updateStatus()
    }

    func openUsageNode(_ node: UsageNode) {
        guard !node.isRest else { return }
        if node.isFolder && !node.isPackage {
            navigate(to: .folder(node.url))
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    // MARK: Preview pane

    @objc func togglePreviewDetachment(_ sender: Any?) {
        guard Prefs.previewPane, !isSecondPane else { return }
        if let previewWindow {
            previewWindow.close()
            return
        }
        guard previewPane.superview === split else { return }
        let sidebarWidth = split.arrangedSubviews[0].frame.width
        split.removeArrangedSubview(previewPane)
        previewPane.removeFromSuperview()
        split.adjustSubviews()
        split.setPosition(sidebarWidth, ofDividerAt: 0)
        let detached = PreviewWindow(pane: previewPane)
        previewWindow = detached
        previewPane.isDetached = true
        detached.onClose = { [weak self] in
            guard let self else { return }
            self.previewWindow = nil
            self.previewPane.isDetached = false
            self.applyPreviewPane()
            if Prefs.previewPane { self.host?.window?.makeKeyAndOrderFront(nil) }
        }
        detached.show(selectedItems, in: location)
        detached.showWindow(nil)
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        Prefs.previewPane.toggle()
        NotificationCenter.default.post(name: .explorerPreviewPaneChanged, object: nil)
    }

    /// The pane is taken out of the split view when put away, so the file
    /// list gets the whole width back.
    func applyPreviewPane() {
        paneButton.isOn = Prefs.previewPane
        let shown = Prefs.previewPane && !isSecondPane
        if !shown, let previewWindow {
            previewPane.clear()
            previewWindow.close()
            return
        }
        guard previewWindow == nil else { return }
        guard (previewPane.superview === split) != shown else { return }
        if shown {
            let sidebarWidth = split.arrangedSubviews[0].frame.width
            split.addArrangedSubview(previewPane)
            split.layoutSubtreeIfNeeded()
            placePreviewPane()
            split.setPosition(sidebarWidth, ofDividerAt: 0)
            selectionChanged()
        } else {
            previewPane.clear()
            split.removeArrangedSubview(previewPane)
            previewPane.removeFromSuperview()
        }
    }

    /// At the width it had last time (300 at first).
    private func placePreviewPane() {
        let saved = UserDefaults.standard.double(forKey: "previewWidth")
        let width = saved >= 180 ? saved : 300
        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
    }

    /// Resizing the window changes the file list. Squeezed below 260 points,
    /// it takes from the preview pane (down to 180), then the navigation pane
    /// (down to 150); given room again, they get back the widths you gave them.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let views = splitView.arrangedSubviews
        guard views.count >= 2 else { return splitView.adjustSubviews() }
        let (sideMin, listMin, paneMin): (CGFloat, CGFloat, CGFloat) = (150, 260, 180)
        let thickness = splitView.dividerThickness
        let height = splitView.bounds.height
        let hasPane = views.count == 3
        let sideShown = !views[0].isHidden
        let room = splitView.bounds.width - (sideShown ? thickness : 0) - (hasPane ? thickness : 0)
        guard room >= 0 else {
            // No room even for the dividers, as before the window first lays
            // the tab out: every pane empty and in order. AppKit's own
            // adjustSubviews put them out of order here, and said so at launch.
            for view in views { view.frame = NSRect(x: 0, y: 0, width: 0, height: height) }
            return
        }
        let sideWanted = max(UserDefaults.standard.double(forKey: sidebarWidthKey), 0) >= sideMin
            ? UserDefaults.standard.double(forKey: sidebarWidthKey) : 220
        let paneWanted = UserDefaults.standard.double(forKey: "previewWidth") >= paneMin
            ? UserDefaults.standard.double(forKey: "previewWidth") : 300
        var side = sideShown ? views[0].frame.width : 0
        var pane = hasPane ? views[2].frame.width : 0
        var list = room - side - pane
        if list < listMin, hasPane {
            let give = min(listMin - list, max(pane - paneMin, 0))
            pane -= give
            list += give
        }
        if list < listMin && sideShown {
            let give = min(listMin - list, max(side - sideMin, 0))
            side -= give
            list += give
        }
        if list > listMin && sideShown && side < sideWanted {
            let take = min(list - listMin, sideWanted - side)
            side += take
            list -= take
        }
        if list > listMin && hasPane && pane < paneWanted {
            let take = min(list - listMin, paneWanted - pane)
            pane += take
            list -= take
        }
        // Below the minimums (a window still being laid out), the panes still
        // add up to the split view's width rather than running past its edge.
        side = min(side, room)
        pane = min(pane, room - side)
        list = room - side - pane
        let start = sideShown ? side + thickness : 0
        views[0].frame = NSRect(x: 0, y: 0, width: side, height: height)
        views[1].frame = NSRect(x: start, y: 0, width: list, height: height)
        if hasPane { views[2].frame = NSRect(x: start + list + thickness, y: 0, width: pane, height: height) }
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        dividerIndex == 0 && splitView.arrangedSubviews.first?.isHidden == true
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        dividerIndex == 0 && splitView.arrangedSubviews.first?.isHidden == true ? .zero : proposedEffectiveRect
    }

    /// Widths are remembered only when you drag a divider, not when a narrow window squeezes the panes.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let divider = notification.userInfo?["NSSplitViewDividerIndex"] as? Int,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }
        let views = split.arrangedSubviews
        if divider == 0, views[0].frame.width >= 150 {
            UserDefaults.standard.set(Double(views[0].frame.width), forKey: sidebarWidthKey)
        }
        if divider == 1, views.count == 3, views[2].frame.width >= 180 {
            UserDefaults.standard.set(Double(views[2].frame.width), forKey: "previewWidth")
        }
    }

    // MARK: Window

    /// ⌘Z undoes file operations; inside a text field it undoes typing.
    func undoManager(in window: NSWindow) -> UndoManager {
        window.firstResponder is NSText ? textUndo : FileUndo.manager
    }

    /// The tab is closing (or its window is): stop watching and listening.
    func tearDown() {
        folderLoading.cancel()
        loadGeneration += 1
        navigationGeneration += 1
        searchDelay?.cancel()
        search.cancel()
        columns.cancelLoading()
        watcher.stop()
        sidebar.stop()
        cloudRefresh?.cancel()
        iconReload?.cancel()
        // A change or an opening still waiting would read the folder again for
        // nobody, and thumbnails asked for ahead would go on being made.
        changeReload?.cancel()
        changeReload = nil
        opening?.cancel()
        opening = nil
        cancelThumbnailsAhead()
        usageScanner?.cancel()
        usageScanner = nil
        usageLoading.cancel()
        measuring = nil
        waitingForUsage = []
        waitingForFolderSizes = false
        previewWindow?.onClose = nil
        previewWindow?.close()
        previewWindow = nil
        previewPane.tearDown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // Divider 0 is the navigation pane's edge, divider 1 the preview pane's.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? 150 : max(splitView.arrangedSubviews[0].frame.maxX + 320, splitView.bounds.width - 560)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? min(460, splitView.bounds.width - 320) : splitView.bounds.width - 200
    }


    // MARK: Quick Look (space bar)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension ExplorerTab: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = selectedItems
        return index < items.count ? items[index].url as NSURL : nil
    }

    /// Arrow keys in the preview move through the list, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        activeList.keyDown(with: event)
        return true
    }
}
