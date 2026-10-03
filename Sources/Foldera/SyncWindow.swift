import AppKit
import UniformTypeIdentifiers

/// File › Sync Folders…: FreeFileSync's idea in one window. Two folders and
/// how to sync them; Compare lists what would happen, row by row (right-click
/// a row to change it), and Synchronize does it.
final class SyncWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate {
    /// A pair of folders and how they are synced. The last ten are offered again.
    struct Setup: Codable, Equatable {
        var left = ""
        var right = ""
        var mode = Sync.Mode.twoWay
        var comparison = Sync.Comparison.dateAndSize
        var permanently = false
        var towardLeft: Bool?
        /// Names never synced (see `Sync.Exclusion`).
        var excludes = ""

        /// The same two folders, whichever side each is on.
        func isPair(_ other: Setup) -> Bool {
            !left.isEmpty && !right.isEmpty && Set([left, right]) == Set([other.left, other.right])
        }

        static var recent: [Setup] {
            get {
                UserDefaults.standard.data(forKey: "syncRecent").flatMap { try? JSONDecoder().decode([Setup].self, from: $0) } ?? []
            }
            set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(10))), forKey: "syncRecent") }
        }

        static func remember(_ setup: Setup) {
            recent = [setup] + recent.filter { !$0.isPair(setup) }
        }

        /// A mode chosen between the panes must use the requested source and
        /// destination, even when this pair was previously synced in reverse.
        static func forFolders(_ folders: [URL], mode: Sync.Mode?, recent: [Setup]) -> Setup {
            var setup: Setup
            switch folders.count {
            case 0: setup = recent.first ?? Setup()
            case 1:
                let key = folders[0].key
                setup = recent.first { $0.left == key || $0.right == key } ?? Setup(left: key)
            default:
                let chosen = Setup(left: folders[0].key, right: folders[1].key)
                setup = recent.first { $0.isPair(chosen) } ?? chosen
                if mode != nil {
                    setup.left = chosen.left
                    setup.right = chosen.right
                    setup.towardLeft = false
                }
            }
            if let mode { setup.mode = mode }
            return setup
        }
    }

    private static var open: [SyncWindow] = []
    private static let actions: [Sync.Action] = [.toRight, .toLeft, .deleteLeft, .deleteRight, .none]

    private let leftField = FolderField()
    private let rightField = FolderField()
    private let chooseLeft = NSButton(title: "Choose…", target: nil, action: nil)
    private let chooseRight = NSButton(title: "Choose…", target: nil, action: nil)
    private let swapButton = NSButton()
    private let recentButton = NSButton()
    private var mode: Sync.Mode = .twoWay
    private let explanation = NSTextField(labelWithString: "")
    private let comparePopup = NSPopUpButton()
    private let removalPopup = NSPopUpButton()
    private let excludeField = NSTextField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let syncButton = NSButton(title: "Synchronize", target: nil, action: nil)
    private let textUndo = UndoManager()
    private var towardLeft = false
    private let directionButton = ToolButton(symbol: "arrow.right", tip: "Change sync direction", iconSize: 20, height: 32, padding: 12)
    private let modeButton = ToolButton(symbol: "chevron.down", tip: "Sync mode: Mirror, Update or Two way", iconSize: 12, height: 32, padding: 8)
    var isSynchronizing: Bool { syncing }
    var isComparing: Bool { comparing != nil }
    var canSynchronize: Bool { syncButton.isEnabled }
    var plannedRows: [Sync.Row] { plan.rows }

    private let profilePopup = NSPopUpButton()
    private let saveProfileButton = NSButton(title: "Save Profile…", target: nil, action: nil)
    private let scheduleButton = NSButton(title: "Schedule…", target: nil, action: nil)
    private let profileStatus = NSTextField(labelWithString: "")
    private let filterControl = NSSegmentedControl()
    private let filterStatus = NSTextField(labelWithString: "")
    private var profileID: UUID?
    private var profiles: [SyncLibrary.Profile] = []
    private var libraryError: String?
    private var libraryObserver: NSObjectProtocol?
    private var visibleIndices: [Int] = []
    private(set) var filter: SyncFilter = .all
    var visibleRows: [Sync.Row] { visibleIndices.map { plan.rows[$0] } }

    private var scan: Sync.Scan?
    private var plan = Sync.Plan()
    /// Plans are made in the background; the one on screen is current when these agree.
    private var planWanted = 0
    private var planShown = 0
    private var comparing: CancelFlag?
    private var syncing = false
    /// What the last Synchronize did, said until you compare again.
    private var result: String?
    private var icons: [String: NSImage] = [:]

    /// The folders chosen: two, one (with the other side it was last synced
    /// with), or none (the pair synced last).
    static func show(_ folders: [URL], mode: Sync.Mode? = nil, compare: Bool = false, preserveSides: Bool = false) {
        var setup = Setup.forFolders(folders, mode: mode, recent: Setup.recent)
        if preserveSides && folders.count == 2 {
            setup.left = folders[0].key
            setup.right = folders[1].key
        }
        if let existing = open.first(where: { $0.setup.isPair(setup) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            if (mode != nil || preserveSides) && !existing.syncing {
                existing.apply(setup)
                if compare { existing.compare(nil) }
            }
            return
        }
        let controller = SyncWindow(setup)
        open.append(controller)
        controller.showWindow(nil)
        if compare { controller.compare(nil) }
    }

    static func showSetup(_ setup: Setup, profileID: UUID? = nil) {
        if let existing = open.first(where: { profileID != nil && $0.profileID == profileID }) {
            existing.window?.makeKeyAndOrderFront(nil)
            if !existing.syncing { existing.apply(setup) }
            return
        }
        let controller = SyncWindow(setup)
        controller.profileID = profileID
        controller.updateControls()
        open.append(controller)
        controller.showWindow(nil)
    }

    func loadProfile(_ id: UUID) {
        guard !syncing, let profile = profiles.first(where: { $0.id == id }) else { return }
        profileID = id
        apply(profile.setup)
    }

    /// For `--snapshot folder out.png --sync other [--mode mirror]`: the window, compared at once.
    static func showCompared(_ left: URL, _ right: URL, mode: Sync.Mode?, size: NSSize?, compare: Bool = true, towardLeft: Bool = false) {
        let controller = SyncWindow(Setup(left: left.key, right: right.key, mode: mode ?? .twoWay, towardLeft: towardLeft))
        open.append(controller)
        if let raw = CommandLine.arguments.firstIndex(of: "--sync-profile"), CommandLine.arguments.indices.contains(raw + 1),
           let id = UUID(uuidString: CommandLine.arguments[raw + 1]) { controller.loadProfile(id) }
        if let index = CommandLine.arguments.firstIndex(of: "--sync-filter"), CommandLine.arguments.indices.contains(index + 1),
           let value = SyncFilter(rawValue: CommandLine.arguments[index + 1]) { controller.selectFilter(value) }
        if let size { controller.window?.setContentSize(size) }
        controller.showWindow(nil)
        if compare { controller.compare(nil) }
    }

    init(_ setup: Setup) {
        let window = EscWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Sync Folders"
        window.minSize = NSSize(width: 960, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        apply(setup)
        refreshProfiles()
        libraryObserver = NotificationCenter.default.addObserver(forName: SyncLibrary.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshProfiles()
        }
        if !window.setFrameAutosaveName("SyncWindow"), let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame SyncWindow") == nil {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) } }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        for (field, side) in [(leftField, "Left"), (rightField, "Right")] {
            field.placeholderString = "Choose or drop the \(side.lowercased()) folder"
            field.delegate = self
            field.lineBreakMode = .byTruncatingMiddle
            field.cell?.usesSingleLineMode = true
            field.onDrop = { [weak self] in self?.foldersChanged() }
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        chooseLeft.target = self
        chooseLeft.action = #selector(chooseLeftFolder(_:))
        chooseRight.target = self
        chooseRight.action = #selector(chooseRightFolder(_:))
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap folders")
        swapButton.toolTip = "Swap the left and right folders"
        swapButton.target = self
        swapButton.action = #selector(swapSides(_:))
        recentButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recent folders")
        recentButton.toolTip = "Folders synced before"
        recentButton.target = self
        recentButton.action = #selector(showRecent(_:))

        comparePopup.addItems(withTitles: Sync.Comparison.allCases.map { "Compare \($0.title.lowercased())" })
        comparePopup.toolTip = "Compare dates and sizes, or read file content"
        comparePopup.target = self
        comparePopup.action = #selector(comparisonChanged(_:))
        removalPopup.addItems(withTitles: ["Deleted files to the Trash", "Delete files permanently"])
        removalPopup.toolTip = "Where replaced and deleted files go"
        removalPopup.target = self
        removalPopup.action = #selector(removalChanged(_:))
        compareButton.target = self
        compareButton.action = #selector(compare(_:))
        compareButton.keyEquivalent = "\r"
        compareButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        compareButton.imagePosition = .imageLeading
        compareButton.toolTip = "See what would change (Enter or ⌘R)"
        syncButton.target = self
        syncButton.action = #selector(synchronize(_:))
        syncButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        syncButton.imagePosition = .imageLeading
        for button in [chooseLeft, chooseRight, swapButton, recentButton, compareButton, syncButton] {
            button.bezelStyle = .rounded
        }
        directionButton.target = self
        directionButton.action = #selector(switchDirection(_:))
        modeButton.target = self
        modeButton.action = #selector(showModes(_:))
        let compareGroup = NSStackView(views: [compareButton, comparePopup])
        compareGroup.spacing = 8
        let syncGroup = NSStackView(views: [syncButton, modeButton])
        syncGroup.spacing = 0
        let toolbar = NSView()
        for view in [compareGroup, directionButton, syncGroup] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(view)
            view.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            compareGroup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            directionButton.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            syncGroup.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            compareGroup.trailingAnchor.constraint(lessThanOrEqualTo: directionButton.leadingAnchor, constant: -12),
            directionButton.trailingAnchor.constraint(lessThanOrEqualTo: syncGroup.leadingAnchor, constant: -12),
        ])
        toolbar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        syncButton.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let leftTitle = NSTextField(labelWithString: "Left folder")
        let rightTitle = NSTextField(labelWithString: "Right folder")
        for title in [leftTitle, rightTitle] { title.font = .systemFont(ofSize: 11, weight: .semibold) }
        let leftPath = NSStackView(views: [leftTitle, leftField, chooseLeft])
        let rightPath = NSStackView(views: [rightTitle, rightField, chooseRight])
        leftPath.spacing = 8
        rightPath.spacing = 8
        let paths = NSStackView(views: [leftPath, swapButton, rightPath, recentButton])
        paths.spacing = 10
        leftPath.widthAnchor.constraint(equalTo: rightPath.widthAnchor).isActive = true

        excludeField.placeholderString = "node_modules; *.tmp; .git"
        excludeField.toolTip = "Names never synced, with ; between them. * and ? are wildcards. "
            + "What is excluded is left alone on both sides, and a folder holding any of it is never deleted whole."
        excludeField.delegate = self
        excludeField.cell?.usesSingleLineMode = true
        excludeField.lineBreakMode = .byTruncatingTail
        excludeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let excludeLabel = NSTextField(labelWithString: "Exclude:")
        let filters = NSStackView(views: [excludeLabel, excludeField])
        filters.spacing = 8

        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.lineBreakMode = .byTruncatingTail
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let options = NSStackView()
        options.setViews([explanation], in: .leading)
        options.setViews([removalPopup], in: .trailing)
        options.spacing = 12

        profilePopup.target = self
        profilePopup.action = #selector(pickProfile(_:))
        profilePopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        profilePopup.toolTip = "Choose a saved profile, or use the current folders as a new profile"
        saveProfileButton.target = self
        saveProfileButton.action = #selector(saveProfile(_:))
        scheduleButton.target = self
        scheduleButton.action = #selector(editSchedule(_:))
        let historyButton = NSButton(title: "History…", target: self, action: #selector(showHistory(_:)))
        for button in [saveProfileButton, scheduleButton, historyButton] { button.bezelStyle = .rounded }
        profileStatus.font = .systemFont(ofSize: 11)
        profileStatus.textColor = .secondaryLabelColor
        profileStatus.lineBreakMode = .byTruncatingTail
        let profileBar = NSStackView()
        profileBar.setViews([profilePopup, saveProfileButton, scheduleButton, profileStatus], in: .leading)
        profileBar.setViews([historyButton], in: .trailing)
        profileBar.spacing = 8
        filterControl.segmentCount = SyncFilter.allCases.count
        filterControl.trackingMode = .selectOne
        for (index, value) in SyncFilter.allCases.enumerated() { filterControl.setLabel(value.title, forSegment: index) }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.toolTip = "Filter the preview only. Synchronize still runs every planned action."
        filterStatus.font = .systemFont(ofSize: 11)
        filterStatus.textColor = .secondaryLabelColor
        filterStatus.lineBreakMode = .byTruncatingTail
        filterStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let filterBar = NSStackView()
        filterBar.setViews([filterControl], in: .leading)
        filterBar.setViews([filterStatus], in: .trailing)
        filterBar.spacing = 10

        // One table keeps corresponding paths, actions, selection and scrolling aligned.
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("leftName", "Left · Relative path", 240, 150), ("leftSize", "Size", 80, 65),
            ("leftDate", "Modified", 135, 115), ("action", "Action", 180, 160),
            ("rightName", "Right · Relative path", 240, 150), ("rightSize", "Size", 80, 65),
            ("rightDate", "Modified", 135, 115),
        ]
        for (id, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = minimum
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        rowMenu.autoenablesItems = false
        table.menu = rowMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let bottom = NSStackView()
        bottom.setViews([summary], in: .leading)
        bottom.setViews([spinner], in: .trailing)
        let stack = NSStackView(views: [profileBar, toolbar, paths, options, filters, filterBar, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(emptyLabel)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ]
        for view in [profileBar, toolbar, paths, options, filters, filterBar, scroll, bottom] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc func switchDirection(_ sender: Any?) {
        guard !syncing, comparing == nil, mode != .twoWay else { return }
        towardLeft.toggle()
        explanation.stringValue = modeExplanation
        replan()
        updateControls()
    }

    func selectMode(_ selected: Sync.Mode) {
        guard !syncing, comparing == nil else { return }
        mode = selected
        modeChanged(nil)
        updateControls()
    }

    @objc private func showModes(_ sender: Any?) {
        let menu = NSMenu()
        for mode in [Sync.Mode.mirror, .update, .twoWay] {
            let item = NSMenuItem(title: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = self.mode == mode ? .on : .off
            item.toolTip = mode.explanation
            menu.addItem(item)
        }
        modeButton.popUp(menu)
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Sync.Mode(rawValue: raw) else { return }
        selectMode(mode)
    }

    // MARK: Profiles and preview filters

    private func refreshProfiles() {
        do { profiles = try SyncLibrary.profiles(); libraryError = nil }
        catch { libraryError = error.localizedDescription }
        if let profileID, !profiles.contains(where: { $0.id == profileID }) { self.profileID = nil }
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: "Current folders (unsaved)")
        profilePopup.lastItem?.tag = -1
        for profile in profiles {
            profilePopup.addItem(withTitle: profile.name)
            profilePopup.lastItem?.representedObject = profile.id.uuidString
        }
        profilePopup.menu?.addItem(.separator())
        for (title, tag) in [("Rename Profile…", -2), ("Delete Profile…", -3)] {
            profilePopup.addItem(withTitle: title)
            profilePopup.lastItem?.tag = tag
        }
        updateControls()
    }

    private func updateProfileControls(idle: Bool) {
        let saved = profiles.first { $0.id == profileID }
        let modified = saved.map { $0.setup != setup } ?? false
        let index = saved.flatMap { profile in profiles.firstIndex { $0.id == profile.id }.map { $0 + 1 } } ?? 0
        profilePopup.selectItem(at: index)
        for item in profilePopup.itemArray {
            guard let raw = item.representedObject as? String, let id = UUID(uuidString: raw), let profile = profiles.first(where: { $0.id == id }) else { continue }
            item.title = profile.name + (id == profileID && modified ? " · modified" : "")
        }
        profilePopup.isEnabled = idle
        saveProfileButton.isEnabled = idle && leftField.url != nil && rightField.url != nil
        saveProfileButton.title = saved == nil ? "Save Profile…" : "Save Changes"
        scheduleButton.isEnabled = idle && saved != nil && !modified
        scheduleButton.toolTip = saved == nil || modified ? "Save the profile first, then set its schedule" : "Set automatic sync for this saved profile"
        if let saved {
            profileStatus.stringValue = saved.pausedReason != nil ? "Schedule paused · Review history" : saved.schedule.frequency == .off ? "" : saved.schedule.title
            profileStatus.toolTip = saved.pausedReason ?? saved.nextRun.map { "Next run: \(Format.date.string(from: $0))" }
        } else { profileStatus.stringValue = ""; profileStatus.toolTip = nil }
        if let libraryError { profileStatus.stringValue = "Profiles could not be read"; profileStatus.toolTip = libraryError }
        profilePopup.itemArray.filter { $0.tag == -2 || $0.tag == -3 }.forEach { $0.isEnabled = saved != nil && idle }
    }

    @objc private func pickProfile(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if item.tag == -2 { updateControls(); renameProfile(); return }
        if item.tag == -3 { updateControls(); deleteProfile(); return }
        if let raw = item.representedObject as? String, let id = UUID(uuidString: raw), let profile = profiles.first(where: { $0.id == id }) {
            profileID = id
            apply(profile.setup)
        } else { profileID = nil; updateControls() }
    }

    @objc private func saveProfile(_ sender: Any?) {
        do {
            _ = try SyncScheduler.folders(setup)
            if var saved = profiles.first(where: { $0.id == profileID }) {
                saved.setup = setup
                try SyncLibrary.save(saved)
                refreshProfiles()
            } else { nameProfile(existing: nil) }
        } catch { alert(error.localizedDescription) }
    }
    private func renameProfile() {
        if let saved = profiles.first(where: { $0.id == profileID }) { nameProfile(existing: saved) }
    }
    private func nameProfile(existing: SyncLibrary.Profile?) {
        guard let window else { return }
        let prompt = NSAlert()
        prompt.messageText = existing == nil ? "Save Sync Profile" : "Rename Sync Profile"
        prompt.informativeText = "Keep these folders, direction, sync mode and comparison settings together."
        let name = NSTextField(string: existing?.name ?? "\(leftField.url?.lastPathComponent ?? "") → \(rightField.url?.lastPathComponent ?? "")")
        name.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        prompt.accessoryView = name
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var profile = existing ?? SyncLibrary.Profile(name: name.stringValue, setup: self.setup)
            profile.name = name.stringValue
            do {
                let saved = try SyncLibrary.save(profile)
                self.profileID = saved.id
                self.refreshProfiles()
            } catch { self.alert(error.localizedDescription) }
        }
        prompt.window.makeFirstResponder(name)
    }
    private func deleteProfile() {
        guard let saved = profiles.first(where: { $0.id == profileID }), let window else { return }
        let prompt = NSAlert()
        prompt.messageText = "Delete profile “\(saved.name)”?"
        prompt.informativeText = "Its schedule will stop. Your files and sync history stay available."
        prompt.addButton(withTitle: "Delete Profile")
        prompt.addButton(withTitle: "Cancel")
        prompt.buttons[0].hasDestructiveAction = true
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try SyncLibrary.remove(saved.id)
                if saved.schedule.frequency != .off {
                    do { try SyncAgent.refresh() }
                    catch { _ = try? SyncLibrary.save(saved); try? SyncAgent.refresh(); throw error }
                }
                self.profileID = nil
                self.refreshProfiles()
            } catch { self.alert(error.localizedDescription) }
        }
    }
    @objc func editSchedule(_ sender: Any?) {
        guard let saved = profiles.first(where: { $0.id == profileID }), saved.setup == setup, let window else { return }
        let editor = SyncScheduleEditor(saved.schedule)
        let prompt = NSAlert()
        prompt.messageText = "Schedule “\(saved.name)”"
        prompt.informativeText = "Use the saved profile automatically."
        prompt.accessoryView = editor
        prompt.addButton(withTitle: "Save Schedule")
        prompt.addButton(withTitle: "Cancel")
        prompt.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var profile = saved
            profile.schedule = editor.schedule
            profile.nextRun = profile.schedule.next(after: Date())
            profile.pausedReason = nil
            do {
                try SyncLibrary.save(profile)
                do { try SyncAgent.refresh() }
                catch { _ = try? SyncLibrary.save(saved); try? SyncAgent.refresh(); throw error }
                self.refreshProfiles()
            } catch { self.alert(error.localizedDescription) }
        }
    }
    @objc private func showHistory(_ sender: Any?) { SyncHistoryWindow.show() }

    func selectFilter(_ value: SyncFilter) {
        filter = value
        filterControl.selectedSegment = SyncFilter.allCases.firstIndex(of: value) ?? 0
        reloadRows()
        updateControls()
    }
    @objc private func filterChanged(_ sender: Any?) {
        selectFilter(SyncFilter.allCases[max(filterControl.selectedSegment, 0)])
    }
    private func reloadRows() {
        visibleIndices = plan.rows.indices.filter { filter.includes(plan.rows[$0]) }
        table.deselectAll(nil)
        table.reloadData()
        filterStatus.stringValue = plan.rows.isEmpty ? "Preview filter" : "Showing \(visibleIndices.count) of \(plan.rows.count) · Sync uses all changes"
    }

    // MARK: Settings

    private var modeExplanation: String {
        guard towardLeft && mode != .twoWay else { return mode.explanation }
        return mode == .mirror
            ? "The left folder becomes an exact copy of the right. Whatever is only on the left is deleted."
            : "New and newer files are copied from the right to the left. Nothing is deleted."
    }

    private var comparison: Sync.Comparison { Sync.Comparison.allCases[max(comparePopup.indexOfSelectedItem, 0)] }
    private var permanently: Bool { removalPopup.indexOfSelectedItem == 1 }

    private var setup: Setup {
        Setup(left: leftField.url?.key ?? "", right: rightField.url?.key ?? "",
              mode: mode, comparison: comparison, permanently: permanently,
              towardLeft: towardLeft, excludes: excludeField.stringValue)
    }

    private var exclusion: Sync.Exclusion { Sync.Exclusion(excludeField.stringValue) }

    private func apply(_ setup: Setup) {
        towardLeft = setup.towardLeft ?? false
        leftField.url = setup.left.isEmpty ? nil : URL(fileURLWithPath: setup.left)
        rightField.url = setup.right.isEmpty ? nil : URL(fileURLWithPath: setup.right)
        mode = setup.mode
        excludeField.stringValue = setup.excludes
        comparePopup.selectItem(at: Sync.Comparison.allCases.firstIndex(of: setup.comparison) ?? 0)
        removalPopup.selectItem(at: setup.permanently ? 1 : 0)
        explanation.stringValue = modeExplanation
        foldersChanged()
    }

    /// Whatever was compared is about other folders now.
    private func foldersChanged() {
        comparing?.set()
        comparing = nil
        scan = nil
        plan = Sync.Plan()
        planWanted += 1
        planShown = planWanted
        result = nil
        reloadRows()
        updateSummary()
        updateControls()
    }

    func controlTextDidChange(_ notification: Notification) { foldersChanged() }

    @objc private func chooseLeftFolder(_ sender: Any?) { choose(for: leftField) }
    @objc private func chooseRightFolder(_ sender: Any?) { choose(for: rightField) }

    private func choose(for field: FolderField) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = field === leftField ? "Choose the left folder" : "Choose the right folder"
        panel.directoryURL = field.url ?? leftField.url ?? rightField.url
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            field.url = url
            self?.foldersChanged()
        }
    }

    @objc private func swapSides(_ sender: Any?) {
        let left = leftField.stringValue
        leftField.stringValue = rightField.stringValue
        rightField.stringValue = left
        foldersChanged()
    }

    @objc private func showRecent(_ sender: NSButton) {
        let menu = NSMenu()
        let recent = Setup.recent
        if recent.isEmpty {
            let none = NSMenuItem(title: "No folders synced yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        let arrows: [Sync.Mode: String] = [.twoWay: "⇄", .mirror: "→", .update: "→"]
        for (index, setup) in recent.enumerated() {
            let left = Format.path(URL(fileURLWithPath: setup.left))
            let right = Format.path(URL(fileURLWithPath: setup.right))
            let item = NSMenuItem(title: "\(left)  \(arrows[setup.mode] ?? "")  \(right)   (\(setup.mode.title))",
                                  action: #selector(pickRecent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func pickRecent(_ sender: NSMenuItem) {
        let recent = Setup.recent
        guard sender.tag < recent.count else { return }
        apply(recent[sender.tag])
    }

    @objc private func modeChanged(_ sender: Any?) {
        explanation.stringValue = modeExplanation
        replan()
    }

    @objc private func comparisonChanged(_ sender: Any?) {
        guard let scan, scan.comparison != comparison else { return updateControls() }
        foldersChanged()
    }

    @objc private func removalChanged(_ sender: Any?) {
        updateSummary()
        updateControls()
    }

    // MARK: Comparing

    /// Both folders, if they can be synced with each other.
    private func pair() -> (URL, URL)? {
        guard let left = leftField.url, let right = rightField.url else {
            alert("Choose two folders to sync.")
            return nil
        }
        for url in [left, right] where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
            alert("“\(Format.path(url))” isn't a folder that can be opened.")
            return nil
        }
        guard !FileOps.isInside(left, right) && !FileOps.isInside(right, left) else {
            alert("The two folders can't be the same, or one inside the other.")
            return nil
        }
        guard !ArchiveFolders.isInside(left) && !ArchiveFolders.isInside(right) else {
            alert("An opened archive is read-only. Extract it to sync it.")
            return nil
        }
        return (left, right)
    }

    /// ⌘R, as Refresh does in the file list.
    @objc func refresh(_ sender: Any?) {
        if comparing == nil { compare(sender) }
    }

    @objc func compare(_ sender: Any?) {
        if let comparing {
            comparing.set()
            return
        }
        guard !syncing, let (left, right) = pair() else { return }
        Setup.remember(setup)
        result = nil
        runCompare(left, right, by: comparison, excluding: exclusion)
    }

    private func runCompare(_ left: URL, _ right: URL, by comparison: Sync.Comparison, excluding exclusion: Sync.Exclusion) {
        let flag = CancelFlag()
        comparing = flag
        scan = nil
        plan = Sync.Plan()
        reloadRows()
        summary.stringValue = "Reading the folders…"
        updateControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Result {
                try Sync.compare(left, right, by: comparison, excluding: exclusion, cancelled: flag) { text in
                    DispatchQueue.main.async {
                        guard let self, self.comparing === flag else { return }
                        self.summary.stringValue = text
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.comparing === flag else { return }
                self.comparing = nil
                switch found {
                case .success(let scan):
                    self.show(scan)
                case .failure(let error):
                    self.updateSummary()
                    if !(error is CancellationError) { self.alert(error.localizedDescription) }
                }
                self.updateControls()
            }
        }
    }

    private func show(_ scan: Sync.Scan) {
        self.scan = scan
        replan()
        let problems = scan.problems
        guard !problems.isEmpty else { return }
        alert(problems.count == 1 ? "An item couldn't be read, so it is left alone." : "\(problems.count) items couldn't be read, so they are left alone.",
              info: problems.prefix(6).joined(separator: "\n"))
    }

    /// Off the main thread: a hundred thousand files take a moment. Until
    /// the new plan is on screen, Synchronize waits.
    private func replan() {
        guard let scan else { return }
        planWanted += 1
        let wanted = planWanted
        let mode = self.mode
        let towardLeft = self.towardLeft
        updateControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = Sync.plan(scan, mode: mode, towardLeft: towardLeft)
            DispatchQueue.main.async {
                guard let self, wanted == self.planWanted else { return }
                self.plan = plan
                self.planShown = wanted
                self.reloadRows()
                self.updateSummary()
                self.updateControls()
            }
        }
    }

    // MARK: Synchronizing

    @objc func synchronize(_ sender: Any?) {
        guard let scan, comparing == nil, !syncing, planShown == planWanted,
              plan.rows.contains(where: { $0.action != .none }) else { return }
        let permanently = self.permanently
        guard confirmed(scan, permanently: permanently) else { return }
        let lock: SyncLibrary.RunLock
        do {
            guard let acquired = try SyncLibrary.RunLock() else { return alert("Another sync is running. Try again when it finishes.") }
            lock = acquired
        } catch { return alert(error.localizedDescription) }
        Setup.remember(setup)
        let selectedProfile = profiles.first { $0.id == profileID }
        let runSetup = setup
        var record = SyncLibrary.Record(profileID: selectedProfile?.id, profileName: selectedProfile?.name,
                                        setup: runSetup, started: Date())
        record.conflicts = plan.rows.filter { $0.action == .none && $0.conflict != nil }.count
        record.failures = scan.problems
        let job = Sync.Job(scan, rows: plan.rows, permanently: permanently)
        let progress = ProgressWindow(title: "Syncing “\(scan.left.lastPathComponent)” and “\(scan.right.lastPathComponent)”")
        progress.onCancel = { job.cancel() }
        progress.showSoon()
        syncing = true
        summary.stringValue = "Synchronizing…"
        updateControls()
        job.run(progress: { [weak self] report in
            progress.update(report)
            if let fraction = report.fraction, self?.syncing == true {
                self?.summary.stringValue = "Synchronizing… \(Int(fraction * 100))%"
            }
        }, done: { [weak self] outcome in
            progress.finish()
            record.finish(outcome)
            do {
                try SyncLibrary.append(record)
                if record.status == .success, record.conflicts == 0, let selectedProfile, selectedProfile.setup == runSetup, selectedProfile.pausedReason != nil {
                    try SyncLibrary.advance(selectedProfile, after: Date())
                }
            }
            catch { self?.alert("The sync finished, but its history could not be saved.", info: error.localizedDescription) }
            withExtendedLifetime(lock) {}
            UsageCache.changed(scan.left)
            UsageCache.changed(scan.right)
            if !permanently { FileUndo.record(outcome.changes, name: "Sync") }
            FileOps.report(outcome.failures)
            guard let self else { return }
            self.syncing = false
            var done = [outcome.copied == 1 ? "1 item copied" : "\(Format.count(Int64(outcome.copied))) items copied"]
            if outcome.deleted > 0 { done.append("\(Format.count(Int64(outcome.deleted))) deleted") }
            self.result = (outcome.cancelled ? "Stopped: " : "Done: ") + done.joined(separator: ", ") + "."
            if let after = outcome.scan {
                // Read again with the same comparison once the sync was done.
                self.show(after)
            } else if job.isCancelled {
                // What was compared is out of date; comparing again is up to you.
                self.scan = nil
                self.plan = Sync.Plan()
                self.reloadRows()
                self.updateSummary()
            } else {
                self.runCompare(scan.left, scan.right, by: scan.comparison, excluding: scan.exclusion)
            }
            self.updateControls()
        })
    }

    /// Asks first when a sync would delete all of one side or replace and
    /// delete most of it, and whenever what it removes won't go to the Trash.
    private func confirmed(_ scan: Sync.Scan, permanently: Bool) -> Bool {
        let worries = plan.worries(scan)
        guard !worries.isEmpty || (permanently && plan.removesAnything) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = worries.isEmpty ? "Replace and delete files permanently?" : "This changes most of a folder. Synchronize anyway?"
        alert.informativeText = (worries + [permanently
            ? "Replaced and deleted files won't go to the Trash. This can't be undone."
            : "Replaced and deleted files go to the Trash."]).joined(separator: "\n\n")
        alert.addButton(withTitle: "Synchronize")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Saying what is going on

    private func updateSummary() {
        guard let scan else {
            summary.stringValue = result ?? ""
            summary.textColor = .secondaryLabelColor
            return
        }
        // One pass over the rows, however many there are.
        var toRight = (count: 0, bytes: Int64(0))
        var toLeft = (count: 0, bytes: Int64(0))
        var deletions = 0
        var conflicts = 0
        for row in plan.rows {
            switch row.action {
            case .toRight: toRight = (toRight.count + 1, toRight.bytes + row.bytesToCopy)
            case .toLeft: toLeft = (toLeft.count + 1, toLeft.bytes + row.bytesToCopy)
            case .deleteLeft, .deleteRight: deletions += 1
            case .none: if row.conflict != nil { conflicts += 1 }
            }
        }
        func copies(_ chosen: (count: Int, bytes: Int64), _ way: String) -> String? {
            guard chosen.count > 0 else { return nil }
            return "Copy \(Format.count(Int64(chosen.count))) to the \(way) (\(Format.bytes(chosen.bytes)))"
        }
        var parts = [copies(toRight, "right"), copies(toLeft, "left")].compactMap { $0 }
        if deletions > 0 { parts.append("Delete \(Format.count(Int64(deletions)))\(permanently ? " permanently" : "")") }
        if conflicts > 0 { parts.append(conflicts == 1 ? "1 conflict" : "\(Format.count(Int64(conflicts))) conflicts") }
        let same = plan.equal == 1 ? "1 file the same" : "\(Format.count(Int64(plan.equal))) files the same"
        var text = parts.isEmpty ? "Nothing to sync. \(same)." : parts.joined(separator: "  ·  ") + "  ·  " + same
        if !scan.problems.isEmpty { text += "  ·  \(Format.count(Int64(scan.problems.count))) couldn't be read" }
        if let result { text = result + "  " + text }
        summary.stringValue = text
        summary.textColor = .labelColor
    }

    private func updateControls() {
        let idle = comparing == nil && !syncing
        compareButton.title = comparing == nil ? "Compare" : "Stop"
        compareButton.isEnabled = !syncing && (comparing != nil || (leftField.url != nil && rightField.url != nil))
        syncButton.isEnabled = idle && scan != nil && planShown == planWanted && plan.rows.contains { $0.action != .none }
        // While a sync runs, the window shows the settings it runs with.
        for control in [leftField, rightField, chooseLeft, chooseRight, swapButton, recentButton, comparePopup,
                        excludeField, removalPopup] as [NSControl] {
            control.isEnabled = idle
        }
        if idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        emptyLabel.isHidden = !idle || !visibleIndices.isEmpty || planShown != planWanted
        if scan != nil {
            emptyLabel.stringValue = plan.rows.isEmpty ? "The two folders are in sync." : "No changes match this filter. Choose All changes to see the complete plan."
        } else {
            emptyLabel.stringValue = leftField.url == nil || rightField.url == nil
                ? "Choose the two folders to sync."
                : comparison == .content
                ? "Compare content reads every file that has the same size on both sides, which takes a while for big folders."
                : "Press Compare to see what would change. Nothing is changed until you press Synchronize."
        }
        updateProfileControls(idle: idle)
        syncButton.title = "Synchronize · \(mode.title)"
        let both = mode == .twoWay
        directionButton.setSymbol(both ? "arrow.left.arrow.right" : towardLeft ? "arrow.left" : "arrow.right", iconSize: 20)
        directionButton.isEnabled = idle && !both
        directionButton.toolTip = both ? "Two way sync copies changes in both directions"
            : towardLeft ? "Source: right folder → left folder. Click to reverse."
            : "Source: left folder → right folder. Click to reverse."
        directionButton.setAccessibilityLabel(directionButton.toolTip)
        modeButton.isEnabled = idle
        syncButton.toolTip = "\(modeExplanation) Review the actions before synchronizing."

    }

    private func alert(_ message: String, info: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { visibleIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier, visibleIndices.indices.contains(index) else { return nil }
        let row = plan.rows[visibleIndices[index]]
        let cell = self.cell(id)
        let text = cell.textField
        text?.textColor = .labelColor
        text?.toolTip = nil
        switch id.rawValue {
        case "leftName", "rightName":
            let left = id.rawValue == "leftName"
            let item = left ? row.left : row.right
            text?.stringValue = item == nil ? "" : left ? row.leftPath : row.rightPath
            text?.toolTip = text?.stringValue
            cell.imageView?.image = item.map { icon(row, item: $0) }
        case "leftSize", "rightSize":
            let left = id.rawValue == "leftSize"
            let item = left ? row.left : row.right
            text?.stringValue = item.map { Format.bytes($0.folder ? (left ? row.leftBytes : row.rightBytes) : $0.size) } ?? ""
            text?.alignment = .right
        case "leftDate", "rightDate":
            let item = id.rawValue == "leftDate" ? row.left : row.right
            text?.stringValue = item.map { $0.folder ? "Folder" : Format.date.string(from: Date(timeIntervalSince1970: $0.modified)) } ?? ""
        default:
            let (words, symbol, color) = look(row)
            text?.stringValue = words
            text?.toolTip = words
            text?.textColor = row.action == .none ? color : .labelColor
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: words)
            cell.imageView?.contentTintColor = color
        }
        return cell
    }

    private func cell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = id.rawValue.hasSuffix("Name") ? .byTruncatingMiddle : .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4)
        if id.rawValue.hasSuffix("Name") || id.rawValue == "action" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func icon(_ row: Sync.Row, item: Sync.Item) -> NSImage {
        let folder = item.folder
        let ext = folder ? "/" : (row.name as NSString).pathExtension.lowercased()
        if let known = icons[ext] { return known }
        let type = folder ? UTType.folder : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        icons[ext] = image
        return image
    }

    /// The Action column: a word, a symbol and a colour.
    private func look(_ row: Sync.Row) -> (String, String, NSColor) {
        switch row.action {
        case .toRight, .toLeft:
            let target = row.action == .toRight ? row.right : row.left
            let word = row.isFolderOnly ? "Create folder" : target == nil ? "Copy" : "Replace"
            return (word, row.action == .toRight ? "arrow.right" : "arrow.left", .controlAccentColor)
        case .deleteLeft:
            return ("Delete on the left", "arrow.left.to.line", .systemRed)
        case .deleteRight:
            return ("Delete on the right", "arrow.right.to.line", .systemRed)
        case .none:
            if let conflict = row.conflict { return (conflict, "exclamationmark.triangle.fill", .systemOrange) }
            return (row.note ?? "Don't sync", "minus.circle", .secondaryLabelColor)
        }
    }

    /// The rows a right-click is about: the selection, or the row clicked outside it.
    private var targetRows: [Int] {
        let clicked = table.clickedRow
        if visibleIndices.indices.contains(clicked) && !table.selectedRowIndexes.contains(clicked) { return [visibleIndices[clicked]] }
        return table.selectedRowIndexes.compactMap { visibleIndices.indices.contains($0) ? visibleIndices[$0] : nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = targetRows
        guard !targets.isEmpty, !syncing, comparing == nil, planWanted == planShown else { return }
        let titles = ["Copy to the Right", "Copy to the Left", "Delete on the Left", "Delete on the Right", "Don't Sync"]
        let symbols = ["arrow.right", "arrow.left", "trash", "trash", "minus.circle"]
        for (index, action) in Self.actions.enumerated() {
            let item = NSMenuItem(title: titles[index], action: #selector(setAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            item.isEnabled = targets.contains { plan.rows[$0].choices.contains(action) }
            item.state = targets.allSatisfy { plan.rows[$0].action == action } ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let row = plan.rows[targets[0]]
        for (title, onLeft, present) in [("Show Left in Foldera", true, row.left != nil), ("Show Right in Foldera", false, row.right != nil)] {
            let item = NSMenuItem(title: title, action: #selector(showInFoldera(_:)), keyEquivalent: "")
            item.target = self
            item.tag = onLeft ? 0 : 1
            item.isEnabled = targets.count == 1 && present
            menu.addItem(item)
        }
    }

    @objc private func setAction(_ sender: NSMenuItem) {
        guard sender.tag < Self.actions.count else { return }
        let action = Self.actions[sender.tag]
        let targets = targetRows
        for index in targets where plan.rows[index].choices.contains(action) {
            plan.rows[index].action = action
        }
        reloadRows()
        updateSummary()
        updateControls()
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let index = table.clickedRow
        guard visibleIndices.indices.contains(index) else { return }
        let row = plan.rows[visibleIndices[index]]
        let clickedRight = table.clickedColumn >= 4
        reveal(row, onLeft: clickedRight ? row.right == nil : row.left != nil)
    }

    @objc private func showInFoldera(_ sender: NSMenuItem) {
        guard let index = targetRows.first else { return }
        reveal(plan.rows[index], onLeft: sender.tag == 0)
    }

    private func reveal(_ row: Sync.Row, onLeft: Bool) {
        guard let scan else { return }
        let url = onLeft ? scan.left.appendingPathComponent(row.leftPath) : scan.right.appendingPathComponent(row.rightPath)
        guard FileOps.exists(url) else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(.folder(url.deletingLastPathComponent()), select: [url])
    }

    // MARK: Window

    /// ⌘Z undoes a sync here as in the file list; text fields keep their own.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndo : FileUndo.manager
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshProfiles() }

    func windowWillClose(_ notification: Notification) {
        comparing?.set()
        comparing = nil
        Self.open.removeAll { $0 === self }
    }
}

extension SyncWindow.Setup {
    /// Pairs saved before a setting existed keep the rest of theirs.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        left = try values.decodeIfPresent(String.self, forKey: .left) ?? left
        right = try values.decodeIfPresent(String.self, forKey: .right) ?? right
        mode = try values.decodeIfPresent(Sync.Mode.self, forKey: .mode) ?? mode
        comparison = try values.decodeIfPresent(Sync.Comparison.self, forKey: .comparison) ?? comparison
        permanently = try values.decodeIfPresent(Bool.self, forKey: .permanently) ?? permanently
        towardLeft = try values.decodeIfPresent(Bool.self, forKey: .towardLeft)
        excludes = try values.decodeIfPresent(String.self, forKey: .excludes) ?? excludes
    }
}

/// A folder's path: typed, chosen, or dropped in.
final class FolderField: NSTextField {
    var onDrop: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var url: URL? {
        get {
            let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        }
        set { stringValue = newValue.map(Format.path) ?? "" }
    }

    private func folder(in info: NSDraggingInfo) -> URL? {
        let urls = DragOps.urls(from: info)
        guard urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return urls[0]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folder(in: sender) != nil ? .link : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let folder = folder(in: sender) else { return false }
        url = folder
        onDrop?()
        return true
    }
}
