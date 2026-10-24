import AppKit
import UniformTypeIdentifiers

/// Where a window is looking: a folder on disk, or the list of drives.
enum Location: Equatable {
    case thisMac
    case folder(URL)

    var url: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var title: String {
        switch self {
        case .thisMac:
            return "This Mac"
        case .folder(let url):
            if isVolumeRoot(url) { return volumeName(url) }
            if let archive = ArchiveFolders.context(of: url), archive.root.key == url.key { return archive.archive.lastPathComponent }
            return FileManager.default.displayName(atPath: url.path)
        }
    }

    var icon: NSImage {
        switch self {
        case .thisMac: return NSImage(named: NSImage.computerName) ?? NSImage()
        case .folder(let url):
            if let archive = ArchiveFolders.context(of: url), archive.root.key == url.key {
                return NSWorkspace.shared.icon(forFile: archive.archive.path)
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    static func == (a: Location, b: Location) -> Bool {
        switch (a, b) {
        case (.thisMac, .thisMac): return true
        case let (.folder(x), .folder(y)): return x.key == y.key
        default: return false
        }
    }
}

extension URL {
    /// One spelling per file whatever the URL came from: a directory listing
    /// hands back folders with a trailing slash, the pasteboard may not.
    var key: String { standardizedFileURL.path }
}

func isVolumeRoot(_ url: URL) -> Bool {
    url.key == "/" || url.deletingLastPathComponent().key == "/Volumes"
}

func volumeName(_ url: URL) -> String {
    (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
}

/// A small copy of an icon for menus; NSWorkspace hands out shared images.
func menuIcon(_ image: NSImage) -> NSImage {
    let copy = image.copy() as? NSImage ?? image
    copy.size = NSSize(width: 16, height: 16)
    return copy
}

/// One row in the list: a file, a folder, or (in This Mac) a drive.
final class FileItem {
    struct Volume {
        let total: Int64
        let free: Int64
        let ejectable: Bool
    }

    /// Where an iCloud Drive item lives, as Windows' Status column shows OneDrive files.
    enum Cloud: CustomStringConvertible {
        case cloudOnly, downloading, local, uploading

        var description: String {
            switch self {
            case .cloudOnly: return "In iCloud only"
            case .downloading: return "Downloading…"
            case .local: return "Downloaded"
            case .uploading: return "Uploading…"
            }
        }

        var symbol: String {
            switch self {
            case .cloudOnly: return "icloud"
            case .downloading: return "icloud.and.arrow.down"
            case .local: return "checkmark.circle"
            case .uploading: return "icloud.and.arrow.up"
            }
        }

        var isSyncing: Bool { self == .downloading || self == .uploading }
    }

    let url: URL
    let key: String
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isAlias: Bool
    let isSymlink: Bool
    /// Resolved with the directory metadata, never while validating a menu
    /// or opening the viewer on the main thread.
    let isImage: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let accessed: Date?
    let kind: String
    let volume: Volume?
    /// Finder tags, read when first asked for: a second trip to the disk per
    /// file that a folder of thousands shouldn't pay for up front. Safe from
    /// any thread, so the list can have them read in the background.
    var tags: [String] {
        get {
            if let known = knownTags { return known }
            let read = Self.tagNames(of: url)
            Self.tagLock.lock()
            readTags = read
            Self.tagLock.unlock()
            return read
        }
        set {
            Self.tagLock.lock()
            readTags = newValue
            Self.tagLock.unlock()
        }
    }
    /// The tags if they were read already, without going to the disk.
    var knownTags: [String]? {
        Self.tagLock.lock()
        defer { Self.tagLock.unlock() }
        return readTags
    }
    private var readTags: [String]?
    private static let tagLock = NSLock()
    /// What the list showed for this file before it was read again, shown
    /// until the tags are, so a refresh doesn't make them blink. Main thread.
    var previousTags: [String]?
    /// The tags to draw now, without going to the disk.
    var shownTags: [String] { knownTags ?? previousTags ?? [] }
    let cloud: Cloud?
    /// A folder's size on disk, once measured (View › Folder Sizes, Disk usage).
    var folderSize: Int64?
    private var cachedIcon: NSImage?
    /// On a disk without macOS's own file metadata: its kind and icon are told from the name.
    private let byName: Bool

    /// The folder it is in, kept for sorting search results by folder.
    lazy var folderPath: String = url.deletingLastPathComponent().path

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isAliasFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentAccessDateKey, .localizedTypeDescriptionKey, .contentTypeKey,
        // Tags are not in this list. Asked for alongside other keys, or
        // prefetched by a directory listing, they come back empty on macOS 27
        // (and .isUbiquitousItemKey empties them too), so they are read on
        // their own. The download status tells an iCloud item apart; the rest
        // of its state is asked for separately, for those items only.
        .ubiquitousItemDownloadingStatusKey,
    ]

    /// What a disk without macOS's own file metadata (exFAT, FAT, a share) is
    /// asked for. Finder metadata, aliases, packages and localized kinds can
    /// live in the "._" file beside it, and asking means a search
    /// of the folder per item: on an exFAT disk through FSKit, seconds for a
    /// folder of photos. They are told from the name instead.
    static let leanKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentAccessDateKey,
    ]

    /// Folders Windows keeps out of sight at the top of a drive.
    private static let windowsHidden: Set<String> = ["System Volume Information", "$RECYCLE.BIN"]

    static func hiddenByName(_ name: String) -> Bool {
        name.hasPrefix(".") || windowsHidden.contains(name)
    }

    /// FAT/exFAT and SMB expose the native hidden bit through stat flags.
    /// Read that bit without asking Foundation to inspect AppleDouble files.
    private static func nativeHidden(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_flags & UInt32(UF_HIDDEN)) != 0
    }

    /// The type an item's name says it is: a folder's extension is looked up among folders ("app"), a file's among files.
    private static func type(byName url: URL, directory: Bool) -> UTType? {
        url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension, conformingTo: directory ? .directory : .data)
    }

