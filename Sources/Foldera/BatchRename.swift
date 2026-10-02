import AppKit

/// How Rename Many (Ctrl+M, or F2 with several selected) makes the new
/// names: Total Commander's Multi-Rename Tool, the parts used most.
struct RenameRule: Codable, Equatable {
    enum Case: String, Codable, CaseIterable {
        case unchanged, lower, upper, title

        var title: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .lower: return "lowercase"
            case .upper: return "UPPERCASE"
            case .title: return "Title Case"
            }
        }
    }

    /// The name and the extension, made of text and [N] name, [E] extension,
    /// [C] counter, [D] date modified, [P] the folder it is in.
    var name = "[N]"
    var ext = "[E]"
    /// Then replaced in the whole name, ignoring case (or as a regular expression).
    var find = ""
    var replace = ""
    var regex = false
    var caseChange = Case.unchanged
    var start = 1
    var step = 1
    var digits = 1

    static var saved: RenameRule {
        get { UserDefaults.standard.data(forKey: "renameRule").flatMap { try? JSONDecoder().decode(RenameRule.self, from: $0) } ?? RenameRule() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "renameRule") }
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The new name for the `index`th of the items, counting from 0.
    func newName(for item: FileItem, index: Int, regex compiled: NSRegularExpression? = nil) -> String {
        let oldExt = item.isFolder ? "" : item.url.pathExtension
        let stem = oldExt.isEmpty ? item.name : String(item.name.dropLast(oldExt.count + 1))
        let counter = start + index * step
        let values = [
            "N": stem, "E": oldExt,
            "C": digits > 1 ? String(format: "%0\(digits)ld", counter) : String(counter),
            "D": item.modified.map(Self.dateFormat.string(from:)) ?? "",
            "P": item.url.deletingLastPathComponent().lastPathComponent,
        ]
        /// Tokens in square brackets filled in; anything else stays as written.
        func fill(_ template: String) -> String {
            var out = ""
            var rest = Substring(template)
            while let open = rest.firstIndex(of: "[") {
                out.append(contentsOf: rest[..<open])
                let after = rest[rest.index(after: open)...]
                if let close = after.firstIndex(of: "]"), let value = values[after[..<close].uppercased()] {
                    out += value
                    rest = after[after.index(after: close)...]
                } else {
                    out += "["
                    rest = after
                }
            }
            out.append(contentsOf: rest)
            return out
        }
        let newStem = fill(name)
        let newExt = fill(ext)
        var full = newExt.isEmpty ? newStem : newStem + "." + newExt
        if !find.isEmpty {
            if regex {
                if let compiled {
                    full = compiled.stringByReplacingMatches(in: full, range: NSRange(full.startIndex..., in: full), withTemplate: replace)
                }
            } else {
                full = full.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
            }
        }
        switch caseChange {
        case .unchanged: break
        case .lower: full = full.lowercased()
        case .upper: full = full.uppercased()
        case .title:
            // The name, not the extension: "Holiday In Rome.jpg".
            let ext = item.isFolder ? "" : (full as NSString).pathExtension
            full = ext.isEmpty ? full.capitalized : ((full as NSString).deletingPathExtension.capitalized + "." + ext)
        }
        return full.trimmingCharacters(in: .whitespaces)
    }
}

enum BatchRename {
    struct Row {
        let item: FileItem
        let newName: String
        /// Why it can't be renamed so; nothing is renamed while any row has one.
        var problem: String?

        var changes: Bool { newName != item.name }
        var target: URL { item.url.deletingLastPathComponent().appendingPathComponent(newName) }
    }

