import AppKit
import CoreServices
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [ExplorerWindow] = []
    private var openedAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Show in Finder" from other apps arrives as Finder's own reveal
        // event once Foldera is the default file viewer.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleReveal(_:reply:)),
            forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let args = Array(CommandLine.arguments.dropFirst())
        // Archives opened last time were unpacked into the cache; start clean,
        // unless another Foldera is using that cache right now.
        if !args.contains("--snapshot") && !Self.anotherFolderaRunning {
            DispatchQueue.global(qos: .utility).async { ArchiveFolders.clear() }
        }
        if let index = args.firstIndex(of: "--snapshot") {
            snapshot(Array(args[(index + 1)...]))
            return
        }
        for arg in args where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            if FileOps.exists(url) { open(url, reveal: false) }
        }
        if windows.isEmpty && !openedAtLaunch {
            openWindow(.folder(FileManager.default.homeDirectoryForCurrentUser))
        }
        NSApp.activate()
    }

    /// The standard About panel, with "beta" after the version while it is one.
    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let stage = info["FolderaReleaseStage"] as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: stage.isEmpty ? version : "\(version) \(stage)"])
    }

    /// A second copy of the app, or a snapshot run beside it: the archive cache is shared.
    private static var anotherFolderaRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != .current }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !CommandLine.arguments.contains("--snapshot") && !Self.anotherFolderaRunning { ArchiveFolders.clear() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Failed pane saves move to retained editor windows before the quit check.
        windows.flatMap(\.tabs).forEach { $0.previewPane.clear() }
        return MarkdownEditor.canCloseAll() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(.folder(FileManager.default.homeDirectoryForCurrentUser)) }
        return true
    }

    /// Folders open in a window of their own; a file opens its folder with it selected.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls { open(url, reveal: false) }
    }

    private func open(_ url: URL, reveal: Bool) {
        // A picture opened with Foldera shows in the viewer, with its folder's other pictures a key away.
        if !reveal && Prefs.imageViewer && ImageFiles.isImage(url) {
            let siblings = ImageFiles.images(in: url.deletingLastPathComponent())
            let pictures = siblings.contains { $0.key == url.key } ? siblings : [url]
            ImageViewer.show(pictures, at: pictures.firstIndex { $0.key == url.key } ?? 0)
            return
        }
        if !reveal && Prefs.browseArchives && ArchiveFolders.isArchive(url) {
            openWindow(.folder(url.deletingLastPathComponent()), select: [url]).openArchive(url)
            return
        }
        if !reveal && FileOps.isFolder(url) {
            openWindow(.folder(url))
        } else {
            openWindow(.folder(url.deletingLastPathComponent()), select: [url])
        }
    }

    @objc private func handleReveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        var urls: [URL] = []
        func take(_ descriptor: NSAppleEventDescriptor) {
            if let url = descriptor.fileURLValue ?? descriptor.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue {
                urls.append(url)
            }
        }
        if direct.descriptorType == DescType(typeAEList) && direct.numberOfItems > 0 {
            for i in 1...direct.numberOfItems {
                if let item = direct.atIndex(i) { take(item) }
            }
        } else {
            take(direct)
        }
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent().key }
        for group in byFolder.values {
            openWindow(.folder(group[0].deletingLastPathComponent()), select: group)
        }
        NSApp.activate()
    }

    // MARK: Windows

    /// Opens `location` in a new window, or as a tab in `parent`'s window
    /// (in the background when `activate` is false, as a middle-click does).
    @discardableResult
    func openWindow(_ location: Location, select: [URL] = [], tabbedWith parent: NSWindow? = nil, activate: Bool = true) -> ExplorerTab {
        let tab = ExplorerTab(location: location, select: select)
        if let host = parent?.windowController as? ExplorerWindow {
            host.add(tab, select: activate)
        } else {
            adopt(tab)
        }
        return tab
    }

    /// A new window around `tab` (a new one, or one dragged out of another window).
    func adopt(_ tab: ExplorerTab) {
        let host = ExplorerWindow(first: tab)
        windows.append(host)
        host.onClose = { [weak self, unowned host] in
            self?.windows.removeAll { $0 === host }
        }
        guard let window = host.window else { return }
        if !window.setFrameAutosaveName("ExplorerWindow"), let key = NSApp.keyWindow {
            let topLeft = window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY))
            window.setFrameTopLeftPoint(topLeft)
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame ExplorerWindow") == nil {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        host.windowShown()
    }

    /// The tab on screen in the front window.
    var frontTab: ExplorerTab? { (NSApp.keyWindow?.windowController as? ExplorerWindow)?.selected }

    /// ⌘N: a new window where the current one is, as Ctrl+N does in Windows.
    @objc func newWindow(_ sender: Any?) {
        openWindow(frontTab?.location ?? .folder(FileManager.default.homeDirectoryForCurrentUser))
    }

    /// File › Sync Folders… with no file list in front: the pair synced last.
    @objc func syncFolders(_ sender: Any?) {
        SyncWindow.show([])
    }

    /// ⌘W in a window without tabs (the viewer, Properties, the Markdown editor) closes it.
    @objc func closeTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc func toggleImageViewer(_ sender: Any?) {
        Prefs.imageViewer.toggle()
    }

    @objc func toggleBrowseArchives(_ sender: Any?) {
        Prefs.browseArchives.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleImageViewer(_:)) {
            menuItem.state = Prefs.imageViewer ? .on : .off
        }
        if menuItem.action == #selector(toggleBrowseArchives(_:)) {
            menuItem.state = Prefs.browseArchives ? .on : .off
        }

        return true
    }

    /// ⌘K: mounts a share and opens it, in the front window when there is one.
    @objc func connectToServer(_ sender: Any?) {
        guard let address = Servers.ask() else { return }
        Servers.mount(address) { [weak self] result in
            switch result {
            case .success(let volume):
                if let front = self?.frontTab {
                    front.navigate(to: .folder(volume))
                } else {
                    self?.openWindow(.folder(volume))
                }
            case .failure(let error):
                if !(error is CancellationError) { NSAlert(error: error).runModal() }
            }
        }
    }

    // MARK: Default folder viewer

    @objc func makeDefault(_ sender: Any?) {
        guard let id = Bundle.main.bundleIdentifier else {
            alert("Open Foldera from Foldera.app to do this.", "")
            return
        }
        let question = NSAlert()
        question.messageText = "Open folders in Foldera?"
        question.informativeText = """
            Folders opened from other apps, the Dock and Terminal (open .) will open in Foldera, \
            and “Show in Finder” in most apps will show the file here. Finder keeps running for the \
            desktop. You can switch back from this same menu.
            """
        question.addButton(withTitle: "Use Foldera")
        question.addButton(withTitle: "Cancel")
        guard question.runModal() == .alertFirstButtonReturn else { return }
        setFileViewer(id, app: Bundle.main.bundleURL)
    }

    @objc func restoreFinder(_ sender: Any?) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        setFileViewer(nil, app: finder)
    }

    private func setFileViewer(_ id: String?, app: URL) {
        CFPreferencesSetValue("NSFileViewer" as CFString, id as CFString?, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                } else {
                    self.alert(id == nil ? "Finder opens folders again." : "Foldera now opens folders.",
                               "Apps that are already running may keep using the previous choice until they restart.")
                }
            }
        }
    }

    private func alert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Screenshots for development

    /// `Foldera --snapshot <folder|thismac|image> <out.png> [--icons|--columns] [--pane] [--dark|--light] [--search text]
    /// [--select name] [--tabs count] [--act newfolder|cut|properties] [--press token,token…] [--capture properties|viewer]`
    /// renders one window to a PNG and quits. `--press` sends real key events
    /// through the event queue, the way typing would: a number is a key code,
    /// anything else is typed as characters. An image as the target opens the viewer.
    private func snapshot(_ args: [String]) {
        guard args.count >= 2 else { exit(2) }
        // A screenshot sets the layout, the pane and the window size; the
        // person's own settings are put back when it exits.
        if let domain = Bundle.main.bundleIdentifier {
            settingsBeforeSnapshot = (domain, UserDefaults.standard.persistentDomain(forName: domain))
            atexit {
                guard let saved = settingsBeforeSnapshot else { return }
                if let values = saved.values {
                    UserDefaults.standard.setPersistentDomain(values, forName: saved.domain)
                } else {
                    UserDefaults.standard.removePersistentDomain(forName: saved.domain)
                }
                UserDefaults.standard.synchronize()
            }
        }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        Prefs.previewPane = args.contains("--pane")
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let path = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
        var controller: ExplorerTab?
        var capture = value("--capture")
        if let other = value("--sync") {
            // The sync window for `path` and `other`, compared at once; its memory stays out of the real one.
            Sync.Memory.folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaSnapshotSync")
            let size = value("--size")?.split(separator: "x").compactMap { Double($0) } ?? []
            SyncWindow.showCompared(path, URL(fileURLWithPath: (other as NSString).expandingTildeInPath),
                                    mode: value("--mode").flatMap(Sync.Mode.init(rawValue:)),
                                    size: size.count == 2 ? NSSize(width: size[0], height: size[1]) : nil)
            capture = "sync"
        } else if args[0] != "thismac" && ImageFiles.isImage(path) {
            open(path, reveal: false)
            capture = "viewer"
        } else if ArchiveFolders.isArchive(path) {
            let c = openWindow(.folder(path.deletingLastPathComponent()), select: [path])
            c.setViewMode(.details)
            c.window?.setContentSize(NSSize(width: 1000, height: 520))
            c.openArchive(path)
            controller = c
        } else {
            let target = args[0] == "thismac" ? Location.thisMac : .folder(path)
            let select = value("--select").map { [path.appendingPathComponent($0)] } ?? []
            let c = openWindow(target, select: select)
            c.setViewMode(args.contains("--icons") ? .icons : args.contains("--columns") ? .columns : args.contains("--usage") ? .usage : .details)
            if let side = value("--iconsize").flatMap(Double.init) { c.setViewSize(CGFloat(side)) }
            let size = value("--size")?.split(separator: "x").compactMap { Double($0) } ?? []
            c.window?.setContentSize(size.count == 2 ? NSSize(width: size[0], height: size[1]) : NSSize(width: 1100, height: 660))
            if let query = value("--search") {
                c.searchField.stringValue = query
                c.searchChanged(c.searchField)
            }
            controller = c
        }
        func captured() -> NSWindow? {
            switch capture {
            case "viewer": return NSApp.windows.first { $0 is ViewerWindow }
            case "properties": return NSApp.windows.first { $0 is EscWindow && $0.isVisible }
            case "sync": return NSApp.windows.first { $0.windowController is SyncWindow }
            default: return controller?.window
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let count = value("--tabs").flatMap(Int.init), count > 1, let controller {
                for _ in 1..<min(count, 100) {
                    self.openWindow(controller.location, tabbedWith: controller.window, activate: false)
                }
            }
            switch value("--act") {
            case "newfolder": controller?.newFolder(nil)
            case "cut": controller?.cut(nil)
            case "properties": controller?.showProperties(nil)
            case "filters": controller?.filtersChanged(SearchFilters(kind: .images))
            case "sync": (captured()?.windowController as? SyncWindow)?.synchronize(nil)
            case "tabs":
                for name in ["Photos", "Projects 2026"] {
                    self.openWindow(.folder(path.appendingPathComponent(name)), tabbedWith: controller?.window, activate: false)
                }
            default: break
            }
            guard let tokens = value("--press"), let window = captured() else { return }
            for token in tokens.split(separator: ",").map(String.init) {
                let code = UInt16(token) ?? 0
                let characters = UInt16(token) == nil ? token : ""
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        }
        let wait = value("--wait").flatMap(Double.init) ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard let frame = captured()?.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            exit(0)
        }
    }
}

/// The app's settings from before a snapshot run (see `AppDelegate.snapshot`).
private var settingsBeforeSnapshot: (domain: String, values: [String: Any]?)?