    /// Something you walk into rather than hand to an app.
    var isFolder: Bool { volume != nil || (isDirectory && !isPackage) }

    /// `foreign`: on a disk without macOS's own file metadata, asked only for `leanKeys`.
    init(url: URL, foreign: Bool = false) {
        self.url = url
        key = url.key
        name = url.lastPathComponent
        byName = foreign
        let values = try? url.resourceValues(forKeys: Set(foreign ? Self.leanKeys : Self.keys))
        isImage = (values?.contentType ?? UTType(filenameExtension: url.pathExtension))?.conforms(to: .image) ?? false
        isSymlink = values?.isSymbolicLink ?? false
        var directory = values?.isDirectory ?? false
        var package = values?.isPackage ?? false
        if isSymlink {
            let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            directory = target?.isDirectory ?? false
            package = target?.isPackage ?? false
        } else if foreign {
            package = directory && Self.type(byName: url, directory: true)?.conforms(to: .package) == true
        }
        isDirectory = directory
        isPackage = package
        isHidden = foreign ? Self.hiddenByName(name) || Self.nativeHidden(url)
            : (values?.isHidden ?? false) || name.hasPrefix(".")
        // isAliasFile is also true for symbolic links.
        isAlias = (values?.isAliasFile ?? false) && !isSymlink
        size = directory ? nil : values?.fileSize.map(Int64.init)
        modified = values?.contentModificationDate
        created = values?.creationDate
        accessed = values?.contentAccessDate
        if foreign {
            kind = directory && !package ? "Folder"
                : Self.type(byName: url, directory: directory)?.localizedDescription ?? (directory ? "Folder" : "Document")
        } else {
            kind = values?.localizedTypeDescription ?? (directory ? "Folder" : "Document")
        }
        volume = nil
        if let status = values?.ubiquitousItemDownloadingStatus {
            let sync = try? url.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey])
            if sync?.ubiquitousItemIsUploading == true {
                cloud = .uploading
            } else if sync?.ubiquitousItemIsDownloading == true {
                cloud = .downloading
            } else if status == .notDownloaded {
                cloud = .cloudOnly
            } else {
                cloud = .local
            }
        } else {
            cloud = nil
        }
    }

    init(volume url: URL) {
        self.url = url
        key = url.key
        let values = try? url.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        ])
        name = values?.volumeLocalizedName ?? url.lastPathComponent
        byName = false
        isDirectory = true
        isPackage = false
        isHidden = false
        isAlias = false
        isSymlink = false
        isImage = false
        size = nil
        modified = nil
        created = nil
        accessed = nil
        cloud = nil
        let ejectable = (values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false)
        if url.key == "/" {
            kind = "Startup disk"
        } else if values?.volumeIsLocal == false {
            kind = "Network drive"
        } else if ejectable || !(values?.volumeIsInternal ?? true) {
            kind = "External disk"
        } else {
            kind = "Local disk"
        }
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        volume = Volume(total: Int64(values?.volumeTotalCapacity ?? 0), free: free, ejectable: ejectable)
        // Drives carry no tags; and a network drive that stopped answering mustn't be asked while drawing.
        readTags = []
    }

    /// A progress batch owns its presentation state independently of the
    /// background reader. No filesystem access and no shared mutable fields.
    init(snapshot item: FileItem, folderSize: Int64?) {
        url = item.url
        key = item.key
        name = item.name
        isDirectory = item.isDirectory
        isPackage = item.isPackage
        isHidden = item.isHidden
        isAlias = item.isAlias
        isSymlink = item.isSymlink
        isImage = item.isImage
        size = item.size
        modified = item.modified
        created = item.created
        accessed = item.accessed
        kind = item.kind
        volume = item.volume
        cloud = item.cloud
        byName = item.byName
        readTags = item.knownTags
        self.folderSize = folderSize
    }

    /// Read alone and fresh; see the note on `keys`.
    static func tagNames(of url: URL) -> [String] {
        var fresh = url
        fresh.removeCachedResourceValue(forKey: .tagNamesKey)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        // On a foreign disk by its name: asking the file there means a trip to its "._" file, on the drawing thread.
        let image = byName
            ? NSWorkspace.shared.icon(for: isFolder ? .folder : Self.type(byName: url, directory: isDirectory) ?? .data)
            : NSWorkspace.shared.icon(forFile: url.path)
        cachedIcon = image
        return image
    }

    /// The items in `folder`. `step` is handed what has been read so far
    /// twice a second, so a slow disk shows the first before the rest.
    typealias Enumerator = (URL, [URLResourceKey], FileManager.DirectoryEnumerationOptions, @escaping (URL, Error) -> Bool) -> AnyIterator<URL>?

    static func enumerate(_ folder: URL, keys: [URLResourceKey], options: FileManager.DirectoryEnumerationOptions,
                          error: @escaping (URL, Error) -> Bool) -> AnyIterator<URL>? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: options, errorHandler: error) else { return nil }
        return AnyIterator { walker.nextObject() as? URL }
    }

    static func contents(of folder: URL, showHidden: Bool, cancelled: CancelFlag = CancelFlag(), step: (([FileItem]) -> Void)? = nil,
                         enumerate: Enumerator = FileItem.enumerate) throws -> [FileItem] {
        if cancelled.isSet { throw CancellationError() }
        let foreign = UsageScanner.isForeign(folder)
        // Foreign disks use names and native stat flags below, avoiding a
        // Foundation hidden-file check that can look into every "._" file.
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showHidden && !foreign { options.insert(.skipsHiddenFiles) }
        var failure: Error?
        guard let walker = enumerate(folder, foreign ? leanKeys : keys, options,
                                     { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        var found: [FileItem] = []
        var told = Date()
        var pause: TimeInterval = 0.5
        while let url = walker.next() {
            if cancelled.isSet { throw CancellationError() }
            let item = FileItem(url: url, foreign: foreign)
            if foreign && !showHidden && item.isHidden { continue }
            found.append(item)
            if let step, Date().timeIntervalSince(told) > pause {
                let began = Date()
                step(found)
                told = Date()
                // Handing over a long list takes a while itself (it is copied and
                // sorted each time); the read goes on at least twice that long
                // before the next, so a folder of a hundred thousand isn't held up.
                pause = max(0.5, 2 * told.timeIntervalSince(began))
            }
        }
        // A partial list is not a successful read, even when some entries arrived.
        if cancelled.isSet { throw CancellationError() }
        if let failure { throw failure }
        return found
    }

    static func volumes() -> [FileItem] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) ?? true }
            .map(FileItem.init(volume:))
    }
}

