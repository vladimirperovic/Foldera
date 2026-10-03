import AppKit

final class SyncHistoryWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: SyncHistoryWindow?
    private let table = NSTableView()
    private let details = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Sync", target: nil, action: nil)
    private var records: [SyncLibrary.Record] = []
    private var observer: NSObjectProtocol?

    static func show() {
        if let current { current.reload(); current.showWindow(nil); return }
        let controller = SyncHistoryWindow()
        current = controller
        controller.showWindow(nil)
    }

    private init() {
        let window = EscWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 580),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sync History"
        window.minSize = NSSize(width: 720, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let column = NSTableColumn(identifier: .init("run"))
        column.title = "Recent sync runs"
        column.width = 315
        table.addTableColumn(column)
        table.rowHeight = 52
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        let detail = NSScrollView()
        detail.documentView = details
        detail.hasVerticalScroller = true
        details.isEditable = false
        details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.textContainerInset = NSSize(width: 12, height: 12)
        details.autoresizingMask = [.width]
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.textContainer?.widthTracksTextView = true
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshHistory(_:)))
        openButton.target = self
        openButton.action = #selector(openSync(_:))
        for button in [refresh, openButton] { button.bezelStyle = .rounded }
        let bottom = NSStackView()
        bottom.setViews([status], in: .leading)
        bottom.setViews([refresh, openButton], in: .trailing)
        bottom.spacing = 8
        let stack = NSStackView(views: [split, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
                bottom.widthAnchor.constraint(equalTo: split.widthAnchor),
                list.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
                detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            ])
            content.layoutSubtreeIfNeeded()
            split.setPosition(315, ofDividerAt: 0)
        }
        window.center()
        observer = NotificationCenter.default.addObserver(forName: SyncLibrary.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private var selected: SyncLibrary.Record? { records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil }
    private func reload() {
        let chosen = selected?.id
        do {
            records = try SyncLibrary.records()
            table.reloadData()
            if !records.isEmpty {
                table.selectRowIndexes(IndexSet(integer: chosen.flatMap { id in records.firstIndex { $0.id == id } } ?? 0), byExtendingSelection: false)
            }
            status.stringValue = records.isEmpty ? "No sync runs yet." : records.count == 1 ? "1 recent run" : "\(records.count) most recent runs"
            showDetails()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func refreshHistory(_ sender: Any?) { reload() }
    @objc private func openSync(_ sender: Any?) {
        guard let selected else { return }
        let current = try? SyncLibrary.profiles().first { $0.id == selected.profileID && $0.setup == selected.setup }
        SyncWindow.showSetup(selected.setup, profileID: current?.id)
    }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
    func windowWillClose(_ notification: Notification) { Self.current = nil }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        let field = NSTextField(wrappingLabelWithString: "\(record.profileName ?? "Manual sync") · \(record.automatic ? "Scheduled" : "Manual")\n\(Format.date.string(from: record.started)) · \(record.summary)")
        field.font = .systemFont(ofSize: 11)
        field.maximumNumberOfLines = 3
        field.textColor = record.status == .failed ? .systemRed : record.status == .needsReview ? .systemOrange : .labelColor
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showDetails() }
    private func showDetails() {
        openButton.isEnabled = selected != nil
        guard let record = selected else { details.string = "Run a synchronization to see its result here."; return }
        let direction = record.setup.mode == .twoWay ? "Both directions" : record.setup.towardLeft == true ? "Right → Left" : "Left → Right"
        var lines = [record.profileName ?? "Manual sync", "\(record.automatic ? "Scheduled" : "Manual") · \(record.summary)",
                     "Started: \(Format.date.string(from: record.started))", "Finished: \(Format.date.string(from: record.finished))",
                     "\(record.setup.mode.title) · \(direction)", "Comparison: \(record.setup.comparison.title)",
                     "Removed files: \(record.setup.permanently ? "Deleted permanently" : "Moved to Trash")", "Left: \(record.setup.left)", "Right: \(record.setup.right)"]
        if record.conflicts > 0 { lines.append("Conflicts: \(record.conflicts)") }
        if !record.failures.isEmpty { lines += ["", "Errors / review:"] + record.failures }
        if !record.events.isEmpty {
            lines += ["", "Actions:"] + record.events.map { "\($0.action)  \($0.path)\($0.error.map { " — \($0)" } ?? "")" }
        }
        details.string = lines.joined(separator: "\n")
        details.scrollToBeginningOfDocument(nil)
    }
}

/// The schedule editor is kept separate from the Sync window's folder controls.
final class SyncScheduleEditor: NSStackView {
    let frequency = NSPopUpButton()
    let time = NSDatePicker()
    let weekday = NSPopUpButton()
    init(_ schedule: SyncLibrary.Schedule) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 155))
        orientation = .vertical
        alignment = .leading
        spacing = 10
        frequency.addItems(withTitles: SyncLibrary.Schedule.Frequency.allCases.map(\.title))
        frequency.selectItem(at: SyncLibrary.Schedule.Frequency.allCases.firstIndex(of: schedule.frequency) ?? 0)
        frequency.target = self
        frequency.action = #selector(changed(_:))
        time.datePickerElements = [.hourMinute]
        time.datePickerStyle = .textFieldAndStepper
        time.dateValue = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: schedule.hour, minute: schedule.minute)) ?? Date()
        weekday.addItems(withTitles: Calendar.current.weekdaySymbols)
        weekday.selectItem(at: min(max(schedule.weekday - 1, 0), 6))
        addArrangedSubview(frequency)
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "At"), time, weekday]))
        let info = NSTextField(wrappingLabelWithString: "Runs in the background, even when Foldera is closed. Missed runs resume after login or wake. Conflicts and changes needing confirmation wait for review in History.")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        addArrangedSubview(info)
        info.widthAnchor.constraint(equalToConstant: 420).isActive = true
        changed(nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    var schedule: SyncLibrary.Schedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time.dateValue)
        return .init(frequency: SyncLibrary.Schedule.Frequency.allCases[max(frequency.indexOfSelectedItem, 0)],
                     hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekday: weekday.indexOfSelectedItem + 1)
    }
    @objc private func changed(_ sender: Any?) {
        let selected = schedule.frequency
        time.isEnabled = selected == .daily || selected == .weekly
        weekday.isEnabled = selected == .weekly
    }
}

final class SyncProfilesMenu: NSObject, NSMenuDelegate {
    static let shared = SyncProfilesMenu()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        do {
            let profiles = try SyncLibrary.profiles()
            for profile in profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(openProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id.uuidString
                item.toolTip = profile.schedule.title
                menu.addItem(item)
            }
            if profiles.isEmpty {
                let item = NSMenuItem(title: "Save a profile in the Sync window", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } catch {
            let item = NSMenuItem(title: "Profiles could not be read", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }
    @objc private func openProfile(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let id = UUID(uuidString: raw),
              let profile = try? SyncLibrary.profiles().first(where: { $0.id == id }) else { return }
        SyncWindow.showSetup(profile.setup, profileID: id)
    }
}
