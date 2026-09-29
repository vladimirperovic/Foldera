import AppKit

/// Closes on Esc, like a Windows dialog.
final class EscWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil) } else { super.keyDown(with: event) }
    }
}

/// The Properties window (⌘I, ⌥↩): what it is, where it is, how big — with
/// folder sizes counted in the background.
final class PropertiesWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindow] = []

    private let urls: [URL]
    private let cancelled = CancelFlag()
    private let sizeValue = PropertiesWindow.value("Calculating…")
    private let diskValue = PropertiesWindow.value("Calculating…")
    private let containsValue = PropertiesWindow.value("Calculating…")

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindow(urls: urls)
        open.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
    }

    private init(urls: [URL]) {
        self.urls = urls
        let window = EscWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.title = urls.count == 1 ? "\(displayName(urls[0])) Properties" : "\(urls.count) items Properties"
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func displayName(_ url: URL) -> String {
        isVolumeRoot(url) ? volumeName(url) : url.lastPathComponent
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private static func value(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 280
        return field
    }

    private func build() {
        guard let window, let content = window.contentView else { return }
        let first = urls[0]
        let single = urls.count == 1
        let values = try? first.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            .isDirectoryKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let volume = single && isVolumeRoot(first)
        let folder = values?.isDirectory == true

        let icon = NSImageView(image: single
            ? NSWorkspace.shared.icon(forFile: first.path)
            : NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = Self.value(single ? displayName(first) : "\(urls.count) items")
        title.font = .boldSystemFont(ofSize: 13)

        var rows: [[NSView]] = [[icon, title], [separator(), NSGridCell.emptyContentView]]
        func row(_ name: String, _ view: NSView) { rows.append([Self.label(name), view]) }
        func row(_ name: String, _ text: String) { row(name, Self.value(text)) }

        if single {
            row("Type:", values?.localizedTypeDescription ?? "")
        } else {
            let kinds = Set(urls.compactMap { try? $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription })
            row("Type:", kinds.count == 1 ? "All of type \(kinds.first!)" : "Multiple types")
        }
        row("Location:", Format.path(first.deletingLastPathComponent()))

        if volume {
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
            rows.append([separator(), NSGridCell.emptyContentView])
            row("Used space:", "\(Format.bytes(total - free))  (\(Format.count(total - free)) bytes)")
            row("Free space:", "\(Format.bytes(free))  (\(Format.count(free)) bytes)")
            row("Capacity:", "\(Format.bytes(total))  (\(Format.count(total)) bytes)")
        } else {
            row("Size:", sizeValue)
            row("Size on disk:", diskValue)
            if folder || !single { row("Contains:", containsValue) }
        }

        if single {
            rows.append([separator(), NSGridCell.emptyContentView])
            let dates: [(String, Date?)] = [
                ("Created:", values?.creationDate), ("Modified:", values?.contentModificationDate),
                ("Accessed:", values?.contentAccessDate),
            ]
            for (name, date) in dates {
                if let date { row(name, DateFormatter.localizedString(from: date, dateStyle: .full, timeStyle: .medium)) }
            }
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 9
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 0).rowAlignment = .none
        for (index, cells) in rows.enumerated() where cells[0] is NSBox {
            grid.row(at: index).mergeCells(in: NSRange(location: 0, length: 2))
            grid.row(at: index).topPadding = 2
            grid.row(at: index).bottomPadding = 2
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        if !volume { measure(countSelf: !single) }
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Adds up everything underneath, updating the numbers as it goes.
    private func measure(countSelf: Bool) {
        let urls = urls
        let flag = cancelled
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
            var size: Int64 = 0
            var disk: Int64 = 0
            var files = 0
            var folders = 0
            // What couldn't be read makes the numbers a lower bound, and says so.
            var unreadable = 0
            var lastUpdate = Date()

            func publish(done: Bool) {
                let (s, d, f, g, u) = (size, disk, files, folders, unreadable)
                DispatchQueue.main.async { self?.show(size: s, disk: d, files: f, folders: g, unreadable: u, done: done) }
            }

            func add(_ url: URL) {
                let v = try? url.resourceValues(forKeys: keys)
                if v?.isDirectory == true && v?.isSymbolicLink != true {
                    folders += 1
                } else {
                    files += 1
                    size += Int64(v?.fileSize ?? 0)
                    disk += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                }
            }

            for url in urls {
                let v = try? url.resourceValues(forKeys: keys)
                guard v?.isDirectory == true && v?.isSymbolicLink != true else {
                    add(url)
                    continue
                }
                if countSelf { folders += 1 }
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in unreadable += 1; return true })
                while let child = walker?.nextObject() as? URL {
                    if flag.isSet { return }
                    add(child)
                    if Date().timeIntervalSince(lastUpdate) > 0.25 {
                        lastUpdate = Date()
                        publish(done: false)
                    }
                }
            }
            if !flag.isSet { publish(done: true) }
        }
    }

    private func show(size: Int64, disk: Int64, files: Int, folders: Int, unreadable: Int, done: Bool) {
        let more = done ? "" : "…"
        let atLeast = unreadable > 0 ? "at least " : ""
        sizeValue.stringValue = "\(atLeast)\(Format.bytes(size))  (\(Format.count(size)) bytes)\(more)"
        diskValue.stringValue = "\(atLeast)\(Format.bytes(disk))  (\(Format.count(disk)) bytes)\(more)"
        var contains = "\(Format.count(Int64(files))) files, \(Format.count(Int64(folders))) folders\(more)"
        if unreadable > 0 {
            contains += "\n\(unreadable == 1 ? "1 folder" : "\(Format.count(Int64(unreadable))) folders") couldn't be read"
        }
        containsValue.stringValue = contains
    }

    func windowWillClose(_ notification: Notification) {
        cancelled.set()
        Self.open.removeAll { $0 === self }
    }
}