enum Folders {
    /// The folders directly inside `url`, in the order Foldera lists them.
    static func subfolders(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter {
                let v = try? $0.resourceValues(forKeys: Set(keys))
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether there is at least one folder inside, without listing everything.
    static func hasSubfolder(_ url: URL) -> Bool {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else { return false }
        while let child = e.nextObject() as? URL {
            let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true && v?.isPackage != true { return true }
        }
        return false
    }
}

enum SortKey: String {
    case name, modified, kind, size, location
    // The further choices of Windows' Sort menu.
    case created, accessed, fileExtension = "extension", tags
}

extension FileItem {
    /// The extension as Windows' File extension column writes it, ".pdf";
    /// folders and drives have none.
    var fileExtension: String {
        guard !isFolder else { return "" }
        let ext = url.pathExtension
        return ext.isEmpty ? "" : "." + ext.lowercased()
    }

    /// What Size sorts by: a file's size, a measured folder's, or a drive's.
    var sortSize: Int64 {
        if let size { return size }
        if let folderSize { return folderSize }
        return volume?.total ?? 0
    }
}

struct SortSpec: Equatable {
    var key: SortKey
    var ascending: Bool

    static var saved: SortSpec {
        let d = UserDefaults.standard
        return SortSpec(
            key: SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .name,
            ascending: d.object(forKey: "sortAscending") as? Bool ?? true)
    }

    func save() {
        UserDefaults.standard.set(key.rawValue, forKey: "sortKey")
        UserDefaults.standard.set(ascending, forKey: "sortAscending")
    }
}

extension SortSpec {
    /// Whether `a` comes before `b`. Folders stay together, as in Windows:
    /// on top going up, at the bottom going down.
    func orders(_ a: FileItem, before b: FileItem) -> Bool {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        /// Tag by tag; no tags at all comes first.
        func orderTags(_ a: [String], _ b: [String]) -> ComparisonResult {
            for (x, y) in zip(a, b) {
                let r = x.localizedStandardCompare(y)
                if r != .orderedSame { return r }
            }
            return order(a.count, b.count)
        }
        if a.isFolder != b.isFolder { return ascending ? a.isFolder : b.isFolder }
        var r: ComparisonResult
        switch key {
        case .name: r = a.name.localizedStandardCompare(b.name)
        case .modified: r = order(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .kind: r = a.kind.localizedStandardCompare(b.kind)
        case .size: r = order(a.sortSize, b.sortSize)
        case .location:
            r = a.folderPath.localizedStandardCompare(b.folderPath)
        case .created: r = order(a.created ?? .distantPast, b.created ?? .distantPast)
        case .accessed: r = order(a.accessed ?? .distantPast, b.accessed ?? .distantPast)
        case .fileExtension: r = a.fileExtension.localizedStandardCompare(b.fileExtension)
        case .tags: r = orderTags(a.tags, b.tags)
        }
        if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
        return ascending ? r == .orderedAscending : r == .orderedDescending
    }
}

extension Array where Element == FileItem {
    func sorted(by spec: SortSpec) -> [FileItem] {
        // Each file's tags are read once, here, rather than on every comparison.
        if spec.key == .tags { forEach { _ = $0.tags } }
        return sorted { spec.orders($0, before: $1) }
    }

    /// This list, already in `spec` order, with `others` put where they
    /// belong; `inserted` is where they ended up, in the merged list.
    func merged(with others: [FileItem], by spec: SortSpec) -> (merged: [FileItem], inserted: [Int]) {
        let others = others.sorted(by: spec)
        var merged: [FileItem] = []
        merged.reserveCapacity(count + others.count)
        var inserted: [Int] = []
        inserted.reserveCapacity(others.count)
        var i = startIndex
        for item in others {
            while i < endIndex && !spec.orders(item, before: self[i]) {
                merged.append(self[i])
                i += 1
            }
            inserted.append(merged.count)
            merged.append(item)
        }
        merged.append(contentsOf: self[i...])
        return (merged, inserted)
    }
}

enum Format {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Sizes in the list the way Windows writes them: always in KB, rounded up.
    static func kilobytes(_ bytes: Int64) -> String {
        count((bytes + 1023) / 1024) + " KB"
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func count(_ n: Int64) -> String {
        number.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func items(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(count(Int64(n))) items"
    }

    /// A path with the home folder written as ~.
    static func path(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

enum Prefs {
    /// The Size column measures folders too (in the background), which Windows doesn't.
    static var folderSizes: Bool {
        get { UserDefaults.standard.bool(forKey: "folderSizes") }
        set {
            UserDefaults.standard.set(newValue, forKey: "folderSizes")
            NotificationCenter.default.post(name: .explorerFolderSizesChanged, object: nil)
        }
    }

    /// The Details columns beyond the usual ones that are switched on: from
    /// the column headers' right-click menu, or by sorting on one, as in Windows.
    static var extraColumns: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "extraColumns") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "extraColumns") }
    }

    /// The layout each folder was last shown in, as Windows remembers it per folder.
    static func folderView(for url: URL) -> String? {
        (UserDefaults.standard.dictionary(forKey: "folderViews") as? [String: String])?[url.key]
    }

    static func rememberFolderView(_ view: String, for url: URL) {
        var views = UserDefaults.standard.dictionary(forKey: "folderViews") as? [String: String] ?? [:]
        views[url.key] = nil
        // A thousand folders is plenty; past that, some are forgotten to make room.
        if views.count >= 1000 {
            for key in Array(views.keys).shuffled().prefix(views.count - 999) { views[key] = nil }
        }
        views[url.key] = view
        UserDefaults.standard.set(views, forKey: "folderViews")
    }

    /// The picture size in Large icons, 48–320 points.
    static var iconSize: CGFloat {
        get { min(max(UserDefaults.standard.object(forKey: "iconSize").map { CGFloat(($0 as? Double) ?? 64) } ?? 64, 48), IconGeometry.largest) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "iconSize") }
    }


    /// Enter on a zip, RAR or 7z opens it like a folder, as in Windows.
    static var browseArchives: Bool {
        get { UserDefaults.standard.object(forKey: "browseArchives") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "browseArchives") }
    }

    /// The preview and details pane on the right.
    static var previewPane: Bool {
        get { UserDefaults.standard.bool(forKey: "previewPane") }
        set { UserDefaults.standard.set(newValue, forKey: "previewPane") }
    }

    /// Pictures open in Foldera's own viewer rather than Preview.
    static var imageViewer: Bool {
        get { UserDefaults.standard.object(forKey: "imageViewer") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "imageViewer") }
    }

    static var showHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "showHidden") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showHidden")
            NotificationCenter.default.post(name: .explorerShowHiddenChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let explorerClipboardChanged = Notification.Name("ExplorerClipboardChanged")
    static let explorerShowHiddenChanged = Notification.Name("ExplorerShowHiddenChanged")
    static let explorerPinsChanged = Notification.Name("ExplorerPinsChanged")
    static let explorerPreviewPaneChanged = Notification.Name("ExplorerPreviewPaneChanged")
    static let explorerFolderSizesChanged = Notification.Name("ExplorerFolderSizesChanged")
    /// Items sent to the Trash or deleted, as "urls": every list drops them at once.
    static let explorerItemsRemoved = Notification.Name("ExplorerItemsRemoved")
}
