import AppKit
import Quartz

/// Everything a window can be asked to do, from the command bar, the menus,
/// the right-click menu and the keyboard.
extension ExplorerTab: NSMenuItemValidation {
    var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: Navigation

    @objc func goBack(_ sender: Any?) {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(location)
        navigate(to: target, record: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(location)
        navigate(to: target, record: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard let parent = parentLocation else { return }
        // Leaving an archive's top folder lands on the archive itself.
        if let archive = archiveContext, archive.root.key == location.url?.key {
            navigate(to: parent, select: [archive.archive])
        } else {
            navigate(to: parent)
        }
    }

    @objc func refresh(_ sender: Any?) {
        if shownMode == .usage { return showUsage(force: true) }
        if Prefs.folderSizes, let url = location.url { UsageCache.forget(url) }
        reload()
    }

    @objc func toggleFolderSizes(_ sender: Any?) { Prefs.folderSizes.toggle() }

    /// A folder's disk usage, in a tab of its own (or here, for the folder on screen).
    @objc func analyzeDiskUsage(_ sender: Any?) {
        let chosen = selectedItems
        let target = chosen.count == 1 ? folderTarget(of: chosen[0]) : (chosen.isEmpty ? location.url : nil)
        guard let target else { return }
        if target.key == location.url?.key {
            setViewMode(.usage)
        } else {
            appDelegate?.openWindow(.folder(target), tabbedWith: window).setViewMode(.usage)
        }
    }

    /// Go menu places, by tag.
    @objc func goToPlace(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch sender.tag {
        case 1: navigate(to: .folder(home.appendingPathComponent("Desktop")))
        case 2: navigate(to: .folder(home.appendingPathComponent("Documents")))
        case 3: navigate(to: .folder(home.appendingPathComponent("Downloads")))
        case 4: navigate(to: .folder(URL(fileURLWithPath: "/Applications")))
        case 5: navigate(to: .thisMac)
        default: navigate(to: .folder(home))
        }
        focusList()
    }

    @objc func focusAddress(_ sender: Any?) {
        addressBar.beginEditing()
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Opening

    /// Where an item leads when opened, if it is something to walk into.
    func folderTarget(of item: FileItem) -> URL? {
        if item.volume != nil { return item.url }
        if item.isFolder { return item.isSymlink ? item.url.resolvingSymlinksInPath() : item.url }
        if item.isAlias, let target = try? URL(resolvingAliasFileAt: item.url), FileOps.isFolder(target) { return target }
        return nil
    }

    @objc func openSelection(_ sender: Any?) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        if chosen.count == 1, let folder = folderTarget(of: chosen[0]) {
            navigate(to: .folder(folder))
            return
        }
        if chosen.count == 1, Prefs.browseArchives, ArchiveFolders.isArchive(chosen[0].url) {
            openArchive(chosen[0].url)
            return
        }
        if Prefs.imageViewer && openInViewer(chosen) { return }
        for item in chosen {
            if let folder = folderTarget(of: item) {
                appDelegate?.openWindow(.folder(folder), tabbedWith: window)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private func isPicture(_ item: FileItem) -> Bool { !item.isFolder && ImageFiles.isImage(item.url) }

    /// One picture opens with the list's other pictures around it, in the
    /// order they are listed; several selected pictures open on their own.
    @discardableResult
    func openInViewer(_ chosen: [FileItem]) -> Bool {
        guard !chosen.isEmpty, chosen.allSatisfy(isPicture) else { return false }
        if chosen.count == 1 {
            let pictures = items.filter(isPicture).map(\.url)
            ImageViewer.show(pictures, at: pictures.firstIndex { $0.key == chosen[0].key } ?? 0)
        } else {
            ImageViewer.show(chosen.map(\.url), at: 0)
        }
        return true
    }

    @objc func viewPictures(_ sender: Any?) {
        openInViewer(selectedItems)
    }

    @objc func tableDoubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        openSelection(sender)
    }

    private var foldersToOpen: [URL] {
        let folders = selectedItems.compactMap(folderTarget(of:))
        if !folders.isEmpty { return folders }
        return location.url.map { [$0] } ?? []
    }

    @objc func openInNewTab(_ sender: Any?) {
        let folders = foldersToOpen
        if folders.isEmpty, location == .thisMac { appDelegate?.openWindow(.thisMac, tabbedWith: window) }
        for folder in folders { appDelegate?.openWindow(.folder(folder), tabbedWith: window) }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        let folders = foldersToOpen
        if folders.isEmpty { appDelegate?.openWindow(location) }
        for folder in folders { appDelegate?.openWindow(.folder(folder)) }
    }

    @objc func openFileLocation(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        navigate(to: .folder(item.url.deletingLastPathComponent()), select: [item.url])
        focusList()
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(urls[0].lastPathComponent)”"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let preferred {
            apps.removeAll { $0 == preferred }
            apps.insert(preferred, at: 0)
        }
        for (i, app) in apps.prefix(30).enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if i == 0 && preferred != nil { title += " (default)" }
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.image = menuIcon(NSWorkspace.shared.icon(forFile: app.path))
            menu.addItem(item)
            if i == 0 && preferred != nil && apps.count > 1 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(item("Choose Another App…", nil, #selector(openWithOther(_:))))
        return menu
    }

    // MARK: Making, moving and removing

    @objc func newFolder(_ sender: Any?) {
        guard let folder = currentFolder else { return }
        do {
            renameNewItem(try FileOps.makeFolder(in: folder), undoName: "New Folder")
        } catch {
            show(error)
        }
    }

    @objc func newTextDocument(_ sender: Any?) {
        guard let folder = currentFolder else { return }
        do {
            renameNewItem(try FileOps.makeTextFile(in: folder), undoName: "New Text Document")
        } catch {
            show(error)
        }
    }

    /// Something new appears selected with its name ready to type, as in Windows.
    private func renameNewItem(_ url: URL, undoName: String) {
        FileUndo.record([.created(url)], name: undoName)
        pendingSelection = [url.key]
        scrollToSelection = true
        renameAfterLoad = url.key
        load()
    }

    @objc func cut(_ sender: Any?) { putOnClipboard(cut: true) }
    @objc func copy(_ sender: Any?) { putOnClipboard(cut: false) }

    private func putOnClipboard(cut: Bool) {
        let urls = selectedItems.filter { $0.volume == nil }.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.put(urls, cut: cut)
    }

    @objc func paste(_ sender: Any?) {
        let clipboard = FileClipboard.shared
        let urls = clipboard.urls
        guard let folder = currentFolder, !urls.isEmpty else { return }
        let move = urls.contains { clipboard.isCut($0.key) }
        transfer(urls, into: folder, move: move) { if move { clipboard.clearCut() } }
    }

    /// ⌥⌘V, Finder's way of saying "move here".
    @objc func pasteMove(_ sender: Any?) {
        let urls = FileClipboard.shared.urls
        guard let folder = currentFolder, !urls.isEmpty else { return }
        transfer(urls, into: folder, move: true) { FileClipboard.shared.clearCut() }
    }

    /// Copy or move with Windows' questions first, then a progress window
    /// that can be cancelled. Undo takes all of it back.
    func transfer(_ urls: [URL], into folder: URL, move requested: Bool, then: (() -> Void)? = nil) {
        guard !ArchiveFolders.isInside(folder) else { return FileOps.report(["An opened archive is read-only. Extract it to add to it."]) }
        // What comes out of an opened archive is always a copy; the archive stays as it is.
        let move = requested && !urls.contains(where: ArchiveFolders.isInside)
        guard let plan = Transfer.plan(urls, into: folder, move: move, ask: Transfer.askWithAlert) else { return }
        FileOps.report(plan.problems)
        guard !plan.steps.isEmpty || (move && !plan.emptied.isEmpty) else {
            then?()
            return
        }
        let verb = move ? "Moving" : "Copying"
        let job = Transfer(plan: plan, move: move)
        let progress = ProgressWindow(title: "\(verb) \(Format.items(plan.steps.count)) to “\(folder.lastPathComponent)”")
        progress.onCancel = { job.cancel() }
        progress.showSoon()
        busyText = "\(verb)…"
        updateStatus()
        job.run(progress: { [weak self] report in
            progress.update(report)
            if let fraction = report.fraction {
                self?.busyText = "\(verb)… \(Int(fraction * 100))%"
                self?.updateStatus()
            }
        }, done: { [weak self] outcome in
            progress.finish()
            // Folders measured before now hold more (or less).
            UsageCache.changed(folder)
            if move { urls.forEach { UsageCache.changed($0.deletingLastPathComponent()) } }
            FileUndo.record(outcome.changes, name: move ? "Move" : "Copy")
            FileOps.report(outcome.failures)
            then?()
            guard let self else { return }
            self.busyText = nil
            if folder.key == self.currentFolder?.key || folder.key == self.location.url?.key {
                self.pendingSelection = Set(outcome.made.map(\.key))
                self.scrollToSelection = true
                self.load()
            } else {
                self.updateStatus()
            }
        })
    }

    private var deletableItems: [FileItem] { isInArchive ? [] : selectedItems.filter { $0.volume == nil } }

    /// The item to select once `gone` has disappeared: the next one down, or the one above.
    private func neighbour(of gone: [FileItem]) -> String? {
        let keys = Set(gone.map(\.key))
        guard let last = items.lastIndex(where: { keys.contains($0.key) }) else { return nil }
        if let next = items[(last + 1)...].first(where: { !keys.contains($0.key) }) { return next.key }
        return items[..<last].last(where: { !keys.contains($0.key) })?.key
    }

    /// After a delete: what failed to go stays on screen.
    private func removed(_ chosen: [FileItem], only removedURLs: [URL]) {
        let keys = Set(removedURLs.map(\.key))
        let gone = chosen.filter { keys.contains($0.key) }
        guard !gone.isEmpty else { return }
        if shownMode == .usage {
            // The displayed tree is still alive even after its cache entry is invalidated.
            for item in gone { treemap.root?.find(item.url)?.remove() }
            for item in gone { UsageCache.changed(item.url.deletingLastPathComponent()) }
            treemap.select(nil)
            treemap.relayout()
            return
        }
        for item in gone { UsageCache.changed(item.url.deletingLastPathComponent()) }
        let next = neighbour(of: gone)
        pendingSelection = next.map { [$0] } ?? []
        if isSearching {
            let keys = Set(gone.map(\.key))
            items.removeAll { keys.contains($0.key) }
            showItems()
        } else {
            load()
        }
    }

    @objc func delete(_ sender: Any?) {
        let gone = deletableItems
        guard !gone.isEmpty else { return }
        FileOps.trash(gone.map(\.url)) { [weak self] removed in self?.removed(gone, only: removed) }
    }

    @objc func deletePermanently(_ sender: Any?) {
        let gone = deletableItems
        guard !gone.isEmpty else { return }
        FileOps.deletePermanently(gone.map(\.url)) { [weak self] removed in self?.removed(gone, only: removed) }
    }

    @objc func renameSelection(_ sender: Any?) {
        let chosen = selectedItems
        // F2 comes here without asking the menu; an opened archive is read-only.
        guard chosen.count == 1, let item = chosen.first, item.volume == nil, !isInArchive else { return }
        switch shownMode {
        case .details: renameInline(item)
        case .icons, .columns, .usage: renameInSheet(item)
        }
    }

    /// The length of the name before its extension; folders are all name.
    func stemLength(of item: FileItem) -> Int {
        let name = item.name as NSString
        let ext = item.isFolder ? "" : name.pathExtension
        let extLength = (ext as NSString).length
        if extLength == 0 || name.length <= extLength + 1 { return name.length }
        return name.length - extLength - 1
    }

    private func renameInline(_ item: FileItem) {
        let column = table.column(withIdentifier: .nameColumn)
        guard column >= 0, let row = items.firstIndex(where: { $0.key == item.key }) else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCell else { return }
        renamingKey = item.key
        cell.textField?.delegate = self
        if !cell.beginRename(stemLength: stemLength(of: item)) { renamingKey = nil }
    }

    private func renameInSheet(_ item: FileItem) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.commitRename(item, to: field.stringValue)
        }
        let length = stemLength(of: item)
        DispatchQueue.main.async { field.currentEditor()?.selectedRange = NSRange(location: 0, length: length) }
    }

    func commitRename(_ item: FileItem, to name: String) {
        guard name != item.name else { return }
        do {
            let renamed = try FileOps.rename(item.url, to: name)
            FileUndo.record([.moved(from: item.url, to: renamed)], name: "Rename")
            pendingSelection = [renamed.key]
            scrollToSelection = true
            if isSearching, let index = items.firstIndex(where: { $0.key == item.key }) {
                items[index] = FileItem(url: renamed)
                showItems()
            } else {
                load()
            }
        } catch {
            show(error)
        }
    }

    // MARK: Other things to do with files

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs
        if !urls.isEmpty {
            FileOps.copyPaths(urls)
        } else if let url = location.url {
            FileOps.copyPaths([url])
        }
    }

    @objc func share(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let button = sender as? ToolButton {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            return
        }
        var anchor = NSRect(x: activeList.visibleRect.midX, y: activeList.visibleRect.midY, width: 1, height: 1)
        if shownMode == .details, let row = table.selectedRowIndexes.first {
            anchor = table.rect(ofRow: row)
        } else if shownMode == .icons, let path = grid.selectionIndexPaths.first, let frame = grid.item(at: path)?.view.frame {
            anchor = frame
        }
        picker.show(relativeTo: anchor, of: activeList, preferredEdge: .minY)
    }

    @objc func showProperties(_ sender: Any?) {
        let urls = selectedURLs
        if !urls.isEmpty {
            PropertiesWindow.show(urls)
        } else if let url = location.url {
            PropertiesWindow.show([url])
        }
    }

    private var terminalFolder: URL? {
        let chosen = selectedItems
        if chosen.count == 1, let folder = folderTarget(of: chosen[0]) { return folder }
        return location.url
    }

    @objc func openInTerminal(_ sender: Any?) {
        if let folder = terminalFolder { FileOps.openTerminal(at: folder) }
    }

    /// Sync Folders: the one or two folders selected (a single one with the
    /// folder it was last synced with); with none, the pair synced last.
    @objc func syncFolders(_ sender: Any?) {
        let folders = selectedItems.compactMap(folderTarget(of:))
        if (1...2).contains(folders.count) { return SyncWindow.show(folders) }
        if SyncWindow.Setup.recent.isEmpty, let url = location.url { return SyncWindow.show([url]) }
        SyncWindow.show([])
    }

    /// Right-click on the empty part of the list: this folder.
    @objc func syncThisFolder(_ sender: Any?) {
        if let url = location.url { SyncWindow.show([url]) }
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedURLs
        if !urls.isEmpty {
            FileOps.showInFinder(urls)
        } else if let url = location.url {
            FileOps.showInFinder([url])
        }
    }

    /// What Add to Quick access works on: the selected files and folders, or the folder on screen.
    private var pinTargets: [URL] {
        guard !isInArchive else { return [] }
        let chosen = selectedItems
        if !chosen.isEmpty { return chosen.map(\.url) }
        return location.url.map { [$0] } ?? []
    }

    @objc func togglePin(_ sender: Any?) {
        let urls = pinTargets
        guard !urls.isEmpty else { return }
        if urls.allSatisfy(Pins.isPinned) { Pins.unpin(urls) } else { Pins.pin(urls) }
    }

    /// Middle-click on a folder: open it in a new tab, as in Windows.
    func openInNewTab(item index: Int) {
        guard index >= 0, index < items.count, let folder = folderTarget(of: items[index]) else { return }
        appDelegate?.openWindow(.folder(folder), tabbedWith: window, activate: false)
    }

    @objc func editMarkdown(_ sender: Any?) {
        guard let file = selectedItems.first?.url, Markdown.isMarkdown(file), !isInArchive else { return }
        MarkdownEditor.show(file)
    }

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Selection

    @objc func selectAllItems(_ sender: Any?) {
        select(keys: Set(items.map(\.key)))
        selectionChanged()
    }

    @objc func selectNone(_ sender: Any?) {
        select(keys: [])
        selectionChanged()
    }

    @objc func invertSelection(_ sender: Any?) {
        let chosen = Set(selectedItems.map(\.key))
        select(keys: Set(items.map(\.key)).subtracting(chosen))
        selectionChanged()
    }

    // MARK: View

    @objc func setDetailsView(_ sender: Any?) { setViewMode(.details) }
    @objc func setIconsView(_ sender: Any?) { setViewMode(.icons) }
    @objc func setColumnsView(_ sender: Any?) { setViewMode(.columns) }
    @objc func toggleHidden(_ sender: Any?) { Prefs.showHidden.toggle() }

    // MARK: Zip, AirDrop, iCloud, tags

    /// Runs a zip or unzip with a progress window, then selects what it made.
    private func runArchive(_ job: Archive.Job, title: String, undoName: String) {
        let progress = ProgressWindow(title: title)
        progress.update(text: job.output.lastPathComponent)
        progress.onCancel = { job.cancel() }
        progress.showSoon()
        busyText = title + "…"
        updateStatus()
        job.run { [weak self] made, problem in
            progress.finish()
            if let problem { FileOps.report([problem]) }
            guard let self else { return }
            self.busyText = nil
            guard let made else { return self.updateStatus() }
            FileUndo.record([.created(made)], name: undoName)
            self.pendingSelection = [made.key]
            self.scrollToSelection = true
            self.reload()
        }
    }

    /// Compress to ▸ ZIP, 7z or TAR.GZ; the menu item carries the format.
    @objc func compress(_ sender: Any?) {
        let format = ((sender as? NSMenuItem)?.representedObject as? String).flatMap(Archive.Format.init(rawValue:)) ?? .zip
        let urls = selectedItems.filter { $0.volume == nil }.map(\.url)
        guard !isInArchive, !urls.isEmpty, Set(urls.map { $0.deletingLastPathComponent().key }).count == 1 else { return }
        runArchive(Archive.compress(urls, as: format), title: "Compressing \(Format.items(urls.count))", undoName: "Compress")
    }

    /// Opens a zip, RAR, 7z or tar like a folder, as Windows does.
    func openArchive(_ archive: URL) {
        ArchiveFolders.open(archive) { [weak self] folder in
            guard let self, let folder else { return }
            self.navigate(to: .folder(folder))
            self.focusList()
        }
    }

    /// The archive Extract All works on: the selected one, or the one being looked inside.
    var archiveToExtract: URL? {
        let chosen = selectedItems
        if chosen.count == 1, ArchiveFolders.isArchive(chosen[0].url), !isInArchive { return chosen[0].url }
        if chosen.isEmpty || isInArchive { return archiveContext?.archive }
        return nil
    }

    /// Extract All: into a folder named after the archive, beside it, then shows it.
    @objc func extract(_ sender: Any?) {
        guard let archive = archiveToExtract else { return }
        unpack(archive, into: nil)
    }

    /// Extract To…: the same, into a folder you pick.
    @objc func extractTo(_ sender: Any?) {
        guard let archive = archiveToExtract, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract"
        panel.message = "Choose where to extract “\(archive.lastPathComponent)”"
        panel.directoryURL = archive.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.unpack(archive, into: folder)
        }
    }

    private func unpack(_ archive: URL, into folder: URL?) {
        ArchiveUI.extractAll(archive, into: folder) { [weak self] made in
            guard let self, let made else { return }
            FileUndo.record([.created(made)], name: "Extract")
            let parent = made.deletingLastPathComponent()
            if parent.key == self.location.url?.key {
                self.pendingSelection = [made.key]
                self.scrollToSelection = true
                self.reload()
            } else {
                self.navigate(to: .folder(parent), select: [made])
                self.focusList()
            }
        }
    }

    @objc func airDrop(_ sender: Any?) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: selectedURLs)
    }

    /// iCloud: keep a copy on this Mac, as Windows' "Always keep on this device".
    @objc func downloadNow(_ sender: Any?) {
        for item in selectedItems where item.cloud == .cloudOnly {
            do { try FileManager.default.startDownloadingUbiquitousItem(at: item.url) } catch { show(error) }
        }
        reload()
    }

    /// iCloud: free the space, keep the file in iCloud, as Windows' "Free up space".
    @objc func removeDownload(_ sender: Any?) {
        var failures: [String] = []
        for item in selectedItems where item.cloud == .local {
            do { try FileManager.default.evictUbiquitousItem(at: item.url) } catch { failures.append(error.localizedDescription) }
        }
        FileOps.report(failures)
        reload()
    }

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        FileOps.report(Tags.toggle(tag, on: selectedURLs))
        reload()
    }

    @objc func newTag(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = "The tag is added to the selected items."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let urls = selectedURLs
        for url in urls where !Tags.names(of: url).contains(name) {
            do { try Tags.set(Tags.names(of: url) + [name], on: url) } catch { show(error) }
        }
        reload()
    }

    func compressMenu() -> NSMenu {
        let menu = NSMenu()
        for format in Archive.Format.allCases {
            menu.addItem(item(format.title, nil, #selector(compress(_:)), object: format.rawValue))
        }
        return menu
    }

    private func tagsMenu() -> NSMenu {
        let menu = NSMenu()
        var names = Tags.favourites
        for tag in selectedItems.flatMap(\.tags) where !names.contains(tag) { names.append(tag) }
        for name in names {
            let entry = item(name, nil, #selector(toggleTag(_:)), object: name)
            entry.image = Tags.dot(for: name)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Tag…", "plus", #selector(newTag(_:))))
        return menu
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        applySort(SortSpec(key: key, ascending: key == sort.key ? sort.ascending : true))
    }

    @objc func sortAscending(_ sender: Any?) { applySort(SortSpec(key: sort.key, ascending: true)) }
    @objc func sortDescending(_ sender: Any?) { applySort(SortSpec(key: sort.key, ascending: false)) }

    func applySort(_ spec: SortSpec) {
        sort = spec
        spec.save()
        table.sortDescriptors = [NSSortDescriptor(key: spec.key.rawValue, ascending: spec.ascending)]
        resort()
    }

    func resort() {
        pendingSelection = Set(selectedItems.map(\.key))
        sortGeneration += 1
        if searchRunning { searchSorted = true }
        // A big folder takes a moment to sort by name; do it off the main
        // thread, as loading does. Search results keep arriving, so they sort here.
        guard items.count > 2000, !isSearching else {
            items = items.sorted(by: sort)
            return showItems()
        }
        let unsorted = items
        let order = sort
        let generation = (load: loadGeneration, sort: sortGeneration)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sorted = unsorted.sorted(by: order)
            DispatchQueue.main.async {
                guard let self, generation == (self.loadGeneration, self.sortGeneration), order == self.sort else { return }
                self.items = sorted
                self.showItems()
            }
        }
    }

    // MARK: Command bar menus

    func item(_ title: String, _ symbol: String?, _ action: Selector, key: String = "",
              mods: NSEvent.ModifierFlags = .command, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.representedObject = object
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Folder", "folder.badge.plus", #selector(newFolder(_:)), key: "n", mods: [.command, .shift]))
        menu.addItem(item("Text Document", "doc.text", #selector(newTextDocument(_:))))
        return menu
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        var keys: [(String, SortKey)] = [("Name", .name), ("Date modified", .modified), ("Type", .kind), ("Size", .size)]
        if isSearching { keys.append(("Folder", .location)) }
        for (title, key) in keys { menu.addItem(item(title, nil, #selector(sortBy(_:)), object: key.rawValue)) }
        menu.addItem(.separator())
        menu.addItem(item("Ascending", nil, #selector(sortAscending(_:))))
        menu.addItem(item("Descending", nil, #selector(sortDescending(_:))))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Details", "list.bullet", #selector(setDetailsView(_:)), key: "1"))
        menu.addItem(item("Large icons", "square.grid.2x2", #selector(setIconsView(_:)), key: "2"))
        menu.addItem(item("Columns", "rectangle.split.3x1", #selector(setColumnsView(_:)), key: "3"))
        menu.addItem(item("Disk usage", "square.split.2x2", #selector(setUsageView(_:)), key: "4"))
        menu.addItem(.separator())
        menu.addItem(item("Folder sizes", "internaldrive", #selector(toggleFolderSizes(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Details pane", "sidebar.right", #selector(togglePreviewPane(_:)), key: "p", mods: [.command, .shift]))
        menu.addItem(item("Hidden items", "eye", #selector(toggleHidden(_:)), key: ".", mods: [.command, .shift]))
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Select all", "checkmark.circle", #selector(selectAllItems(_:)), key: "a"))
        menu.addItem(item("Select none", "circle", #selector(selectNone(_:))))
        menu.addItem(item("Invert selection", "circle.lefthalf.filled", #selector(invertSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Copy as path", "link", #selector(copyPath(_:)), key: "c", mods: [.command, .shift]))
        menu.addItem(item("Open in Terminal", "terminal", #selector(openInTerminal(_:))))
        menu.addItem(item("Show in Finder", "folder", #selector(showInFinder(_:))))
        menu.addItem(item(pinTitle, "pin", #selector(togglePin(_:))))
        menu.addItem(item("Sync folders…", "arrow.triangle.2.circlepath", #selector(syncFolders(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Properties", "info.circle", #selector(showProperties(_:)), key: "i"))
        return menu
    }

    private var pinTitle: String {
        let urls = pinTargets
        return !urls.isEmpty && urls.allSatisfy(Pins.isPinned) ? "Remove from Quick access" : "Add to Quick access"
    }

    @objc func showNewMenu(_ sender: ToolButton) { sender.popUp(newMenu()) }
    @objc func showSortMenu(_ sender: ToolButton) { sender.popUp(sortMenu()) }
    @objc func showViewMenu(_ sender: ToolButton) { sender.popUp(viewMenu()) }
    @objc func showMoreMenu(_ sender: ToolButton) { sender.popUp(moreMenu()) }

    // MARK: Right-click menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let chosen = selectedItems
        if chosen.isEmpty {
            let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            view.image = NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: nil)
            view.submenu = viewMenu()
            menu.addItem(view)
            let sort = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
            sort.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
            sort.submenu = sortMenu()
            menu.addItem(sort)
            menu.addItem(item("Refresh", "arrow.clockwise", #selector(refresh(_:)), key: "r"))
            menu.addItem(.separator())
            menu.addItem(item("Paste", "doc.on.clipboard", #selector(paste(_:)), key: "v"))
            let new = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
            new.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
            new.submenu = newMenu()
            menu.addItem(new)
            menu.addItem(.separator())
            menu.addItem(item("Open in Terminal", "terminal", #selector(openInTerminal(_:))))
            menu.addItem(item("Analyze disk usage", "square.split.2x2", #selector(analyzeDiskUsage(_:))))
            menu.addItem(item("Sync with…", "arrow.triangle.2.circlepath", #selector(syncThisFolder(_:))))
            menu.addItem(item("Copy as path", "link", #selector(copyPath(_:)), key: "c", mods: [.command, .shift]))
            menu.addItem(item(pinTitle, "pin", #selector(togglePin(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Properties", "info.circle", #selector(showProperties(_:)), key: "i"))
            return menu
        }

        let open = item("Open", nil, #selector(openSelection(_:)))
        open.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(open)
        let folders = chosen.compactMap(folderTarget(of:))
        if folders.count == chosen.count {
            menu.addItem(item("Open in new tab", "plus.square.on.square", #selector(openInNewTab(_:))))
            menu.addItem(item("Open in new window", "macwindow.badge.plus", #selector(openInNewWindow(_:))))
        } else if chosen.count == 1 {
            let with = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
            with.submenu = openWithMenu(for: chosen[0].url)
            menu.addItem(with)
        }
        if !Prefs.imageViewer && chosen.allSatisfy(isPicture) {
            menu.addItem(item("View in Foldera", "photo", #selector(viewPictures(_:))))
        }
        if chosen.count == 1, Markdown.isMarkdown(chosen[0].url), !isInArchive {
            menu.addItem(item("Edit Markdown", "square.and.pencil", #selector(editMarkdown(_:))))
        }
        if isSearching {
            menu.addItem(item("Open file location", "folder", #selector(openFileLocation(_:))))
        }
        menu.addItem(item("Quick Look", "eye", #selector(quickLook(_:))))
        if !pinTargets.isEmpty { menu.addItem(item(pinTitle, "pin", #selector(togglePin(_:)))) }
        guard chosen.allSatisfy({ $0.volume == nil }) else {
            menu.addItem(.separator())
            menu.addItem(item("Properties", "info.circle", #selector(showProperties(_:)), key: "i"))
            return menu
        }
        menu.addItem(.separator())
        menu.addItem(item("Cut", "scissors", #selector(cut(_:)), key: "x"))
        menu.addItem(item("Copy", "doc.on.doc", #selector(copy(_:)), key: "c"))
        menu.addItem(item("Copy as path", "link", #selector(copyPath(_:)), key: "c", mods: [.command, .shift]))
        menu.addItem(item("Share", "square.and.arrow.up", #selector(share(_:))))
        menu.addItem(item("AirDrop", "airplayaudio", #selector(airDrop(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Rename", "character.cursor.ibeam", #selector(renameSelection(_:))))
        menu.addItem(item("Move to Trash", "trash", #selector(delete(_:)), key: "\u{8}"))
        if archiveToExtract != nil {
            menu.addItem(item("Extract All", "archivebox", #selector(extract(_:))))
            menu.addItem(item("Extract To…", "archivebox", #selector(extractTo(_:))))
        }
        let compress = NSMenuItem(title: "Compress to", action: nil, keyEquivalent: "")
        compress.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        compress.submenu = compressMenu()
        menu.addItem(compress)
        let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        tags.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        tags.submenu = tagsMenu()
        menu.addItem(tags)
        if chosen.contains(where: { $0.cloud == .cloudOnly }) {
            menu.addItem(item("Download Now", "icloud.and.arrow.down", #selector(downloadNow(_:))))
        }
        if chosen.contains(where: { $0.cloud == .local }) {
            menu.addItem(item("Remove Download", "icloud", #selector(removeDownload(_:))))
        }
        menu.addItem(.separator())
        if folders.count == 1 && chosen.count == 1 {
            menu.addItem(item("Open in Terminal", "terminal", #selector(openInTerminal(_:))))
            menu.addItem(item("Analyze disk usage", "square.split.2x2", #selector(analyzeDiskUsage(_:))))
            menu.addItem(item("Sync with…", "arrow.triangle.2.circlepath", #selector(syncFolders(_:))))
        } else if folders.count == 2 && chosen.count == 2 {
            menu.addItem(item("Sync these folders…", "arrow.triangle.2.circlepath", #selector(syncFolders(_:))))
        }
        menu.addItem(item("Show in Finder", "folder", #selector(showInFinder(_:))))
        menu.addItem(item("Properties", "info.circle", #selector(showProperties(_:)), key: "i"))
        return menu
    }

    // MARK: Menu state

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let editing = window?.firstResponder is NSText
        let chosen = selectedItems
        let files = !chosen.isEmpty && chosen.allSatisfy { $0.volume == nil }
        // Inside an archive everything is read-only: copy out, but change nothing.
        let changeable = files && !isInArchive
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return parentLocation != nil
        case #selector(copy(_:)), #selector(share(_:)):
            return !editing && files
        case #selector(cut(_:)), #selector(delete(_:)), #selector(deletePermanently(_:)):
            return !editing && changeable
        case #selector(paste(_:)), #selector(pasteMove(_:)):
            return !editing && currentFolder != nil && FileClipboard.shared.hasFiles
        case #selector(renameSelection(_:)):
            return !editing && changeable && chosen.count == 1
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return currentFolder != nil
        case #selector(openSelection(_:)), #selector(quickLook(_:)), #selector(openFileLocation(_:)):
            return !chosen.isEmpty
        case #selector(copyPath(_:)), #selector(showProperties(_:)), #selector(showInFinder(_:)):
            return !editing && (!chosen.isEmpty || location.url != nil)
        case #selector(openInTerminal(_:)):
            return terminalFolder != nil
        case #selector(syncFolders(_:)), #selector(syncThisFolder(_:)):
            return !isInArchive
        case #selector(togglePin(_:)):
            menuItem.title = pinTitle
            return !pinTargets.isEmpty
        case #selector(setUsageView(_:)):
            menuItem.state = viewMode == .usage ? .on : .off
            return location.url != nil
        case #selector(toggleFolderSizes(_:)):
            menuItem.state = Prefs.folderSizes ? .on : .off
            return true
        case #selector(analyzeDiskUsage(_:)):
            return !isInArchive && (chosen.isEmpty ? location.url != nil : chosen.count == 1 && folderTarget(of: chosen[0]) != nil)
        case #selector(biggerIcons(_:)):
            return true
        case #selector(smallerIcons(_:)):
            return shownMode == .icons
        case #selector(toggleFilters(_:)):
            menuItem.state = showsFilterBar || filters.isActive ? .on : .off
            return true
        case #selector(editMarkdown(_:)):
            return chosen.count == 1 && Markdown.isMarkdown(chosen[0].url) && !isInArchive
        case #selector(selectAllItems(_:)), #selector(selectNone(_:)), #selector(invertSelection(_:)):
            return !items.isEmpty
        case #selector(setDetailsView(_:)):
            menuItem.state = viewMode == .details ? .on : .off
            return true
        case #selector(setColumnsView(_:)):
            menuItem.state = viewMode == .columns ? .on : .off
            return true
        case #selector(togglePreviewPane(_:)):
            menuItem.state = Prefs.previewPane ? .on : .off
            return true
        case #selector(compress(_:)):
            return !editing && changeable && Set(selectedURLs.map { $0.deletingLastPathComponent().key }).count == 1
        case #selector(extract(_:)), #selector(extractTo(_:)):
            return archiveToExtract != nil
        case #selector(airDrop(_:)):
            return files && NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: selectedURLs) == true
        case #selector(downloadNow(_:)):
            return chosen.contains { $0.cloud == .cloudOnly }
        case #selector(removeDownload(_:)):
            return chosen.contains { $0.cloud == .local }
        case #selector(toggleTag(_:)):
            let tag = menuItem.representedObject as? String ?? ""
            let having = chosen.filter { $0.tags.contains(tag) }.count
            menuItem.state = having == 0 ? .off : (having == chosen.count ? .on : .mixed)
            return changeable
        case #selector(newTag(_:)):
            return changeable
        case #selector(setIconsView(_:)):
            menuItem.state = viewMode == .icons ? .on : .off
            return true
        case #selector(toggleHidden(_:)):
            menuItem.state = Prefs.showHidden ? .on : .off
            return true
        case #selector(sortBy(_:)):
            menuItem.state = (menuItem.representedObject as? String) == sort.key.rawValue ? .on : .off
            return true
        case #selector(sortAscending(_:)):
            menuItem.state = sort.ascending ? .on : .off
            return true
        case #selector(sortDescending(_:)):
            menuItem.state = sort.ascending ? .off : .on
            return true
        default:
            return true
        }
    }

    // MARK: Keyboard

    /// The Windows keys: Enter opens, Backspace goes back, Delete trashes,
    /// F2 renames, F5 refreshes, Alt+arrows move around. Anything typed
    /// into a text field is left alone.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, host?.selected === self else { return false }
        let responder = window.firstResponder
        if responder is NSText {
            typeSelection.reset()
            return false
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let listFocused = (responder as? NSView)?.isDescendant(of: activeList) == true
        if listFocused && handleTypeSelection(event) { return true }
        typeSelection.reset()
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if listFocused && mods.isEmpty { openSelection(nil); return true }
            if listFocused && mods == .option { showProperties(nil); return true }
            if listFocused && mods == .command { openInNewTab(nil); return true }
        case 51: // Backspace
            if mods.isEmpty { goBack(nil); return true }
        case 117: // Forward delete
            if listFocused && mods.isEmpty { delete(nil); return true }
            if listFocused && mods == .shift { deletePermanently(nil); return true }
        case 49: // Space
            if listFocused && mods.isEmpty { quickLook(nil); return true }
        case 120: // F2
            if mods.isEmpty { renameSelection(nil); return true }
        case 99: // F3
            if mods.isEmpty { focusSearch(nil); return true }
        case 118: // F4
            if mods.isEmpty { focusAddress(nil); return true }
        case 96: // F5
            if mods.isEmpty { refresh(nil); return true }
        case 123: // ←
            if mods == .option { goBack(nil); return true }
        case 124: // →
            if mods == .option { goForward(nil); return true }
        case 126: // ↑
            if mods == .option { goUp(nil); return true }
        case 2: // D
            if mods == .option { focusAddress(nil); return true }
        case 35: // P: Alt+P in Windows shows the preview pane
            if mods == .option { togglePreviewPane(nil); return true }
        case 53: // Esc: the words first, then the search options
            if !searchQuery.isEmpty { endSearch(); return true }
            if filters.isActive { filtersChanged(SearchFilters()); return true }
            if FileClipboard.shared.isCut { FileClipboard.shared.clearCut(); return true }
        default:
            break
        }
        return false
    }

    func show(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