    /// The new names, and what stands in their way: a name that can't be,
    /// two items given one name, or a name already taken by something else.
    /// Names are compared ignoring case, as most Mac drives do.
    static func rows(for items: [FileItem], rule: RenameRule) -> [Row] {
        var compiled: NSRegularExpression?
        if rule.regex && !rule.find.isEmpty {
            compiled = try? NSRegularExpression(pattern: rule.find)
            if compiled == nil {
                return items.map { Row(item: $0, newName: $0.name, problem: "The text to find isn't a valid regular expression") }
            }
        }
        var rows = items.enumerated().map { index, item in
            Row(item: item, newName: rule.newName(for: item, index: index, regex: compiled), problem: nil)
        }
        let sources = Set(items.map { $0.key.lowercased() })
        // Names that stay where they are, and how many items want each new one.
        let staying = Set(rows.filter { !$0.changes }.map { $0.item.key.lowercased() })
        var wanted: [String: Int] = [:]
        for row in rows where row.changes { wanted[row.target.key.lowercased(), default: 0] += 1 }
        for i in rows.indices where rows[i].changes {
            let name = rows[i].newName
            let target = rows[i].target
            let key = target.key.lowercased()
            if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") {
                rows[i].problem = "Not a name a file can have"
            } else if wanted[key, default: 0] > 1 {
                rows[i].problem = "Two items would get this name"
            } else if staying.contains(key) && key != rows[i].item.key.lowercased() {
                rows[i].problem = "Another selected item keeps this name"
            } else if !sources.contains(key) && FileOps.exists(target) && !FileOps.isSameItem(target, rows[i].item.url) {
                rows[i].problem = "Something by this name is already there"
            }
        }
        return rows
    }

    /// Renames on the calling thread. When a new name is one another item of
    /// the batch is giving up, every item goes by way of a temporary name,
    /// so swaps work. An item whose second step fails gets its old name back.
    static func perform(_ rows: [Row]) -> (changes: [Change], failures: [String]) {
        let moving = rows.filter { $0.changes && $0.problem == nil }
        let sources = Set(moving.map { $0.item.key.lowercased() })
        let viaTemporary = moving.contains {
            let key = $0.target.key.lowercased()
            return key != $0.item.key.lowercased() && sources.contains(key)
        }
        var changes: [Change] = []
        var failures: [String] = []
        guard viaTemporary else {
            for row in moving {
                do {
                    let renamed = try FileOps.rename(row.item.url, to: row.newName)
                    changes.append(.moved(from: row.item.url, to: renamed))
                } catch {
                    failures.append("“\(row.item.name)”: \(error.localizedDescription)")
                }
            }
            return (changes, failures)
        }
        var parked: [(row: Row, temporary: URL, change: Int)] = []
        let batch = UUID().uuidString
        for (index, row) in moving.enumerated() {
            do {
                let temporary = try FileOps.rename(row.item.url, to: ".foldera-rename-\(batch)-\(index)")
                changes.append(.moved(from: row.item.url, to: temporary))
                parked.append((row, temporary, changes.count - 1))
            } catch {
                failures.append("“\(row.item.name)”: \(error.localizedDescription)")
            }
        }
        var takenBack = IndexSet()
        for entry in parked {
            do {
                let renamed = try FileOps.rename(entry.temporary, to: entry.row.newName)
                changes.append(.moved(from: entry.temporary, to: renamed))
            } catch {
                failures.append("“\(entry.row.item.name)”: \(error.localizedDescription)")
                if (try? FileOps.rename(entry.temporary, to: entry.row.item.name)) != nil {
                    takenBack.insert(entry.change)
                } else {
                    failures.append("“\(entry.row.item.name)” was left named “\(entry.temporary.lastPathComponent)”.")
                }
            }
        }
        return (changes.enumerated().filter { !takenBack.contains($0.offset) }.map(\.element), failures)
    }
}

