import AppKit

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
    let size: Int64?
    let modified: Date?
    let created: Date?
    let kind: String
    let volume: Volume?
    /// Finder tags, read when first shown: a second trip to the disk per
    /// file that a folder of thousands shouldn't pay for up front.
    lazy var tags: [String] = Self.tagNames(of: url)
    let cloud: Cloud?
    /// A folder's size on disk, once measured (View › Folder Sizes, Disk usage).
    var folderSize: Int64?
    private var cachedIcon: NSImage?

    /// The folder it is in, kept for sorting search results by folder.
    lazy var folderPath: String = url.deletingLastPathComponent().path

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isAliasFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
        // Tags are not in this list. Asked for alongside other keys, or
        // prefetched by a directory listing, they come back empty on macOS 27
        // (and .isUbiquitousItemKey empties them too), so they are read on
        // their own. The download status tells an iCloud item apart; the rest
        // of its state is asked for separately, for those items only.
        .ubiquitousItemDownloadingStatusKey,
    ]

    /// Something you walk into rather than hand to an app.
    var isFolder: Bool { volume != nil || (isDirectory && !isPackage) }

    init(url: URL) {
        self.url = url
        key = url.key
        name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Set(Self.keys))
        isSymlink = values?.isSymbolicLink ?? false
        var directory = values?.isDirectory ?? false
        var package = values?.isPackage ?? false
        if isSymlink {
            let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            directory = target?.isDirectory ?? false
            package = target?.isPackage ?? false
        }
        isDirectory = directory
        isPackage = package
        isHidden = (values?.isHidden ?? false) || name.hasPrefix(".")
        // isAliasFile is also true for symbolic links.
        isAlias = (values?.isAliasFile ?? false) && !isSymlink
        size = directory ? nil : values?.fileSize.map(Int64.init)
        modified = values?.contentModificationDate
        created = values?.creationDate
        kind = values?.localizedTypeDescription ?? (directory ? "Folder" : "Document")
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
        isDirectory = true
        isPackage = false
        isHidden = false
        isAlias = false
        isSymlink = false
        size = nil
        modified = nil
        created = nil
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
        tags = []
    }

    /// Read alone and fresh; see the note on `keys`.
    static func tagNames(of url: URL) -> [String] {
        var fresh = url
        fresh.removeCachedResourceValue(forKey: .tagNamesKey)
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    var icon: NSImage {
        if let cachedIcon { return cachedIcon }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cachedIcon = image
        return image
    }

    static func contents(of folder: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map(FileItem.init(url:))
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

extension Array where Element == FileItem {
    /// Folders stay together, as in Windows: on top going up, at the bottom going down.
    func sorted(by spec: SortSpec) -> [FileItem] {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return sorted { a, b in
            if a.isFolder != b.isFolder { return spec.ascending ? a.isFolder : b.isFolder }
            var r: ComparisonResult
            switch spec.key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .modified: r = order(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind: r = a.kind.localizedStandardCompare(b.kind)
            case .size: r = order(a.size ?? a.folderSize ?? a.volume?.total ?? 0, b.size ?? b.folderSize ?? b.volume?.total ?? 0)
            case .location:
                r = a.folderPath.localizedStandardCompare(b.folderPath)
            }
            if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
            return spec.ascending ? r == .orderedAscending : r == .orderedDescending
        }
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

    /// The picture size in Large icons, 48–256 points.
    static var iconSize: CGFloat {
        get { min(max(UserDefaults.standard.object(forKey: "iconSize").map { CGFloat(($0 as? Double) ?? 64) } ?? 64, 48), 256) }
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
}
