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
    }

    private static var open: [SyncWindow] = []
    private static let actions: [Sync.Action] = [.toRight, .toLeft, .deleteLeft, .deleteRight, .none]

    private let leftField = FolderField()
    private let rightField = FolderField()
    private let chooseLeft = NSButton(title: "Choose…", target: nil, action: nil)
    private let chooseRight = NSButton(title: "Choose…", target: nil, action: nil)
    private let swapButton = NSButton()
    private let recentButton = NSButton()
    private let modeControl = NSSegmentedControl()
    private let explanation = NSTextField(labelWithString: "")
    private let comparePopup = NSPopUpButton()
    private let removalPopup = NSPopUpButton()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let syncButton = NSButton(title: "Synchronize", target: nil, action: nil)
    private let textUndo = UndoManager()

    private var scan: Sync.Scan?
    private var plan = Sync.Plan()
    private var comparing: CancelFlag?
    private var syncing = false
    /// What the last Synchronize did, said until you compare again.
    private var result: String?
    private var icons: [String: NSImage] = [:]

    /// The folders chosen: two, one (with the other side it was last synced
    /// with), or none (the pair synced last).
    static func show(_ folders: [URL]) {
        let recent = Setup.recent
        var setup: Setup
        switch folders.count {
        case 0:
            setup = recent.first ?? Setup()
        case 1:
            let key = folders[0].key
            setup = recent.first { $0.left == key || $0.right == key } ?? Setup(left: key)
        default:
            let chosen = Setup(left: folders[0].key, right: folders[1].key)
            setup = recent.first { $0.isPair(chosen) } ?? chosen
        }
        if let existing = open.first(where: { $0.setup.isPair(setup) }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SyncWindow(setup)
        open.append(controller)
        controller.showWindow(nil)
    }

    /// For `--snapshot folder out.png --sync other [--mode mirror]`: the window, compared at once.
    static func showCompared(_ left: URL, _ right: URL, mode: Sync.Mode?, size: NSSize?) {
        let controller = SyncWindow(Setup(left: left.key, right: right.key, mode: mode ?? .twoWay))
        open.append(controller)
        if let size { controller.window?.setContentSize(size) }
        controller.showWindow(nil)
        controller.compare(nil)
    }

    private init(_ setup: Setup) {
        let window = EscWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Sync Folders"
        window.minSize = NSSize(width: 760, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        apply(setup)
        if !window.setFrameAutosaveName("SyncWindow"), let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame SyncWindow") == nil {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }

        for (field, side) in [(leftField, "Left"), (rightField, "Right")] {
            field.placeholderString = "\(side) folder: a path, or drop a folder here"
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
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap sides")
        swapButton.bezelStyle = .rounded
        swapButton.toolTip = "Swap left and right"
        swapButton.target = self
        swapButton.action = #selector(swapSides(_:))
        recentButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Synced before")
        recentButton.bezelStyle = .rounded
        recentButton.toolTip = "Folders synced before"
        recentButton.target = self
        recentButton.action = #selector(showRecent(_:))
        let paths = NSStackView(views: [leftField, chooseLeft, swapButton, rightField, chooseRight, recentButton])
        paths.spacing = 8
        paths.setCustomSpacing(12, after: chooseLeft)
        paths.setCustomSpacing(12, after: swapButton)
        paths.setCustomSpacing(16, after: chooseRight)

        modeControl.segmentCount = Sync.Mode.allCases.count
        modeControl.trackingMode = .selectOne
        let symbols = ["arrow.left.arrow.right", "arrow.right.to.line", "arrow.right"]
        for (index, mode) in Sync.Mode.allCases.enumerated() {
            modeControl.setLabel(mode.title, forSegment: index)
            modeControl.setImage(NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil), forSegment: index)
            modeControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        comparePopup.addItems(withTitles: Sync.Comparison.allCases.map { "Compare \($0.title.lowercased())" })
        comparePopup.toolTip = "How to tell whether two files are the same"
        comparePopup.target = self
        comparePopup.action = #selector(comparisonChanged(_:))
        removalPopup.addItems(withTitles: ["Deleted files to the Trash", "Delete files permanently"])
        removalPopup.toolTip = "Where replaced and deleted files go"
        removalPopup.target = self
        removalPopup.action = #selector(removalChanged(_:))
        let options = NSStackView()
        options.spacing = 8
        options.setViews([modeControl], in: .leading)
        options.setViews([comparePopup, removalPopup], in: .trailing)

        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.lineBreakMode = .byTruncatingTail
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let columns: [(String, String, CGFloat)] = [("name", "Name", 280), ("left", "Left", 215), ("action", "Action", 195), ("right", "Right", 215)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 90
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        rowMenu.autoenablesItems = false
        table.menu = rowMenu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        summary.lineBreakMode = .byTruncatingTail
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        compareButton.target = self
        compareButton.action = #selector(compare(_:))
        compareButton.keyEquivalent = "\r"
        compareButton.toolTip = "See what would change (⌘R)"
        syncButton.target = self
        syncButton.action = #selector(synchronize(_:))
        let bottom = NSStackView()
        bottom.spacing = 8
        bottom.setViews([summary], in: .leading)
        bottom.setViews([spinner, compareButton, syncButton], in: .trailing)

        let stack = NSStackView(views: [paths, options, explanation, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(6, after: options)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(emptyLabel)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ]
        for view in [paths, options, explanation, scroll, bottom] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: Settings

    private var mode: Sync.Mode { Sync.Mode.allCases[max(modeControl.selectedSegment, 0)] }
    private var comparison: Sync.Comparison { Sync.Comparison.allCases[max(comparePopup.indexOfSelectedItem, 0)] }
    private var permanently: Bool { removalPopup.indexOfSelectedItem == 1 }

    private var setup: Setup {
        Setup(left: leftField.url?.key ?? "", right: rightField.url?.key ?? "",
              mode: mode, comparison: comparison, permanently: permanently)
    }

    private func apply(_ setup: Setup) {
        leftField.url = setup.left.isEmpty ? nil : URL(fileURLWithPath: setup.left)
        rightField.url = setup.right.isEmpty ? nil : URL(fileURLWithPath: setup.right)
        modeControl.selectedSegment = Sync.Mode.allCases.firstIndex(of: setup.mode) ?? 0
        comparePopup.selectItem(at: Sync.Comparison.allCases.firstIndex(of: setup.comparison) ?? 0)
        removalPopup.selectItem(at: setup.permanently ? 1 : 0)
        explanation.stringValue = setup.mode.explanation
        foldersChanged()
    }

    /// Whatever was compared is about other folders now.
    private func foldersChanged() {
        comparing?.set()
        comparing = nil
        scan = nil
        plan = Sync.Plan()
        result = nil
        table.reloadData()
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
        explanation.stringValue = mode.explanation
        replan()
    }

    @objc private func comparisonChanged(_ sender: Any?) {
        guard let scan, scan.comparison != comparison else { return }
        foldersChanged()
    }

    @objc private func removalChanged(_ sender: Any?) {
        updateSummary()
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

    @objc private func compare(_ sender: Any?) {
        if let comparing {
            comparing.set()
            return
        }
        guard !syncing, let (left, right) = pair() else { return }
        Setup.remember(setup)
        result = nil
        runCompare(left, right, by: comparison)
    }

    private func runCompare(_ left: URL, _ right: URL, by comparison: Sync.Comparison) {
        let flag = CancelFlag()
        comparing = flag
        scan = nil
        plan = Sync.Plan()
        table.reloadData()
        summary.stringValue = "Reading the folders…"
        updateControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Result {
                try Sync.compare(left, right, by: comparison, cancelled: flag) { text in
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

    private func replan() {
        guard let scan else { return }
        plan = Sync.plan(scan, mode: mode)
        table.reloadData()
        updateSummary()
        updateControls()
    }

    // MARK: Synchronizing

    @objc func synchronize(_ sender: Any?) {
        guard let scan, comparing == nil, !syncing, plan.rows.contains(where: { $0.action != .none }) else { return }
        let permanently = self.permanently
        guard confirmed(scan, permanently: permanently) else { return }
        Setup.remember(setup)
        let job = Sync.Job(left: scan.left, right: scan.right, rows: plan.rows, permanently: permanently)
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
            UsageCache.changed(scan.left)
            UsageCache.changed(scan.right)
            if !permanently { FileUndo.record(outcome.changes, name: "Sync") }
            FileOps.report(outcome.failures)
            guard let self else { return }
            self.syncing = false
            var done = [outcome.copied == 1 ? "1 item copied" : "\(Format.count(Int64(outcome.copied))) items copied"]
            if outcome.deleted > 0 { done.append("\(Format.count(Int64(outcome.deleted))) deleted") }
            self.result = (outcome.cancelled ? "Stopped: " : "Done: ") + done.joined(separator: ", ") + "."
            if scan.comparison == .dateAndSize, let after = outcome.scan {
                self.show(after)
            } else {
                self.runCompare(scan.left, scan.right, by: scan.comparison)
            }
            self.updateControls()
        })
    }

    /// Asks first when a sync would replace or delete most of one side, and
    /// whenever what it replaces or deletes won't go to the Trash.
    private func confirmed(_ scan: Sync.Scan, permanently: Bool) -> Bool {
        var left = 0
        var right = 0
        for row in plan.rows {
            switch row.action {
            case .deleteLeft: left += max(row.leftFiles, 1)
            case .deleteRight: right += max(row.rightFiles, 1)
            case .toLeft where row.left != nil && !row.isFolderOnly: left += max(row.leftFiles, 1)
            case .toRight where row.right != nil && !row.isFolderOnly: right += max(row.rightFiles, 1)
            default: break
            }
        }
        var worries: [String] = []
        for (side, count, total) in [("left", left, scan.leftSide.files), ("right", right, scan.rightSide.files)]
        where count >= 10 && count * 2 > total {
            worries.append("\(Format.count(Int64(count))) of the \(Format.count(Int64(total))) files on the \(side) would be replaced or deleted.")
        }
        guard !worries.isEmpty || (permanently && left + right > 0) else { return true }
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
        let rows = plan.rows
        func copies(_ action: Sync.Action, _ way: String) -> String? {
            let chosen = rows.filter { $0.action == action }
            guard !chosen.isEmpty else { return nil }
            return "Copy \(Format.count(Int64(chosen.count))) to the \(way) (\(Format.bytes(chosen.reduce(0) { $0 + $1.bytesToCopy })))"
        }
        var parts = [copies(.toRight, "right"), copies(.toLeft, "left")].compactMap { $0 }
        let deletions = rows.filter { $0.action == .deleteLeft || $0.action == .deleteRight }.count
        if deletions > 0 { parts.append("Delete \(Format.count(Int64(deletions)))\(permanently ? " permanently" : "")") }
        let conflicts = rows.filter { $0.action == .none && $0.conflict != nil }.count
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
        syncButton.isEnabled = idle && scan != nil && plan.rows.contains { $0.action != .none }
        for control in [leftField, rightField, chooseLeft, chooseRight, swapButton, recentButton, comparePopup] as [NSControl] {
            control.isEnabled = idle
        }
        if idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        emptyLabel.isHidden = !idle || !plan.rows.isEmpty
        if scan != nil {
            emptyLabel.stringValue = "The two folders are in sync."
        } else {
            emptyLabel.stringValue = leftField.url == nil || rightField.url == nil
                ? "Choose the two folders to sync."
                : "Press Compare to see what would change. Nothing is changed until you press Synchronize."
        }
    }

    private func alert(_ message: String, info: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { plan.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier, index < plan.rows.count else { return nil }
        let row = plan.rows[index]
        let cell = self.cell(id)
        let text = cell.textField
        text?.textColor = .labelColor
        text?.toolTip = nil
        switch id.rawValue {
        case "name":
            text?.stringValue = row.name
            text?.toolTip = row.name
            cell.imageView?.image = icon(row)
        case "left":
            text?.stringValue = describe(row.left, files: row.leftFiles, bytes: row.leftBytes, row)
        case "right":
            text?.stringValue = describe(row.right, files: row.rightFiles, bytes: row.rightBytes, row)
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
        text.lineBreakMode = id.rawValue == "name" ? .byTruncatingMiddle : .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4)
        if id.rawValue == "name" || id.rawValue == "action" {
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

    private func icon(_ row: Sync.Row) -> NSImage {
        let folder = (row.left ?? row.right)?.folder == true
        let ext = folder ? "/" : (row.name as NSString).pathExtension.lowercased()
        if let known = icons[ext] { return known }
        let type = folder ? UTType.folder : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        icons[ext] = image
        return image
    }

    /// One side of a row: size and date, or what a folder holds.
    private func describe(_ item: Sync.Item?, files: Int, bytes: Int64, _ row: Sync.Row) -> String {
        guard let item else { return "" }
        guard item.folder else {
            return "\(Format.kilobytes(item.size))    \(Format.date.string(from: Date(timeIntervalSince1970: item.modified)))"
        }
        guard row.whole else { return "Folder" }
        return "\(files == 1 ? "1 file" : "\(Format.count(Int64(files))) files"), \(Format.bytes(bytes))"
    }

    /// The Action column: a word, a symbol and a colour.
    private func look(_ row: Sync.Row) -> (String, String, NSColor) {
        switch row.action {
        case .toRight, .toLeft:
            let target = row.action == .toRight ? row.right : row.left
            let word = row.isFolderOnly ? "Create folder" : target == nil ? "Copy" : "Replace"
            return (word, row.action == .toRight ? "arrow.right" : "arrow.left", .controlAccentColor)
        case .deleteLeft:
            return ("Delete on the left", "trash", .systemRed)
        case .deleteRight:
            return ("Delete on the right", "trash", .systemRed)
        case .none:
            if let conflict = row.conflict { return (conflict, "exclamationmark.triangle.fill", .systemOrange) }
            return (row.note ?? "Don't sync", "minus.circle", .secondaryLabelColor)
        }
    }

    /// The rows a right-click is about: the selection, or the row clicked outside it.
    private var targetRows: [Int] {
        let clicked = table.clickedRow
        if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return [clicked] }
        return table.selectedRowIndexes.filter { $0 < plan.rows.count }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = targetRows
        guard !targets.isEmpty, !syncing, comparing == nil else { return }
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
        table.reloadData(forRowIndexes: IndexSet(targets), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        updateSummary()
        updateControls()
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let index = table.clickedRow
        guard index >= 0, index < plan.rows.count else { return }
        reveal(plan.rows[index], onLeft: plan.rows[index].left != nil)
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

    func windowWillClose(_ notification: Notification) {
        comparing?.set()
        comparing = nil
        Self.open.removeAll { $0 === self }
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
