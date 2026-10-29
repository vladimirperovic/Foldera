import AppKit

private struct UIAuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// CI-only overlay compiled into a disposable checkout, never shipped in Foldera.
/// Uses actual controls/event handlers in the running AppKit application.
@MainActor final class FolderaUIAudit {
    let tab: ExplorerTab
    let output: URL
    let fixture: URL
    let scenario: String
    var steps = [[String: Any]]()
    var shots = [String]()
    var menuRecords = [[String: Any]]()
    var observer: NSObjectProtocol?
    var menuChoice: String?

    init(tab: ExplorerTab, output: URL, fixture: URL) {
        self.tab = tab; self.output = output; self.fixture = fixture
        scenario = ProcessInfo.processInfo.environment["FOLDERA_UI_SCENARIO"] ?? "missing"
    }
    func run() {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            fputs("UI audit is restricted to disposable GitHub macOS runners.\n", stderr); exit(2)
        }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [self] note in
            guard let menu = note.object as? NSMenu else { return }
            menuRecords.append(["title": menu.title, "items": menu.items.map { ["title": $0.title, "enabled": $0.isEnabled, "action": $0.action.map(NSStringFromSelector) ?? ""] }])
            // Common-mode timer also runs inside a native menu tracking loop.
            let timer = Timer(timeInterval: 0.35, repeats: false) { [self] _ in
                let chosen = menuChoice
                menuChoice = nil
                menu.cancelTracking()
                if let chosen, let index = menu.items.firstIndex(where: { $0.title == chosen }) {
                    DispatchQueue.main.async { menu.performActionForItem(at: index) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        Task { @MainActor in
            do {
                try await wait("Initial folder listing") { !self.tab.items.isEmpty && !self.tab.waitingForFolder }
                try captureAll("before")
                try await exercise()
                await pause(0.5)
                try captureAll("after")
                finish(error: nil)
            } catch {
                try? captureAll("failure")
                finish(error: error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 38) { [self] in
            try? captureAll("timeout")
            finish(error: UIAuditFailure("UI scenario exceeded 38 seconds; inspect steps/log before blaming app"))
        }
    }
    func pause(_ seconds: Double = 0.25) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        if !condition() { throw UIAuditFailure(reason) }
    }
    func wait(_ reason: String, seconds: Double = 7, _ condition: @escaping () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > until { throw UIAuditFailure("Timed out: " + reason) }
            await pause(0.1)
        }
    }
    func note(_ action: String, _ method: String) { steps.append(["action": action, "method": method, "time": ISO8601DateFormatter().string(from: Date())]) }
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func views(_ window: NSWindow? = nil) -> [NSView] { (window ?? tab.window)?.contentView.map(descendants) ?? [] }
    func button(_ title: String, in window: NSWindow? = nil) throws -> NSButton {
        guard let b = views(window).compactMap({ $0 as? NSButton }).first(where: { $0.title == title && !$0.isHiddenOrHasHiddenAncestor }) else {
            throw UIAuditFailure("Could not find visible native button: " + title)
        }
        return b
    }
    func click(_ button: NSButton) throws {
        try require(button.isEnabled, "Disabled button: " + button.title)
        note(button.title.isEmpty ? (button.identifier?.rawValue ?? "native button") : button.title, "NSButton.performClick on actual UI control")
        button.performClick(nil)
    }
    func click(_ button: ToolButton) throws {
        try require(button.isEnabled, "Disabled toolbar button: " + (button.toolTip ?? "?"))
        try require(!button.isHiddenOrHasHiddenAncestor, "Hidden toolbar button: " + (button.toolTip ?? "?"))
        guard let window = button.window else { throw UIAuditFailure("Toolbar button has no window") }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw UIAuditFailure("Could not create mouse events") }
        note(button.toolTip ?? button.label ?? "toolbar", "ToolButton mouseDown with queued mouseUp, actual wired action")
        NSApp.postEvent(up, atStart: true)
        button.mouseDown(with: down)
    }
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) throws {
        guard let window = window ?? tab.window else { throw UIAuditFailure("No key target window") }
        note("Key \(code) \(characters)", "NSEvent dispatched through NSWindow")
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { window.sendEvent(event) }
        }
    }
    func menu(_ title: String) throws {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title, item.action != nil { return item }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let item = find(main), let action = item.action else { throw UIAuditFailure("Menu item not found: " + title) }
        tab.window?.makeKeyAndOrderFront(nil); tab.focusList()
        note(title, "Actual NSMenuItem dispatched through AppKit responder chain")
        try require(NSApp.sendAction(action, to: item.target, from: item), "Menu action had no responder: " + title)
    }
    func select(_ names: [String]) async throws {
        try await wait("Files listed: " + names.joined(separator: ",")) { Set(names).isSubset(of: Set(self.tab.items.map(\.name))) }
        tab.focusList()
        tab.select(keys: Set(names.map { fixture.appendingPathComponent($0).key }))
        tab.selectionChanged()
        try require(Set(tab.selectedItems.map(\.name)) == Set(names), "Fixture selection mismatch")
        note("Select " + names.joined(separator: ","), "AppKit list selection; setup for tested action")
        await pause()
    }
    func navigate(_ url: URL) async throws {
        // Explicit setup navigation, not counted as a tested address-bar click.
        tab.navigate(to: .folder(url))
        try await wait("Navigate setup") { self.tab.location.url?.key == url.key && !self.tab.waitingForFolder }
        await pause()
    }
    func sheet() async throws -> NSWindow {
        try await wait("Expected sheet") { self.tab.window?.attachedSheet != nil }
        return tab.window!.attachedSheet!
    }
    func nativeField(in window: NSWindow) throws -> NSTextField {
        guard let field = views(window).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && !($0 is NSSearchField) }) else { throw UIAuditFailure("No editable dialog field") }
        return field
    }
    func text(_ value: String, in field: NSTextField) {
        field.stringValue = value
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        if let action = field.action { _ = NSApp.sendAction(action, to: field.target, from: field) }
        note("Type " + value, "Native editable field value + text-change/action notification")
    }
    func exercise() async throws {
        let fm = FileManager.default
        let right = fixture.deletingLastPathComponent().appendingPathComponent("Right")
        if scenario.hasPrefix("layout-") {
            let mode = String(scenario.dropFirst(7))
            switch mode {
            case "details": try click(tab.detailsToggle)
            case "icons": try click(tab.iconsToggle)
            case "columns": try click(tab.columnsToggle)
            case "usage": try click(tab.usageToggle)
            default: throw UIAuditFailure("Unknown layout")
            }
            try require(tab.viewMode.rawValue == mode, "View toggle did not change layout")
            await pause(mode == "usage" ? 1.8 : 0.6)
            return
        }
        switch scenario {
        case "navigation":
            try await select(["Folder A"])
            try key(36, "\r")
            try await wait("Enter opens selected folder") { self.tab.location.url?.lastPathComponent == "Folder A" }
            try click(tab.backButton)
            try await wait("Back") { self.tab.location.url?.key == self.fixture.key }
            try click(tab.forwardButton)
            try await wait("Forward") { self.tab.location.url?.lastPathComponent == "Folder A" }
            try click(tab.upButton)
            try await wait("Up") { self.tab.location.url?.key == self.fixture.key }
            try click(tab.refreshButton)
            try await wait("Refresh preserves listing") { self.tab.items.contains { $0.name == "Reading.md" } }
        case "search":
            text("Reading", in: tab.searchField)
            try await wait("Search filters list") { !self.tab.searchRunning && self.tab.isSearching && self.tab.items.contains { $0.name == "Reading.md" } && !self.tab.items.contains { $0.name == "plain.txt" } }
            try captureAll("filtered")
            text("", in: tab.searchField)
            try await wait("Clear search restores list") { self.tab.items.contains { $0.name == "plain.txt" } }
        case "filters":
            try click(tab.filterButton); try require(tab.showsFilterBar, "Search options did not open")
            try captureAll("open"); try click(tab.filterButton)
            try require(!tab.showsFilterBar, "Search options did not close")
        case "preview-toggle":
            let before = tab.split.arrangedSubviews.contains(tab.previewPane)
            try click(tab.paneButton); await pause()
            try require(tab.split.arrangedSubviews.contains(tab.previewPane) != before, "Preview toggle had no effect")
            try click(tab.paneButton); await pause()
            try require(tab.split.arrangedSubviews.contains(tab.previewPane) == before, "Preview toggle failed round trip")
        case "preview-detach", "preview-edit":
            try await select(["Reading.md"]); await pause(1.5)
            if scenario == "preview-detach" {
                guard let detach = views().compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "preview.detach" }) else { throw UIAuditFailure("Detach button absent") }
                try click(detach)
                try await wait("Detached preview window") { self.tab.previewWindow?.window?.isVisible == true }
                try captureAll("detached")
                try click(detach)
                try await wait("Dock preview") { self.tab.previewWindow == nil && self.tab.previewPane.superview === self.tab.split }
            } else {
                try click(button("Edit")); await pause()
                let done = try button("Done")
                guard let editor = tab.window?.firstResponder as? NSTextView else { throw UIAuditFailure("Markdown editor did not receive focus") }
                editor.insertText("\nUI audit edit\n", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                try click(done)
                try await wait("Done saves Markdown edit") { (try? String(contentsOf: self.fixture.appendingPathComponent("Reading.md"), encoding: .utf8))?.contains("UI audit edit") == true }
            }
        case "two-panes":
            try click(tab.twoPanesButton); await pause()
            try require(tab.host?.partner?.view.window != nil, "Second pane not visible")
            try captureAll("two-panes")
            try click(tab.onePaneButton); await pause()
            try require(tab.host?.partner?.view.window == nil || tab.host?.partner?.view.isHiddenOrHasHiddenAncestor == true, "One-pane button left second pane visible")
        case "tabs":
            guard let host = tab.host else { throw UIAuditFailure("No tab host") }
            let before = host.tabs.count
            guard let plus = views().compactMap({ $0 as? ToolButton }).first(where: { $0.toolTip == "New tab (⌘T)" }) else { throw UIAuditFailure("Tab plus button absent") }
            try click(plus); await pause()
            try require(host.tabs.count == before + 1, "Plus did not create tab")
            host.select(tab)
            try menu("Close Tab"); await pause()
            try require(host.tabs.count == before, "Close Tab did not remove one tab")
        case "new-folder", "new-document":
            try menu(scenario == "new-folder" ? "New Folder" : "New Text Document")
            let name = scenario == "new-folder" ? "New folder" : "New Text Document.txt"
            try await wait("New item appears on disk and list") { fm.fileExists(atPath: self.fixture.appendingPathComponent(name).path) && self.tab.items.contains { $0.name == name } }
            try key(53, "\u{1b}")
        case "rename-inline", "rename-sheet":
            try await select(["plain.txt"])
            if scenario == "rename-sheet" { try click(tab.iconsToggle); await pause(); try await select(["plain.txt"]) }
            try click(tab.renameButton)
            if scenario == "rename-inline" {
                await pause()
                guard let editor = tab.window?.firstResponder as? NSTextView else { throw UIAuditFailure("Inline rename has no field editor") }
                editor.string = "renamed-Čć.txt"
                try key(36, "\r")
            } else {
                let dialog = try await sheet()
                text("renamed-Čć.txt", in: try nativeField(in: dialog))
                try captureAll("rename-dialog")
                try click(button("Rename", in: dialog))
            }
            try await wait("Rename committed to disk") { fm.fileExists(atPath: self.fixture.appendingPathComponent("renamed-Čć.txt").path) && !fm.fileExists(atPath: self.fixture.appendingPathComponent("plain.txt").path) }
        case "copy-paste", "cut-paste", "copy-same":
            try await select(["plain.txt"])
            let move = scenario == "cut-paste"
            try click(move ? tab.cutButton : tab.copyButton)
            try require(FileClipboard.shared.urls.contains { $0.key == fixture.appendingPathComponent("plain.txt").key }, "Clipboard did not receive selected fixture")
            if scenario != "copy-same" { try await navigate(right) }
            try click(tab.pasteButton)
            let target = scenario == "copy-same" ? fixture.appendingPathComponent("plain - Copy.txt") : right.appendingPathComponent("plain.txt")
            try await wait("Paste produces correct bytes", seconds: 10) { (try? String(contentsOf: target, encoding: .utf8)) == "Synthetic UI fixture\n" }
            try require(fm.fileExists(atPath: fixture.appendingPathComponent("plain.txt").path) != move, "Cut/copy source retention wrong")
        case "trash-undo":
            try await select(["plain.txt"]); try click(tab.deleteButton)
            let file = fixture.appendingPathComponent("plain.txt")
            try await wait("Trash removed selected file") { !fm.fileExists(atPath: file.path) }
            try menu("Undo")
            try await wait("Undo restores trashed file") { (try? String(contentsOf: file, encoding: .utf8)) == "Synthetic UI fixture\n" }
        case "properties":
            try await select(["plain.txt"]); try menu("Properties")
            try await wait("Properties window") { NSApp.windows.contains { $0.isVisible && $0.windowController is PropertiesWindow } }
            try captureAll("properties")
            NSApp.windows.first { $0.windowController is PropertiesWindow }?.performClose(nil)
        case "batch-rename":
            try await select(["plain.txt", "second.txt"]); try click(tab.renameButton)
            let dialog = try await sheet()
            guard let field = views(dialog).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "[N]" }) else { throw UIAuditFailure("Batch name field absent") }
            text("qa-[C]", in: field); await pause()
            try captureAll("batch-preview")
            try click(button("Rename", in: dialog))
            try await wait("Batch rename committed") { fm.fileExists(atPath: self.fixture.appendingPathComponent("qa-1.txt").path) && fm.fileExists(atPath: self.fixture.appendingPathComponent("qa-2.txt").path) }
        case "quick-open", "find-command":
            try menu(scenario == "quick-open" ? "Quick Open…" : "Find Command…")
            let dialog = try await sheet()
            try require(dialog.title == "Quick Open", "Wrong Quick Open sheet")
            let fields = views(dialog).compactMap { $0 as? NSSearchField }
            try require(!fields.isEmpty, "Quick Open search control absent")
            try captureAll("quick-open")
            try key(53, "\u{1b}", window: dialog)
            try await wait("Quick Open Escape closes sheet") { self.tab.window?.attachedSheet == nil }
        case "selection":
            try menu("Select All"); await pause()
            try require(tab.selectedItems.count == tab.items.count, "Select All missed items")
            try menu("Invert Selection"); await pause()
            try require(tab.selectedItems.isEmpty, "Invert all did not clear selection")
            try await select(["plain.txt"]); try menu("Select None")
            try require(tab.selectedItems.isEmpty, "Select None failed")
        case "image-viewer":
            try await select(["picture.png"]); try menu("Open")
            try await wait("Image viewer visible") { NSApp.windows.contains { $0 is ViewerWindow && $0.isVisible } }
            try captureAll("viewer")
            let viewer = NSApp.windows.first { $0 is ViewerWindow && $0.isVisible }!
            try key(124, "", window: viewer); await pause()
            try require(viewer.isVisible, "Viewer closed on Next")
            try key(53, "\u{1b}", window: viewer)
        case "sync-window":
            try click(tab.twoPanesButton); await pause()
            tab.host?.partner?.navigate(to: .folder(right)); await pause()
            try click(tab.syncButton)
            try await wait("Sync window visible") { NSApp.windows.contains { $0.isVisible && $0.windowController is SyncWindow } }
            let window = NSApp.windows.first { $0.isVisible && $0.windowController is SyncWindow }!
            try click(button("Compare", in: window))
            try await wait("Sync Compare creates executable plan", seconds: 12) { (window.windowController as? SyncWindow)?.canSynchronize == true }
            try captureAll("sync-compared")
            window.performClose(nil)
        case "new-menu", "sort-menu", "view-menu", "more-menu":
            try await select(["plain.txt"])
            let control = scenario == "new-menu" ? tab.newButton : scenario == "sort-menu" ? tab.sortButton : scenario == "view-menu" ? tab.viewButton : tab.moreButton
            try click(control); await pause()
            try require(!menuRecords.isEmpty, "Toolbar dropdown did not expose a menu (or tracking observer unsupported)")
        case "share-menu":
            try await select(["plain.txt"])
            let beforeMenus = menuRecords.count
            let beforeWindows = NSApp.windows.filter { $0.isVisible }.count
            try click(tab.shareButton); await pause(1)
            try require(menuRecords.count > beforeMenus || NSApp.windows.filter { $0.isVisible }.count > beforeWindows, "Share picker not observable on hosted runner; needs environment/selector review")
            note("Sharing service picker opened; no recipient/service selected", "Native Share control; open/cancel only")
            try key(53, "\u{1b}")
        case "compare-files":
            try await select(["plain.txt", "second.txt"]); try menu("Compare Files")
            await pause(1)
            try require(NSApp.windows.filter { $0.isVisible }.count > 1, "Compare Files did not open another window/sheet")
        case "markdown-editor":
            try await select(["Reading.md"]); try menu("Edit Markdown"); await pause(1)
            try require(NSApp.windows.filter { $0.isVisible }.count > 1, "Edit Markdown did not open editor window")
        case "permanent-delete-cancel":
            try await select(["plain.txt"])
            // runModal enters a nested loop; a common-mode timer cancels the
            // real confirmation and captures it before closing.
            let timer = Timer(timeInterval: 0.4, repeats: false) { [self] _ in
                try? captureAll("delete-confirmation")
                if let window = NSApp.modalWindow, let cancel = try? button("Cancel", in: window) { try? click(cancel) }
            }
            RunLoop.main.add(timer, forMode: .common)
            try menu("Delete Permanently…")
            try require(fm.fileExists(atPath: fixture.appendingPathComponent("plain.txt").path), "Cancel permanently deleted selected file")
        case "archive-browse":
            try await select(["sample.zip"]); try menu("Open")
            try await wait("Archive opened read-only") { self.tab.isInArchive && self.tab.items.contains { $0.name == "inside.txt" } }
            try require(!tab.deleteButton.isEnabled && !tab.cutButton.isEnabled, "Archive exposes enabled destructive buttons")
        default: throw UIAuditFailure("Unknown scenario: " + scenario)
        }
    }
    func inventory(_ window: NSWindow) -> [[String: Any]] {
        guard let root = window.contentView else { return [] }
        return descendants(root).compactMap { view in
            guard view is ToolButton || view is NSControl else { return nil }
            let rectangle = view.convert(view.bounds, to: root)
            let button = view as? ToolButton
            let control = view as? NSControl
            return ["class": String(describing: type(of: view)), "label": button?.toolTip ?? button?.label ?? (view as? NSButton)?.title ?? view.identifier?.rawValue ?? "",
                    "action": button?.action.map(NSStringFromSelector) ?? control?.action.map(NSStringFromSelector) ?? "",
                    "hidden": view.isHiddenOrHasHiddenAncestor, "enabled": button?.isEnabled ?? control?.isEnabled ?? true,
                    "frame": [Double(rectangle.minX), Double(rectangle.minY), Double(rectangle.width), Double(rectangle.height)],
                    "visible_fraction": rectangle.width * rectangle.height > 0 ? max(0, rectangle.intersection(root.bounds).width * rectangle.intersection(root.bounds).height / (rectangle.width * rectangle.height)) : 0]
        }
    }
    func captureAll(_ stage: String) throws {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        for (index, window) in windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let bytes = bitmap.representation(using: .png, properties: [:]) else { continue }
            let name = "\(stage)-\(index).png"
            try bytes.write(to: output.deletingLastPathComponent().appendingPathComponent(name))
            shots.append(name)
        }
        let detail: [[String: Any]] = windows.map { ["title": $0.title, "class": String(describing: type(of: $0)), "controller": $0.windowController.map { String(describing: type(of: $0)) } ?? "", "controls": inventory($0)] }
        try JSONSerialization.data(withJSONObject: detail, options: [.prettyPrinted, .sortedKeys]).write(to: output.deletingLastPathComponent().appendingPathComponent("\(stage)-controls.json"))
    }
    func finish(error: Error?) -> Never {
        let record: [String: Any] = ["scenario": scenario, "status": error == nil ? "passed" : "needs_reproduction", "error": error.map { String(describing: $0) } ?? "", "steps": steps, "screenshots": shots, "menus": menuRecords,
            "method": "CI-only in-process AppKit controls + native events; not external accessibility automation", "gui_assertions_only": true]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.deletingLastPathComponent().appendingPathComponent("result.json"))
        print("UIAUDIT " + scenario + ": " + (error == nil ? "passed" : String(describing: error!)))
        exit(error == nil ? 0 : 1)
    }
}
