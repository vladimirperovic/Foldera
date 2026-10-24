import AppKit

struct OpError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Everything that changes files. Names and questions follow Windows:
/// "New folder (2)", "report - Copy.txt", Replace / Keep both / Skip.
enum FileOps {
    static let stagingSuffix = ".foldera-transfer"

    /// A private directory on the destination volume. Only its contents may
    /// be removed when a copy fails; the requested destination may belong to
    /// another writer by then.
    static func stagingFolder(beside target: URL) throws -> URL {
        let folder = target.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)\(stagingSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Takes away a tree Foldera made itself: an archive's cache, a staging
    /// folder, a half-made copy. See `removeTree`.
    static func removeOwn(_ url: URL) { try? removeTree(url) }

    /// Removes `url` and everything in it, for good. A read-only folder
    /// inside (an unpacked archive, a copied folder, a Go module cache) stops
    /// removeItem partway, leaving the rest half deleted; as its owner, it is
    /// opened up and the removal tried again, as Finder does when it empties
    /// the Trash. Only for what is to go anyway: Foldera's own staging and
    /// caches, and what the user chose to erase.
    static func removeTree(_ url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: url)
        } catch {
            guard exists(url) else { return }
            func openUp(_ path: String) {
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
                if info.st_mode & S_IRWXU != S_IRWXU { chmod(path, (info.st_mode & 0o7777) | S_IRWXU) }
                for name in (try? fm.contentsOfDirectory(atPath: path)) ?? [] { openUp(path + "/" + name) }
            }
            openUp(url.path)
            try fm.removeItem(at: url)
        }
    }

    struct Revision: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int
        let modifiedNanos: Int
        let changed: Int
        let changedNanos: Int
    }

    static func revision(of url: URL) -> Revision? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return Revision(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                        modified: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
                        changed: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec)
    }

    /// Includes every descendant, without following symbolic links. A
    /// directory's own date does not tell whether an existing child changed.
    struct TreeRevision: Equatable {
        var entries: [String: Revision]
    }

    static func treeRevision(of root: URL, cancelled: CancelFlag) throws -> TreeRevision {
        if cancelled.isSet { throw CancellationError() }
        guard let own = revision(of: root) else { throw CocoaError(.fileReadUnknown) }
        var entries = ["": own]
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        if info.st_mode & S_IFMT == S_IFDIR {
            var failure: Error?
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [], errorHandler: { _, error in failure = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            while let child = walker.nextObject() as? URL {
                if cancelled.isSet { throw CancellationError() }
                guard let value = revision(of: child) else { throw CocoaError(.fileReadUnknown) }
                let path = child.pathComponents.suffix(walker.level).joined(separator: "/")
                entries[path] = value
            }
            if let failure { throw failure }
        }
        if cancelled.isSet { throw CancellationError() }
        return TreeRevision(entries: entries)
    }

    /// Like fileExists, but a broken symbolic link still counts as being there.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Two names for one file: the same entry on the same disk, as a
    /// name differing only in case is on a drive that ignores case.
    static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        var x = stat()
        var y = stat()
        guard lstat(a.path, &x) == 0, lstat(b.path, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func isFolder(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    /// `base`, then `base (2)`, `base (3)`… — the first name nobody has taken.
    /// The first name not on disk and not in `taken` (names already given out by a plan being made).
    static func freeURL(in folder: URL, base: String, ext: String, from start: Int = 1, taken: Set<String> = []) -> URL {
        var n = start
        while true {
            let stem = n == 1 ? base : "\(base) (\(n))"
            let url = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if !taken.contains(url.key) && !exists(url) { return url }
            n += 1
        }
    }

    private static func split(_ url: URL) -> (stem: String, ext: String) {
        if isFolder(url) { return (url.lastPathComponent, "") }
        return (url.deletingPathExtension().lastPathComponent, url.pathExtension)
    }

    static func copyName(for source: URL, in folder: URL, taken: Set<String> = []) -> URL {
        let (stem, ext) = split(source)
        return freeURL(in: folder, base: "\(stem) - Copy", ext: ext, taken: taken)
    }

    static func keepBothName(for source: URL, in folder: URL, taken: Set<String> = []) -> URL {
        let (stem, ext) = split(source)
        return freeURL(in: folder, base: stem, ext: ext, from: 2, taken: taken)
    }

    /// A transfer can collect thousands of identically named search results.
    /// Resume the suffix search instead of scanning all previous names again.
    struct NameAllocator {
        private struct Key: Hashable { let folder: String; let stem: String; let ext: String }
        private var next: [Key: Int] = [:]

        mutating func name(for source: URL, in folder: URL, copy: Bool = false, taken: Set<String>, ignoreCase: Bool = false) -> URL {
            let parts = FileOps.split(source)
            let stem = copy ? parts.stem + " - Copy" : parts.stem
            func keyPart(_ text: String) -> String { ignoreCase ? text.lowercased() : text }
            let key = Key(folder: keyPart(folder.key), stem: keyPart(stem), ext: keyPart(parts.ext))
            var n = next[key] ?? (copy ? 1 : 2)
            while true {
                let base = n == 1 ? stem : "\(stem) (\(n))"
                let url = folder.appendingPathComponent(parts.ext.isEmpty ? base : base + "." + parts.ext)
                n += 1
                if !taken.contains(keyPart(url.key)) && !FileOps.exists(url) {
                    next[key] = n
                    return url
                }
            }
        }
    }

    /// True when `folder` is `source` itself or somewhere inside it.
    static func isInside(_ folder: URL, _ source: URL) -> Bool {
        let f = folder.resolvingSymlinksInPath().key
        let s = source.resolvingSymlinksInPath().key
        return f == s || f.hasPrefix(s == "/" ? "/" : s + "/")
    }

    static func makeFolder(in folder: URL) throws -> URL {
        try refuseInArchive([folder])
        let url = freeURL(in: folder, base: "New folder", ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func makeTextFile(in folder: URL) throws -> URL {
        try refuseInArchive([folder])
        let url = freeURL(in: folder, base: "New Text Document", ext: "txt")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw OpError("Foldera couldn't create a file in “\(folder.lastPathComponent)”.")
        }
        return url
    }

    static func rename(_ url: URL, to proposed: String) throws -> URL {
        try refuseInArchive([url])
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw OpError("A file name can't be empty or contain / or :.")
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if name == url.lastPathComponent { return url }
        // RENAME_EXCL permits changing this entry's case on APFS while
        // atomically refusing to replace any other directory entry.
        if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { throw OpError("There is already a file with the name “\(name)” in this location.") }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return target
    }

    /// What is inside an opened archive is a read-only view of it: nothing there is renamed, moved or deleted.
    static func refuseInArchive(_ urls: [URL]) throws {
        if urls.contains(where: ArchiveFolders.isInside) {
            throw OpError("An opened archive is read-only. Extract it to change what is inside.")
        }
    }

    /// To the Trash, recorded so ⌘Z brings it back. `done` gets what actually went.
    static func trash(_ urls: [URL], done: @escaping (_ removed: [URL]) -> Void) {
        do { try refuseInArchive(urls) } catch { return report([error.localizedDescription]) }
        NSWorkspace.shared.recycle(urls) { trashed, error in
            DispatchQueue.main.async {
                FileUndo.record(trashed.map { Change.moved(from: $0.key, to: $0.value) }, name: "Move to Trash")
                if let error { NSAlert(error: error).runModal() }
                done(Array(trashed.keys))
                announceRemoved(Array(trashed.keys))
            }
        }
    }

    /// Every window takes the items off its list without waiting to read the
    /// folder again, which on a slow disk takes seconds.
    static func announceRemoved(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .explorerItemsRemoved, object: nil, userInfo: ["urls": urls])
    }

    /// Shift+Delete: gone for good, after one clear question.
    static func deletePermanently(_ urls: [URL], done: @escaping (_ removed: [URL]) -> Void) {
        do { try refuseInArchive(urls) } catch { return report([error.localizedDescription]) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Permanently delete “\(urls[0].lastPathComponent)”?"
            : "Permanently delete these \(urls.count) items?"
        alert.informativeText = "They won't go to the Trash. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var removed: [URL] = []
            for url in urls {
                do {
                    try removeTree(url)
                    removed.append(url)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                report(failures)
                done(removed)
                announceRemoved(removed)
            }
        }
    }

    static func report(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        // Without a running app (the tests) there is nobody to press OK, and
        // a modal alert would wait forever.
        guard NSApplication.shared.isRunning else {
            failures.forEach { FileHandle.standardError.write(Data(("Foldera: " + $0 + "\n").utf8)) }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1 ? "An item couldn't be processed." : "\(failures.count) items couldn't be processed."
        alert.informativeText = failures.prefix(6).joined(separator: "\n")
        alert.runModal()
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func openTerminal(at folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows the items in Finder itself, even when Foldera is the default file viewer.
    static func showInFinder(_ urls: [URL]) {
        let viewer = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "NSFileViewer")
        if viewer == nil || viewer == "com.apple.finder" {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"),
                  let first = urls.first {
            NSWorkspace.shared.open([first.deletingLastPathComponent()], withApplicationAt: finder,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// The file clipboard. macOS has no "cut" for files, so Foldera remembers
/// which URLs it put there as cut; pasting those moves them.
final class FileClipboard {
    static let shared = FileClipboard()
    private var cutKeys: Set<String> = []
    private var cutChangeCount = -1

    func put(_ urls: [URL], cut: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        cutKeys = cut ? Set(urls.map(\.key)) : []
        cutChangeCount = pb.changeCount
        NotificationCenter.default.post(name: .explorerClipboardChanged, object: nil)
    }

    var urls: [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private var checkedChangeCount = -1
    private var checkedHasFiles = false

    /// Asked on every selection change; the pasteboard is only read again once its contents change.
    var hasFiles: Bool {
        let pb = NSPasteboard.general
        if pb.changeCount != checkedChangeCount {
            checkedChangeCount = pb.changeCount
            checkedHasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        }
        return checkedHasFiles
    }

    var isCut: Bool { !cutKeys.isEmpty && NSPasteboard.general.changeCount == cutChangeCount }

    func isCut(_ key: String) -> Bool { isCut && cutKeys.contains(key) }

    func clearCut() {
        guard !cutKeys.isEmpty else { return }
        cutKeys = []
        NotificationCenter.default.post(name: .explorerClipboardChanged, object: nil)
    }
}

/// What a drop means, Windows-style: same drive moves, another drive copies,
/// Option always copies.
enum DragOps {
    static func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// What one drag carries, read once. A drop is validated again at every
    /// move of the pointer, and thousands of files dragged were each looked
    /// up on the disk again (their real paths, whether folders) every time.
    private struct Sources {
        let drag: Int
        let change: Int
        let urls: [URL]
        let fromArchive: Bool
        /// The real paths of the folders and packages among them.
        let folders: [String]
        let parents: Set<String>
    }
    private static var dragged: Sources?

    private static func sources(of info: NSDraggingInfo) -> Sources {
        let drag = info.draggingSequenceNumber
        let change = info.draggingPasteboard.changeCount
        if let dragged, dragged.drag == drag, dragged.change == change { return dragged }
        let urls = urls(from: info)
        let read = Sources(drag: drag, change: change, urls: urls,
                           fromArchive: urls.contains(where: ArchiveFolders.isInside),
                           folders: urls.filter(isFolderOrPackage).map { $0.resolvingSymlinksInPath().key },
                           parents: Set(urls.map { $0.deletingLastPathComponent().key }))
        dragged = read
        return read
    }

    static func operation(for info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        let sources = sources(of: info)
        guard let first = sources.urls.first else { return [] }
        // An opened archive is read-only, and what comes out of one is always a copy.
        if ArchiveFolders.isInside(folder) { return [] }
        if sources.fromArchive {
            return info.draggingSourceOperationMask.contains(.copy) ? .copy : []
        }
        // Not into one of the folders dragged, nor anywhere inside one.
        if !sources.folders.isEmpty {
            let target = folder.resolvingSymlinksInPath().key
            if sources.folders.contains(where: { target == $0 || target.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { return [] }
        }
        if sources.parents == [folder.key] { return [] }
        let mask = info.draggingSourceOperationMask
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        if !optionHeld && mask.contains(.move) && sameVolume(first, folder) { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return []
    }

    private static func isFolderOrPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }
}