/// The Rename Many sheet: the rule above, and every old and new name side
/// by side, updated as you type.
final class BatchRenameSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var current: BatchRenameSheet?

    private let items: [FileItem]
    private var rows: [BatchRename.Row] = []
    private let done: ([BatchRename.Row]) -> Void

    private let nameField = NSTextField()
    private let extField = NSTextField()
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexBox = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let casePopup = NSPopUpButton()
    private let startField = NSTextField()
    private let stepField = NSTextField()
    private let digitsField = NSTextField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)

    static func begin(_ items: [FileItem], on parent: NSWindow, done: @escaping ([BatchRename.Row]) -> Void) {
        let sheet = BatchRenameSheet(items: items, done: done)
        guard let window = sheet.window else { return }
        current = sheet
        parent.beginSheet(window) { _ in current = nil }
        window.makeFirstResponder(sheet.nameField)
    }

    private init(items: [FileItem], done: @escaping ([BatchRename.Row]) -> Void) {
        self.items = items
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        build()
        show(RenameRule.saved)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Rename \(Format.items(items.count))")
        title.font = .boldSystemFont(ofSize: 13)
        for field in [nameField, extField, findField, replaceField, startField, stepField, digitsField] {
            field.delegate = self
        }
        nameField.placeholderString = "[N]"
        extField.placeholderString = "[E]"
        findField.placeholderString = "Text to find"
        replaceField.placeholderString = "Replace with"
        for field in [startField, stepField, digitsField] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        for field in [extField, replaceField] { field.widthAnchor.constraint(equalToConstant: 170).isActive = true }
        regexBox.target = self
        regexBox.action = #selector(changed(_:))
        for option in RenameRule.Case.allCases {
            casePopup.addItem(withTitle: option.title)
            casePopup.lastItem?.representedObject = option.rawValue
        }
        casePopup.target = self
        casePopup.action = #selector(changed(_:))

        let tokens = NSTextField(labelWithString: "[N] name    [E] extension    [C] counter    [D] date modified    [P] folder")
        tokens.font = .systemFont(ofSize: 11)
        tokens.textColor = .secondaryLabelColor
        let empty = { NSGridCell.emptyContentView }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField, NSTextField(labelWithString: "Extension:"), extField],
            [empty(), tokens, empty(), empty()],
            [NSTextField(labelWithString: "Find:"), findField, NSTextField(labelWithString: "Replace:"), replaceField],
            [empty(), regexBox, empty(), empty()],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        grid.row(at: 1).mergeCells(in: NSRange(location: 1, length: 3))
        grid.row(at: 3).mergeCells(in: NSRange(location: 1, length: 3))
        grid.columnSpacing = 8
        grid.rowSpacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let options = NSStackView(views: [
            NSTextField(labelWithString: "Case:"), casePopup, spacer,
            NSTextField(labelWithString: "Counter starts at"), startField,
            NSTextField(labelWithString: "step"), stepField,
            NSTextField(labelWithString: "digits"), digitsField,
        ])
        options.spacing = 6

        for (id, heading) in [("old", "Name now"), ("new", "New name")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = heading
            column.width = 330
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.target = self
        renameButton.action = #selector(rename(_:))
        renameButton.keyEquivalent = "\r"
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [summary, gap, cancel, renameButton])

        let stack = NSStackView(views: [title, grid, options, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view in [grid, options, scroll, footer] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    private func show(_ rule: RenameRule) {
        nameField.stringValue = rule.name
        extField.stringValue = rule.ext
        findField.stringValue = rule.find
        replaceField.stringValue = rule.replace
        regexBox.state = rule.regex ? .on : .off
        casePopup.selectItem(at: RenameRule.Case.allCases.firstIndex(of: rule.caseChange) ?? 0)
        startField.stringValue = String(rule.start)
        stepField.stringValue = String(rule.step)
        digitsField.stringValue = String(rule.digits)
    }

    /// What the fields say; an empty name or extension field means as it was.
    private func readRule() -> RenameRule {
        var rule = RenameRule()
        rule.name = nameField.stringValue.isEmpty ? "[N]" : nameField.stringValue
        rule.ext = extField.stringValue.isEmpty ? "[E]" : extField.stringValue
        rule.find = findField.stringValue
        rule.replace = replaceField.stringValue
        rule.regex = regexBox.state == .on
        rule.caseChange = RenameRule.Case(rawValue: casePopup.selectedItem?.representedObject as? String ?? "") ?? .unchanged
        rule.start = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        rule.step = Int(stepField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        rule.digits = min(max(Int(digitsField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1, 1), 9)
        return rule
    }

    private func update() {
        rows = BatchRename.rows(for: items, rule: readRule())
        table.reloadData()
        let changing = rows.filter(\.changes).count
        let problems = rows.filter { $0.problem != nil }.count
        if problems > 0 {
            summary.stringValue = problems == 1 ? "1 item can't be renamed this way" : "\(Format.count(Int64(problems))) items can't be renamed this way"
            summary.textColor = .systemRed
        } else {
            summary.stringValue = changing == 0 ? "No name changes yet" : "\(Format.count(Int64(changing))) of \(Format.items(items.count)) will be renamed"
            summary.textColor = .secondaryLabelColor
        }
        renameButton.isEnabled = problems == 0 && changing > 0
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    @objc private func changed(_ sender: Any?) { update() }

    @objc private func cancel(_ sender: Any?) { finish() }

    @objc private func rename(_ sender: Any?) {
        let rule = readRule()
        // The disk looked at once more, right before.
        rows = BatchRename.rows(for: items, rule: rule)
        guard !rows.contains(where: { $0.problem != nil }), rows.contains(where: \.changes) else { return update() }
        RenameRule.saved = rule
        let chosen = rows
        let done = self.done
        finish()
        done(chosen)
    }

    private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
    }

    // MARK: The names

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
        }
        let entry = rows[row]
        if id.rawValue == "old" {
            field.stringValue = entry.item.name
            field.textColor = .secondaryLabelColor
            field.toolTip = nil
        } else {
            field.stringValue = entry.problem.map { "\(entry.newName)   — \($0)" } ?? entry.newName
            field.textColor = entry.problem != nil ? .systemRed : (entry.changes ? .labelColor : .secondaryLabelColor)
            field.toolTip = entry.problem
        }
        return field
    }
}

extension ExplorerTab {
    /// Several items renamed at once, by a pattern (Ctrl+M as in Total
    /// Commander, or F2 with more than one selected). ⌘Z undoes all of it.
    @objc func renameMany(_ sender: Any?) {
        let chosen = selectedItems.filter { $0.volume == nil }
        guard chosen.count > 1, !isInArchive, let window, window.attachedSheet == nil else { return }
        BatchRenameSheet.begin(chosen, on: window) { [weak self] rows in self?.performRename(rows) }
    }

    private func performRename(_ rows: [BatchRename.Row]) {
        let progress = ProgressWindow(title: "Renaming \(Format.items(rows.filter(\.changes).count))")
        progress.update(text: "")
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (changes, failures) = BatchRename.perform(rows)
            DispatchQueue.main.async {
                progress.finish()
                FileUndo.record(changes, name: "Rename")
                FileOps.report(failures)
                guard let self else { return }
                self.pendingSelection = Set(changes.compactMap { change -> String? in
                    guard case let .moved(_, to) = change, !to.lastPathComponent.hasPrefix(".foldera-rename-") else { return nil }
                    return to.key
                })
                self.scrollToSelection = true
                if self.isSearching { self.runSearch() } else { self.load() }
            }
        }
    }
}
