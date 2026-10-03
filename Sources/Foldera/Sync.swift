import AppKit
import CryptoKit

/// Keeps two folders in step, as FreeFileSync does: Compare lists what is
/// different, Synchronize makes the two the same.
///
/// - Two way: what changed on either side goes to the other, deletions too.
///   What both sides held when they were last the same is remembered
///   (`Memory`); that is how a file deleted on one side is told apart from
///   one that is new on the other. Without that memory nothing is deleted.
/// - Mirror: the right folder becomes an exact copy of the left.
/// - Update: new and newer files go from the left to the right; nothing is deleted.
///
/// Two files are the same when size and date modified agree (dates to two
/// seconds, as FAT drives keep them), or, if asked, when their bytes do.
/// A symbolic link is the same as another when it points to the same place.
/// Nothing inside a folder that couldn't be read is touched, and nothing is
/// changed that isn't still as the compare found it.
enum Sync {
    enum Mode: String, CaseIterable, Codable {
        case twoWay, mirror, update

        var title: String {
            switch self {
            case .twoWay: return "Two way"
            case .mirror: return "Mirror"
            case .update: return "Update"
            }
        }

        var explanation: String {
            switch self {
            case .twoWay:
                return "Changes on either side are copied to the other, deletions included. When a file changed on both sides, you decide."
            case .mirror:
                return "The right folder becomes an exact copy of the left. Whatever is only on the right is deleted."
            case .update:
                return "New and newer files are copied from the left to the right. Nothing is deleted."
            }
        }
    }

    enum Comparison: String, CaseIterable, Codable {
        case dateAndSize, content
        var title: String { self == .content ? "Content" : "Date and size" }
    }

    /// One side of one path.
    struct Item: Equatable {
        var folder: Bool
        var size: Int64
        /// Date modified, in seconds since 1970.
        var modified: Double
        /// A symbolic link: copied and compared as a link, never as what it points to.
        var link = false

        init(folder: Bool, size: Int64, modified: Double, link: Bool = false) {
            self.folder = folder
            self.size = size
            self.modified = modified
            self.link = link
        }

        init(_ values: URLResourceValues) {
            link = values.isSymbolicLink == true
            folder = values.isDirectory == true && !link
            size = folder ? 0 : Int64(values.fileSize ?? 0)
            modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        }

        /// The same kind, size and date (dates to two seconds). Folders only
        /// by kind: what is inside one is looked at on its own (see
        /// `Job.unchanged`), since a folder's date moves whenever Finder
        /// writes its .DS_Store.
        func matches(_ other: Item) -> Bool {
            folder == other.folder && link == other.link
                && (folder || (size == other.size && abs(modified - other.modified) <= Sync.tolerance))
        }
    }

    /// Whether a file was touched at all since it was looked at: which file
    /// it is on the disk, and when anything about it last changed. Unlike
    /// the date modified, that time can't be set back.
    struct Stamp: Equatable {
        let id: UInt64
        let changed: Double

        init(_ values: URLResourceValues) {
            id = values.fileIdentifier ?? 0
            changed = values.attributeModificationDate?.timeIntervalSince1970 ?? 0
        }
    }

    /// FAT drives keep dates to two seconds.
    static let tolerance: Double = 2

    /// Half-copied replacements are named so; they are never synced.
    static let partialSuffix = ".foldera-sync"

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                                         .fileIdentifierKey, .attributeModificationDateKey]
    private static let keySet = Set(keys)

    /// What is at `url` now, if anything.
    static func item(at url: URL) -> Item? {
        (try? url.resourceValues(forKeys: keySet)).map(Item.init)
    }

    static func stamp(at url: URL) -> Stamp? {
        (try? url.resourceValues(forKeys: keySet)).map(Stamp.init)
    }

    /// The path with every symbolic link in it followed, as the disk has it
    /// (with /private, unlike `resolvingSymlinksInPath`).
    static func realPath(_ url: URL) -> String? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Which folder this is, on which disk: another drive mounted in the
    /// same place is another folder.
    static func identity(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey]) else { return nil }
        return "\(values.volumeUUIDString ?? "?")/\(values.fileIdentifier ?? 0)"
    }

    /// Never synced: Finder's and the drive's own bookkeeping.
    static func isIgnored(_ name: String, atTop: Bool) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name.hasSuffix(partialSuffix) || (atTop && driveNames.contains(name))
    }

    private static let driveNames: Set<String> = [
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".VolumeIcon.icns", ".apdisk",
    ]

    /// Names a pair never syncs, as its Exclude field lists them, `;` between:
    /// `node_modules; *.tmp; .git`. A name matches whole, ignoring case; `*`
    /// and `?` are wildcards. What is excluded is left alone on both sides:
    /// not compared, copied or deleted, and a folder holding any of it is
    /// never deleted or replaced as a whole.
    struct Exclusion {
        let text: String
        private let matchers: [(String) -> Bool]

        static let none = Exclusion("")

        init(_ text: String) {
            self.text = text
            matchers = text.split(whereSeparator: { $0 == ";" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(Self.matcher(for:))
        }

        var isEmpty: Bool { matchers.isEmpty }

        func excludes(_ name: String) -> Bool { matchers.contains { $0(name) } }

        private static func matcher(for pattern: String) -> (String) -> Bool {
            if pattern.contains("*") || pattern.contains("?") {
                let predicate = NSPredicate(format: "SELF LIKE[c] %@", pattern)
                return { predicate.evaluate(with: $0) }
            }
            return { $0.caseInsensitiveCompare(pattern) == .orderedSame }
        }
    }

    // MARK: Reading both sides

    /// One folder, read to the bottom.
    struct Listing {
        /// By key: the path inside the folder, lowercased when names are compared ignoring case.
        var items: [String: Item] = [:]
        /// The path as this side spells it, where that differs from the key.
        var spelled: [String: String] = [:]
        /// For files and links: whether they are touched before anything is done to them.
        var stamps: [String: Stamp] = [:]
        /// Where each symbolic link points.
        var targets: [String: String] = [:]
        /// Folders whose contents couldn't be read, and items that couldn't be looked at.
        var unreadable: Set<String> = []
        /// Items left out by the pair's Exclusion (not what is inside them).
        var excluded: Set<String> = []
        var problems: [String] = []

        func path(_ key: String) -> String { spelled[key] ?? key }

        var files: Int { items.values.reduce(0) { $1.folder ? $0 : $0 + 1 } }
    }

    /// What a compare found.
    struct Scan {
        let left: URL
        let right: URL
        let comparison: Comparison
        /// Names compared ignoring case (see `caseSensitive`).
        var ignoreCase = false
        /// What the pair leaves alone; the sync and its checks leave it alone too.
        var exclusion = Exclusion.none
        var leftSide = Listing()
        var rightSide = Listing()
        /// Files of equal size read byte by byte (Content only): key → the same.
        var sameContent: [String: Bool] = [:]
        /// SHA-256 of what files hold, where Content read them whole.
        var leftHashes: [String: String] = [:]
        var rightHashes: [String: String] = [:]
        /// `Sync.identity` of both folders when they were read.
        var leftIdentity: String?
        var rightIdentity: String?
        var memory = Memory()

        var problems: [String] { leftSide.problems + rightSide.problems }

        /// Couldn't be read, or lies inside something that couldn't.
        func isBlocked(_ key: String) -> Bool {
            var path = Substring(key)
            while true {
                if leftSide.unreadable.contains(String(path)) || rightSide.unreadable.contains(String(path)) { return true }
                guard let slash = path.lastIndex(of: "/") else { return false }
                path = path[..<slash]
            }
        }

        /// Two files that are not the same, by the comparison chosen.
        func differ(_ key: String, _ l: Item, _ r: Item) -> Bool {
            if l.link != r.link || l.size != r.size { return true }
            if l.link {
                guard let a = leftSide.targets[key], let b = rightSide.targets[key] else { return true }
                return a != b
            }
            if let same = sameContent[key] { return !same }
            return abs(l.modified - r.modified) > Sync.tolerance
        }

        func same(_ key: String, _ l: Item, _ r: Item) -> Bool {
            l.folder == r.folder && (l.folder || !differ(key, l, r))
        }
    }

    /// Names are compared ignoring case unless both drives tell case apart,
    /// or "Photo.jpg" and "photo.jpg" would be taken for two files.
    static func caseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// Reads both folders (and for Content, the files that may be the same),
    /// then remembers what is the same on both sides. On any thread.
    static func compare(_ left: URL, _ right: URL, by comparison: Comparison, excluding exclusion: Exclusion = .none,
                        cancelled: CancelFlag, progress: @escaping (String) -> Void = { _ in }) throws -> Scan {
        // A folder chosen through a symbolic link is read, and synced, where it really is.
        let left = realPath(left).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? left
        let right = realPath(right).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? right
        let ignoreCase = !(caseSensitive(left) && caseSensitive(right))
        var last = Date.distantPast
        func report(_ text: @autoclosure () -> String) {
            guard Date().timeIntervalSince(last) > 0.1 else { return }
            last = Date()
            progress(text())
        }
        var scan = Scan(left: left, right: right, comparison: comparison, ignoreCase: ignoreCase, exclusion: exclusion)
        scan.leftIdentity = identity(of: left)
        scan.rightIdentity = identity(of: right)
        scan.leftSide = try list(left, ignoreCase: ignoreCase, excluding: exclusion, cancelled: cancelled) {
            report("Reading “\(left.lastPathComponent)”… \(Format.items($0))")
        }
        scan.rightSide = try list(right, ignoreCase: ignoreCase, excluding: exclusion, cancelled: cancelled) {
            report("Reading “\(right.lastPathComponent)”… \(Format.items($0))")
        }
        scan.memory = Memory.load(left, right)
        if comparison == .content {
            let keys = scan.leftSide.items.compactMap { key, l -> String? in
                guard !l.folder, !l.link, let r = scan.rightSide.items[key], !r.folder, !r.link, l.size == r.size else { return nil }
                return key
            }.sorted()
            // Every byte of these is read on both sides, which takes a while for big folders.
            let total = keys.reduce(Int64(0)) { $0 + (scan.leftSide.items[$1]?.size ?? 0) }
            var read: Int64 = 0
            for key in keys {
                if cancelled.isSet { throw CancellationError() }
                report("Comparing contents… \(Format.bytes(read)) of \(Format.bytes(total))")
                read += scan.leftSide.items[key]?.size ?? 0
                let a = left.appendingPathComponent(scan.leftSide.path(key))
                let b = right.appendingPathComponent(scan.rightSide.path(key))
                if let (same, hash) = sameBytes(a, b, cancelled: cancelled) {
                    scan.sameContent[key] = same
                    if let hash {
                        scan.leftHashes[key] = hash
                        scan.rightHashes[key] = hash
                    }
                } else if !cancelled.isSet {
                    scan.leftSide.unreadable.insert(key)
                    scan.leftSide.problems.append("“\(scan.leftSide.path(key))” couldn't be read on both sides.")
                }
            }
            // By content, a file is unchanged since the last sync only if its
            // bytes are: those that look unchanged by size and date, and
            // weren't read whole above, are read now.
            for (key, pair) in scan.memory.items where scan.memory.hashes?[key] != nil {
                for onLeft in [true, false] {
                    let side = onLeft ? scan.leftSide : scan.rightSide
                    guard let item = side.items[key], !item.folder, !item.link, item.matches(onLeft ? pair.left : pair.right),
                          (onLeft ? scan.leftHashes : scan.rightHashes)[key] == nil else { continue }
                    if cancelled.isSet { throw CancellationError() }
                    report("Comparing contents… “\(side.path(key))”")
                    let hash = self.hash((onLeft ? left : right).appendingPathComponent(side.path(key)), cancelled: cancelled)
                    if onLeft { scan.leftHashes[key] = hash } else { scan.rightHashes[key] = hash }
                }
            }
        }
        if cancelled.isSet { throw CancellationError() }
        let remembered = scan.memory
        scan.memory.remember(scan)
        // Written again only when it changed: a hundred thousand files make a file of megabytes.
        if scan.memory != remembered { try? scan.memory.save() }
        return scan
    }

    /// `top`: `root` is one of the two folders synced, where a drive's own folders may be.
    static func list(_ root: URL, ignoreCase: Bool, top: Bool = true, excluding exclusion: Exclusion = .none,
                     cancelled: CancelFlag, found: (Int) -> Void = { _ in }) throws -> Listing {
        // An unreadable folder must not look empty: that would read as everything deleted.
        _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var listing = Listing()
        let bases = [root.key, root.resolvingSymlinksInPath().key]
        func relative(_ url: URL) -> String? {
            let path = url.key
            for base in bases {
                let prefix = base == "/" ? "/" : base + "/"
                if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            }
            return nil
        }
        var failed: [(URL, Error)] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, error in
            failed.append((url, error))
            return true
        })
        while let url = walker?.nextObject() as? URL {
            if cancelled.isSet { throw CancellationError() }
            let path = url.pathComponents.suffix(walker?.level ?? 1).joined(separator: "/")
            if isIgnored(url.lastPathComponent, atTop: top && !path.contains("/")) {
                walker?.skipDescendants()
                continue
            }
            let key = ignoreCase ? path.lowercased() : path
            if exclusion.excludes(url.lastPathComponent) {
                listing.excluded.insert(key)
                walker?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                listing.unreadable.insert(key)
                listing.problems.append("“\(path)” couldn't be looked at.")
                continue
            }
            if listing.items[key] != nil {
                // Two names that differ only in case, and the other drive can't keep both.
                listing.unreadable.insert(key)
                listing.problems.append("“\(path)” and another item differ only in upper and lower case, so neither is synced.")
                continue
            }
            let item = Item(values)
            listing.items[key] = item
            if !item.folder { listing.stamps[key] = Stamp(values) }
            if item.link {
                do {
                    listing.targets[key] = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                } catch {
                    listing.unreadable.insert(key)
                    listing.problems.append("“\(path)” couldn't be read as a symbolic link: \(error.localizedDescription)")
                }
            }
            if key != path { listing.spelled[key] = path }
            if listing.items.count % 500 == 0 { found(listing.items.count) }
        }
        for (url, error) in failed {
            guard let path = relative(url) else {
                throw OpError("Part of “\(root.lastPathComponent)” couldn't be read: \(error.localizedDescription)")
            }
            listing.unreadable.insert(ignoreCase ? path.lowercased() : path)
            listing.problems.append("“\(path)”: \(error.localizedDescription)")
        }
        return listing
    }

    /// Byte by byte, with the SHA-256 of what both hold when they are the
    /// same; nil when either can't be read.
    static func sameBytes(_ a: URL, _ b: URL, cancelled: CancelFlag) -> (Bool, String?)? {
        guard let x = FileHandle(forReadingAtPath: a.path), let y = FileHandle(forReadingAtPath: b.path) else { return nil }
        defer {
            try? x.close()
            try? y.close()
        }
        var sha = SHA256()
        do {
            while !cancelled.isSet {
                let p = try x.read(upToCount: 1 << 20) ?? Data()
                let q = try y.read(upToCount: 1 << 20) ?? Data()
                if p != q { return (false, nil) }
                if p.isEmpty { return (true, Data(sha.finalize()).base64EncodedString()) }
                sha.update(data: p)
            }
        } catch {}
        return nil
    }

    /// The SHA-256 of what a file holds; nil when it can't be read.
    static func hash(_ url: URL, cancelled: CancelFlag) -> String? {
        digest(url, cancelled: cancelled)?.base64EncodedString()
    }

    /// The SHA-256 itself, read a megabyte at a time; `read` hears how far it got.
    static func digest(_ url: URL, cancelled: CancelFlag, read: (Int64) -> Void = { _ in }) -> Data? {
        guard let file = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? file.close() }
        var sha = SHA256()
        var done: Int64 = 0
        do {
            while !cancelled.isSet {
                let chunk = try file.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { return Data(sha.finalize()) }
                sha.update(data: chunk)
                done += Int64(chunk.count)
                read(done)
            }
        } catch {}
        return nil
    }

    // MARK: Deciding

    enum Action {
        case none, toRight, toLeft, deleteLeft, deleteRight
        var reversed: Action {
            switch self {
            case .toRight: return .toLeft
            case .toLeft: return .toRight
            case .deleteLeft: return .deleteRight
            case .deleteRight: return .deleteLeft
            case .none: return .none
            }
        }
    }

    /// One line of the comparison: a path, and what Synchronize does about it.
    struct Row {
        let key: String
        /// The path as spelled on each side, or where it will go there.
        let leftPath: String
        let rightPath: String
        let left: Item?
        let right: Item?
        var action: Action
        /// Why it isn't synced on its own: for you to decide.
        let conflict: String?
        /// Why nothing happens, when that is no conflict.
        let note: String?
        /// A folder on one side only (or where the other side has a file),
        /// done in one go with everything inside it.
        let whole: Bool
        /// Inside a whole folder, on each side.
        let leftFiles: Int
        let rightFiles: Int
        let leftBytes: Int64
        let rightBytes: Int64
        /// Everything inside a whole folder (files and folders), on each side.
        let leftEntries: Int
        let rightEntries: Int
        /// What can be chosen for it.
        let choices: [Action]

        var name: String { left != nil ? leftPath : rightPath }

        /// A folder on one side, made on the other while its contents are synced row by row.
        var isFolderOnly: Bool { !whole && (left?.folder == true || right?.folder == true) }

        /// What Synchronize reads, when copying this way.
        var bytesToCopy: Int64 {
            switch action {
            case .toRight: return isFolderOnly ? 0 : leftBytes
            case .toLeft: return isFolderOnly ? 0 : rightBytes
            default: return 0
            }
        }
    }

    struct Plan {
        var rows: [Row] = []
        /// Files found the same on both sides.
        var equal = 0

        /// What deserves a question before Synchronize: deleting everything
        /// on one side (an empty or unmounted drive looks like that), or
        /// replacing and deleting more than half of it.
        func worries(_ scan: Scan) -> [String] {
            var lost = (left: 0, right: 0)
            var deleted = (left: 0, right: 0)
            for row in rows {
                switch row.action {
                case .deleteLeft:
                    lost.left += max(row.leftFiles, 1)
                    deleted.left += max(row.leftFiles, 1)
                case .deleteRight:
                    lost.right += max(row.rightFiles, 1)
                    deleted.right += max(row.rightFiles, 1)
                case .toLeft where row.left != nil && !row.isFolderOnly: lost.left += max(row.leftFiles, 1)
                case .toRight where row.right != nil && !row.isFolderOnly: lost.right += max(row.rightFiles, 1)
                default: break
                }
            }
            var worries: [String] = []
            for (side, lost, deleted, total) in [("left", lost.left, deleted.left, scan.leftSide.files),
                                                 ("right", lost.right, deleted.right, scan.rightSide.files)] {
                if deleted > 0 && deleted >= total {
                    worries.append("Everything in the \(side) folder would be deleted.")
                } else if lost >= 10 && lost * 2 > total {
                    worries.append("\(Format.count(Int64(lost))) of the \(Format.count(Int64(total))) files on the \(side) would be replaced or deleted.")
                }
            }
            return worries
        }

        /// Whether Synchronize would replace or delete anything.
        var removesAnything: Bool {
            rows.contains {
                switch $0.action {
                case .deleteLeft, .deleteRight: return true
                case .toLeft: return $0.left != nil && !$0.isFolderOnly
                case .toRight: return $0.right != nil && !$0.isFolderOnly
                case .none: return false
                }
            }
        }
    }

    /// What a folder holds, as far as deciding about the folder goes.
    private struct Tally {
        var actions = Set<Action>()
        var files = 0
        var entries = 0
        var bytes: Int64 = 0
        var unreadable = false
    }

    /// Reverse one-way sync without moving the folders displayed on screen.
    static func plan(_ scan: Scan, mode: Mode, towardLeft: Bool = false) -> Plan {
        if towardLeft && mode != .twoWay {
            var reversed = Scan(left: scan.right, right: scan.left, comparison: scan.comparison)
            reversed.ignoreCase = scan.ignoreCase
            reversed.leftSide = scan.rightSide
            reversed.rightSide = scan.leftSide
            reversed.sameContent = scan.sameContent
            let planned = plan(reversed, mode: mode)
            let rows = planned.rows.map { row in
                Row(key: row.key, leftPath: row.rightPath, rightPath: row.leftPath,
                    left: row.right, right: row.left, action: row.action.reversed, conflict: row.conflict,
                    note: row.note?.replacingOccurrences(of: "on the right", with: "on the left"),
                    whole: row.whole, leftFiles: row.rightFiles, rightFiles: row.leftFiles,
                    leftBytes: row.rightBytes, rightBytes: row.leftBytes,
                    leftEntries: row.rightEntries, rightEntries: row.leftEntries,
                    choices: row.choices.map(\.reversed))
            }
            return Plan(rows: rows, equal: planned.equal)
        }
        let lefts = scan.leftSide
        let rights = scan.rightSide
        // Folder by folder: everything inside a folder comes right after it.
        let order = Set(lefts.items.keys).union(rights.items.keys)
            .map { ($0.replacingOccurrences(of: "/", with: "\u{0}"), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        func parent(_ key: String) -> String {
            key.lastIndex(of: "/").map { String(key[..<$0]) } ?? ""
        }

        // Folders holding something excluded, however deep: never deleted or
        // replaced whole, or what is excluded would go with them.
        var shielded = Set<String>()
        for key in lefts.excluded.union(rights.excluded) {
            var above = parent(key)
            while !above.isEmpty, shielded.insert(above).inserted { above = parent(above) }
        }

        func newer(_ l: Item, _ r: Item) -> Action? {
            if l.modified > r.modified + tolerance { return .toRight }
            if r.modified > l.modified + tolerance { return .toLeft }
            return nil
        }
        let sameDate = scan.comparison == .content ? "Same date, different content" : "Same date, different size"
        let fileAndFolder = "A file on one side, a folder on the other"

        typealias Decision = (action: Action, conflict: String?, note: String?)

        /// Still what both sides held at the last sync? By content that takes
        /// the same bytes, not just the same size and date; nil when that
        /// can't be told (no content was remembered for it).
        func unchanged(_ key: String, _ item: Item, since was: Item, onLeft: Bool) -> Bool? {
            guard item.folder == was.folder, item.link == was.link else { return false }
            // A link's content is its destination in either comparison mode.
            // Older memory without that destination cannot justify a deletion.
            if item.link {
                let side = onLeft ? scan.leftSide : scan.rightSide
                guard let before = scan.memory.targets?[key], let now = side.targets[key] else { return nil }
                return before == now
            }
            guard item.matches(was) else { return false }
            guard scan.comparison == .content, !item.folder else { return true }
            guard let before = scan.memory.hashes?[key], let now = (onLeft ? scan.leftHashes : scan.rightHashes)[key] else { return nil }
            return before == now
        }

        /// Files, and a file facing a folder.
        func decideFile(_ key: String, _ l: Item?, _ r: Item?) -> Decision {
            let was = scan.memory.items[key]
            switch mode {
            case .mirror:
                guard let l else { return (.deleteRight, nil, nil) }
                guard let r else { return (.toRight, nil, nil) }
                return (scan.same(key, l, r) ? .none : .toRight, nil, nil)
            case .update:
                guard let l else { return (.none, nil, "Only on the right") }
                guard let r else { return (.toRight, nil, nil) }
                if l.folder != r.folder { return (.none, fileAndFolder, nil) }
                guard scan.differ(key, l, r) else { return (.none, nil, nil) }
                switch newer(l, r) {
                case .toRight?: return (.toRight, nil, nil)
                case .toLeft?: return (.none, nil, "Newer on the right")
                default: return scan.comparison == .content ? (.toRight, nil, nil) : (.none, sameDate, nil)
                }
            case .twoWay:
                switch (l, r) {
                case let (l?, r?):
                    if l.folder != r.folder { return (.none, fileAndFolder, nil) }
                    guard scan.differ(key, l, r) else { return (.none, nil, nil) }
                    if let was {
                        switch (unchanged(key, l, since: was.left, onLeft: true), unchanged(key, r, since: was.right, onLeft: false)) {
                        case (true?, false?): return (.toLeft, nil, nil)
                        case (false?, true?): return (.toRight, nil, nil)
                        case (false?, false?): return (.none, "Changed on both sides", nil)
                        case (true?, true?): break
                        default: return (.none, "Can't tell which side changed", nil)
                        }
                    }
                    // Never synced before: the newer one wins.
                    if let direction = newer(l, r) { return (direction, nil, nil) }
                    return (.none, sameDate, nil)
                case let (l?, nil):
                    // Gone from the right since the last sync: deleted there, unless changed here since.
                    guard let was else { return (.toRight, nil, nil) }
                    switch unchanged(key, l, since: was.left, onLeft: true) {
                    case true?: return (.deleteLeft, nil, nil)
                    case false?: return (.toRight, nil, nil)
                    case nil: return (.none, "Deleted on the right; can't tell whether it changed here", nil)
                    }
                case let (nil, r?):
                    guard let was else { return (.toLeft, nil, nil) }
                    switch unchanged(key, r, since: was.right, onLeft: false) {
                    case true?: return (.deleteRight, nil, nil)
                    case false?: return (.toLeft, nil, nil)
                    case nil: return (.none, "Deleted on the left; can't tell whether it changed here", nil)
                    }
                case (nil, nil):
                    return (.none, nil, nil)
                }
            }
        }

        /// A folder on one side only, knowing what is decided for everything inside it.
        func decideFolder(_ key: String, onLeft: Bool, _ inside: Tally) -> Decision {
            let copy: Action = onLeft ? .toRight : .toLeft
            let delete: Action = onLeft ? .deleteLeft : .deleteRight
            var wanted: Action
            switch mode {
            case .mirror: wanted = onLeft ? .toRight : .deleteRight
            case .update: wanted = onLeft ? .toRight : .none
            case .twoWay:
                // Synced before and gone from the other side since: deleted there,
                // unless something inside is new or changed.
                let was = scan.memory.items[key]
                wanted = was.map { (onLeft ? $0.left : $0.right).folder } == true && !inside.actions.contains(copy) ? delete : copy
            }
            if wanted == .none { return (.none, nil, "Only on the right") }
            let holdsExcluded = shielded.contains(key)
            if wanted == delete && (inside.unreadable || holdsExcluded || !inside.actions.isSubset(of: [delete])) {
                // Something inside stays, so the folder does too.
                if inside.actions.contains(copy) { return (copy, nil, nil) }
                let onlyExcluded = holdsExcluded && !inside.unreadable && inside.actions.isSubset(of: [delete])
                return (.none, nil, onlyExcluded ? "Holds excluded items" : "Some of what is inside stays")
            }
            return (wanted, nil, nil)
        }

        var tallies: [String: Tally] = [:]
        var decided: [String: Decision] = [:]
        var blocked = Set<String>()
        for key in order.reversed() {
            let l = lefts.items[key]
            let r = rights.items[key]
            let unreadable = lefts.unreadable.contains(key) || rights.unreadable.contains(key)
            var inside = tallies[key] ?? Tally()
            if unreadable { inside.unreadable = true }
            var decision: Decision
            if key.contains("/") && scan.isBlocked(parent(key)) {
                blocked.insert(key)
                decision = (.none, nil, nil)
            } else if unreadable && l?.folder != true && r?.folder != true {
                decision = (.none, nil, "Couldn't be read")
            } else if l?.folder == true && r?.folder == true {
                decision = unreadable ? (.none, nil, "Couldn't be read; nothing inside is synced") : (.none, nil, nil)
            } else if l?.folder == true && r == nil {
                decision = decideFolder(key, onLeft: true, inside)
            } else if r?.folder == true && l == nil {
                decision = decideFolder(key, onLeft: false, inside)
            } else {
                decision = decideFile(key, l, r)
                // A folder replaced as a whole must hold nothing unread.
                if let l, let r, l.folder != r.folder, inside.unreadable, decision.action != .none {
                    decision = (.none, nil, "Part of it couldn't be read")
                }
                // Nor may a file take the place of a folder holding something excluded.
                if let l, let r, l.folder != r.folder, shielded.contains(key), decision.action == (l.folder ? Action.toLeft : .toRight) {
                    decision = (.none, nil, "Holds excluded items")
                }
            }
            decided[key] = decision
            var up = tallies[parent(key)] ?? Tally()
            up.actions.insert(decision.action)
            up.actions.formUnion(inside.actions)
            let existing = l ?? r
            up.files += inside.files + (existing?.folder == false ? 1 : 0)
            up.entries += inside.entries + 1
            up.bytes += inside.bytes + (existing?.size ?? 0)
            up.unreadable = up.unreadable || inside.unreadable || blocked.contains(key)
            tallies[parent(key)] = up
        }

        func spelled(_ key: String, on side: Listing, from other: Listing) -> String {
            if side.items[key] != nil { return side.path(key) }
            let name = (other.path(key) as NSString).lastPathComponent
            let above = parent(key)
            return above.isEmpty ? name : spelled(above, on: side, from: other) + "/" + name
        }

        var plan = Plan()
        var skipping: String?
        for key in order {
            if let skipping, key.hasPrefix(skipping + "/") { continue }
            skipping = nil
            if blocked.contains(key) { continue }
            let l = lefts.items[key]
            let r = rights.items[key]
            guard let decision = decided[key] else { continue }
            let unreadable = lefts.unreadable.contains(key) || rights.unreadable.contains(key)
            var inside = tallies[key] ?? Tally()
            if unreadable { inside.unreadable = true }
            let oneSided = (l?.folder == true && r == nil) || (r?.folder == true && l == nil)
            let facing = l != nil && r != nil && l?.folder != r?.folder
            let whole = facing || (oneSided && !inside.unreadable && inside.actions.isSubset(of: [decision.action]))
            if whole { skipping = key }
            if decision.action == .none && decision.conflict == nil && decision.note == nil {
                if l?.folder == false && r?.folder == false { plan.equal += 1 }
                continue
            }
            var choices: [Action] = []
            if !unreadable && !(facing && inside.unreadable) {
                // What would remove a folder holding something excluded isn't offered.
                let keeps = shielded.contains(key)
                if l != nil && !(facing && keeps && r?.folder == true) { choices.append(.toRight) }
                if r != nil && !(facing && keeps && l?.folder == true) { choices.append(.toLeft) }
                let deletable = !inside.unreadable && !keeps && (whole || l?.folder != true && r?.folder != true)
                if deletable && r == nil { choices.append(.deleteLeft) }
                if deletable && l == nil { choices.append(.deleteRight) }
            }
            choices.append(.none)
            plan.rows.append(Row(
                key: key,
                leftPath: spelled(key, on: lefts, from: rights),
                rightPath: spelled(key, on: rights, from: lefts),
                left: l, right: r,
                action: decision.action, conflict: decision.conflict, note: decision.note,
                whole: whole || l?.folder != true && r?.folder != true,
                leftFiles: l?.folder == true ? inside.files : (l == nil ? 0 : 1),
                rightFiles: r?.folder == true ? inside.files : (r == nil ? 0 : 1),
                leftBytes: l?.folder == true ? inside.bytes : l?.size ?? 0,
                rightBytes: r?.folder == true ? inside.bytes : r?.size ?? 0,
                leftEntries: l?.folder == true ? inside.entries : 0,
                rightEntries: r?.folder == true ? inside.entries : 0,
                choices: choices))
        }
        return plan
    }

    // MARK: Remembering

    /// What both sides held when they were last found the same, path by path.
    /// One file per pair of folders, in ~/Library/Application Support/Foldera/Sync,
    /// of a few dozen bytes per item: some megabytes for a hundred thousand files.
    struct Memory: Codable, Equatable {
        struct Pair: Codable, Equatable {
            var left: Item
            var right: Item

            init(left: Item, right: Item) {
                self.left = left
                self.right = right
            }

            /// One [size, date] when both sides are alike, as they are after a sync.
            init(from decoder: Decoder) throws {
                var values = try decoder.unkeyedContainer()
                left = try values.decode(Item.self)
                right = values.isAtEnd ? left : try values.decode(Item.self)
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.unkeyedContainer()
                try values.encode(left)
                if right != left { try values.encode(right) }
            }
        }

        var left = ""
        var right = ""
        var items: [String: Pair] = [:]
        /// SHA-256 of what both sides held, for files last compared by content.
        var hashes: [String: String]?
        /// The shared destination of each symbolic link, in either comparison mode.
        /// Missing in older memory: such a link needs review until compared equal again.
        var targets: [String: String]?

        static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foldera/Sync", isDirectory: true)

        /// The same file whichever side each folder is on.
        private static func file(_ a: URL, _ b: URL) -> URL {
            let pair = [a.key, b.key].sorted().joined(separator: "\n")
            let hash = SHA256.hash(data: Data(pair.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            return folder.appendingPathComponent(hash + ".json")
        }

        static func load(_ left: URL, _ right: URL) -> Memory {
            let fresh = Memory(left: left.key, right: right.key)
            guard let data = try? Data(contentsOf: file(left, right)),
                  let memory = try? JSONDecoder().decode(Memory.self, from: data) else { return fresh }
            if memory.left == left.key && memory.right == right.key { return memory }
            if memory.left == right.key && memory.right == left.key {
                return Memory(left: left.key, right: right.key,
                              items: memory.items.mapValues { Pair(left: $0.right, right: $0.left) },
                              hashes: memory.hashes, targets: memory.targets)
            }
            return fresh
        }

        func save() throws {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.file(URL(fileURLWithPath: left), URL(fileURLWithPath: right)), options: .atomic)
        }

        /// What is the same on both sides now is what they hold in common.
        /// Anything else is remembered as it was, until it is gone from both.
        mutating func remember(_ scan: Scan) {
            var now: [String: Pair] = [:]
            var sums: [String: String] = [:]
            var links: [String: String] = [:]
            for (key, l) in scan.leftSide.items {
                guard !scan.isBlocked(key), let r = scan.rightSide.items[key], scan.same(key, l, r) else { continue }
                now[key] = Pair(left: l, right: r)
                if l.link, let target = scan.leftSide.targets[key] { links[key] = target }
                // What both hold, when it was read; otherwise what was known,
                // as long as nothing about either file moved since.
                if let sum = scan.leftHashes[key], scan.rightHashes[key] == sum {
                    sums[key] = sum
                } else if let old = items[key], old.left == l, old.right == r, let sum = hashes?[key] {
                    sums[key] = sum
                }
            }
            for (key, pair) in items where now[key] == nil {
                if scan.leftSide.items[key] != nil || scan.rightSide.items[key] != nil || scan.isBlocked(key) {
                    now[key] = pair
                    if let sum = hashes?[key] { sums[key] = sum }
                    if let target = targets?[key] { links[key] = target }
                }
            }
            items = now
            hashes = sums.isEmpty ? nil : sums
            targets = links.isEmpty ? nil : links
        }
    }

    // MARK: Synchronizing

    /// Does what the rows say: copies first, in order, so folders come before
    /// what goes in them; deletions last, deepest first. Whatever is
    /// replaced or deleted must still be as the compare found it, all the way down.
    final class Job {
        struct Outcome {
            var changes: [Change] = []
            var events: [SyncLibrary.Event] = []
            var failures: [String] = []
            var copied = 0
            var deleted = 0
            var cancelled = false
            /// Both folders read again afterwards, compared as before, so what
            /// is now the same is remembered even if nobody compares again.
            var scan: Scan?
        }

        let scan: Scan
        let rows: [Row]
        let permanently: Bool
        var left: URL { scan.left }
        var right: URL { scan.right }
        var isCancelled: Bool { cancelled.isSet }
        private let cancelled = CancelFlag()
        private let copier: TreeCopier
        // Touched only from the worker thread.
        private var progress = Transfer.Progress()
        private var base: Int64 = 0
        private var trashFailed = false
        private var lastPublished = Date.distantPast
        private var report: ((Transfer.Progress) -> Void)?

        init(_ scan: Scan, rows: [Row], permanently: Bool) {
            self.scan = scan
            self.rows = rows.filter { $0.action != .none }
            self.permanently = permanently
            copier = TreeCopier(cancelled: cancelled)
            copier.copied = { [unowned self] bytes in
                self.progress.bytesDone = self.base + bytes
                self.publish(force: false)
            }
            copier.waiting = { [unowned self] waiting in
                self.progress.waiting = waiting
                self.publish(force: true)
            }
            // What the compare left out stays out of a folder copied whole.
            let exclusion = scan.exclusion
            copier.skips = { Sync.isIgnored($0, atTop: false) || exclusion.excludes($0) }
        }

        func cancel() { cancelled.set() }

        func run(progress report: @escaping (Transfer.Progress) -> Void, done: @escaping (Outcome) -> Void) {
            self.report = report
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self.perform()
                DispatchQueue.main.async { done(outcome) }
            }
        }

        /// Does it all on the calling thread (`run` calls it in the background).
        func perform() -> Outcome {
            var outcome = Outcome()
            // The same two folders, where they were: not another drive mounted in their place.
            guard Sync.identity(of: left) == scan.leftIdentity, Sync.identity(of: right) == scan.rightIdentity,
                  Sync.realPath(left) == left.path, Sync.realPath(right) == right.path else {
                outcome.failures = ["One of the folders is no longer where it was when compared. Compare again."]
                return outcome
            }
            let copies = rows.filter { $0.action == .toRight || $0.action == .toLeft }
            let deletions = rows.filter { $0.action == .deleteLeft || $0.action == .deleteRight }
            progress.bytesTotal = copies.reduce(0) { $0 + $1.bytesToCopy }
            progress.itemsTotal = rows.count
            progress.preparing = false
            publish(force: true)

            func step(_ row: Row, _ work: (Row) throws -> Void) -> Bool {
                if cancelled.isSet {
                    outcome.cancelled = true
                    return false
                }
                progress.current = row.name
                base = progress.bytesDone
                publish(force: true)
                let failuresBefore = outcome.failures.count
                do {
                    try work(row)
                } catch is CancellationError {
                    outcome.events.append(SyncLibrary.Event(row, error: "Stopped before this action finished."))
                    outcome.cancelled = true
                    return false
                } catch {
                    outcome.failures.append("“\(row.name)”: \(error.localizedDescription)")
                }
                let errors = outcome.failures.dropFirst(failuresBefore).joined(separator: "\n")
                outcome.events.append(SyncLibrary.Event(row, error: errors.isEmpty ? nil : errors))
                progress.bytesDone = base + row.bytesToCopy
                progress.itemsDone += 1
                return true
            }
            for row in copies {
                if !step(row, { try copy($0, into: &outcome) }) { break }
            }
            if !outcome.cancelled {
                for row in deletions.reversed() {
                    if !step(row, { try delete($0, into: &outcome) }) { break }
                }
            }
            if trashFailed {
                outcome.failures.append("Some items couldn't be moved to the Trash; network drives often have none. With “Delete files permanently” they can be synced.")
            }
            if !cancelled.isSet {
                progress.current = "Checking the result…"
                publish(force: true)
                outcome.scan = try? Sync.compare(left, right, by: scan.comparison, excluding: scan.exclusion,
                                                 cancelled: cancelled) { [unowned self] text in
                    self.progress.current = text
                    self.publish(force: false)
                }
            }
            return outcome
        }

        private func url(_ row: Row, onLeft: Bool) -> URL {
            onLeft ? left.appendingPathComponent(row.leftPath) : right.appendingPathComponent(row.rightPath)
        }

        /// Nothing is read or written through a folder that has become a
        /// symbolic link since the compare: that could lead outside both folders.
        private func guardInside(_ url: URL, onLeft: Bool) throws {
            let root = onLeft ? left : right
            let folder = url.deletingLastPathComponent()
            guard Sync.realPath(folder) == folder.path, folder.path == root.path || folder.path.hasPrefix(root.path + "/") else {
                throw OpError("The folder it is in isn't where it was when compared (it may now be a link), so it was left alone.")
            }
        }

        private func copy(_ row: Row, into outcome: inout Outcome) throws {
            let toRight = row.action == .toRight
            let source = url(row, onLeft: toRight)
            let target = url(row, onLeft: !toRight)
            let side = toRight ? "right" : "left"
            if row.isFolderOnly {
                outcome.changes += try makeFolders(target, below: toRight ? right : left)
                outcome.copied += 1
                return
            }
            try guardInside(source, onLeft: toRight)
            // A file goes over as it was compared, or not at all. (A folder
            // copied whole takes what is in it now, but for what is never synced.)
            if let from = toRight ? row.left : row.right, !from.folder, try !unchanged(row, onLeft: toRight, at: source) {
                throw OpError("It changed on the \(toRight ? "left" : "right") since the comparison, so it wasn't copied.")
            }
            guard let expected = toRight ? row.right : row.left else {
                outcome.changes += try makeFolders(target.deletingLastPathComponent(), below: toRight ? right : left)
                try guardInside(target, onLeft: !toRight)
                try copier.copy(source, to: target)
                outcome.changes.append(.created(target))
                outcome.failures += copier.errors
                outcome.copied += 1
                return
            }
            // A replacement: the new version is copied in beside the old one
            // first, so a failed copy leaves the old one as it was.
            let changed = OpError("\(expected.folder ? "Something inside it" : "It") changed on the \(side) since the comparison, so it was left alone.")
            try guardInside(target, onLeft: !toRight)
            guard try unchanged(row, onLeft: !toRight, at: target) else { throw changed }
            let partial = target.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)\(Sync.partialSuffix)")
            try copier.copy(source, to: partial)
            guard copier.errors.isEmpty else {
                try? FileManager.default.removeItem(at: partial)
                throw OpError(copier.errors.joined(separator: " "))
            }
            do {
                // Looked at again right before it goes: the copy may have taken a while.
                try guardInside(target, onLeft: !toRight)
                guard try unchanged(row, onLeft: !toRight, at: target) else { throw changed }
                if let change = try remove(target) { outcome.changes.append(change) }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
            guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                let problem = String(cString: strerror(errno))
                outcome.changes.append(.created(partial))
                throw OpError("The new version couldn't be put in place (\(problem)); it is in “\(partial.lastPathComponent)”.")
            }
            outcome.changes.append(.created(target))
            outcome.copied += 1
        }

        private func delete(_ row: Row, into outcome: inout Outcome) throws {
            let onLeft = row.action == .deleteLeft
            let target = url(row, onLeft: onLeft)
            guard let expected = onLeft ? row.left : row.right else { return }
            // It is deleted because the other side doesn't have it. Back there since, it stays.
            let other = url(row, onLeft: !onLeft)
            guard !FileOps.exists(other) else {
                throw OpError("It is on the \(onLeft ? "right" : "left") again since the comparison, so it wasn't deleted.")
            }
            try guardInside(target, onLeft: onLeft)
            guard try unchanged(row, onLeft: onLeft, at: target) else {
                let side = onLeft ? "left" : "right"
                throw OpError("\(expected.folder ? "Something inside it" : "It") changed on the \(side) since the comparison, so it was left alone.")
            }
            if let change = try remove(target) { outcome.changes.append(change) }
            outcome.deleted += 1
        }

        /// What is at `url` is exactly what the compare found there: the same
        /// file, untouched since (see `Stamp`), not merely the same size and
        /// about the same date. A folder is read again, to the bottom: a file
        /// added deep inside it since leaves the folder's own date as it was.
        private func unchanged(_ row: Row, onLeft: Bool, at url: URL) throws -> Bool {
            let side = onLeft ? scan.leftSide : scan.rightSide
            guard let expected = onLeft ? row.left : row.right, let now = Sync.item(at: url) else { return false }
            guard expected.folder else { return now == expected && Sync.stamp(at: url) == side.stamps[row.key] }
            guard now.folder else { return false }
            let found: Listing
            do {
                found = try Sync.list(url, ignoreCase: scan.ignoreCase, top: false, excluding: scan.exclusion, cancelled: cancelled)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return false
            }
            // Something excluded put in it since would go with it: then it stays.
            guard found.unreadable.isEmpty, found.excluded.isEmpty,
                  found.items.count == (onLeft ? row.leftEntries : row.rightEntries) else { return false }
            return found.items.allSatisfy { key, item in
                let whole = row.key + "/" + key
                guard let was = side.items[whole] else { return false }
                return item.folder ? was.folder : item == was && found.stamps[key] == side.stamps[whole]
            }
        }

        /// Out of the way: to the Trash (Undo brings it back), or gone for good.
        private func remove(_ url: URL) throws -> Change? {
            if permanently {
                try FileManager.default.removeItem(at: url)
                return nil
            }
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            } catch {
                trashFailed = true
                throw error
            }
            return trashed.map { .moved(from: url, to: $0 as URL) }
        }

        /// Makes `folder` and whatever above it is missing, but never above `root`.
        private func makeFolders(_ folder: URL, below root: URL) throws -> [Change] {
            var missing: [URL] = []
            var url = folder
            while !FileOps.exists(url) {
                // Paths as built, not `key`s: standardizing drops /private only from paths that exist.
                guard url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                    throw OpError("“\(root.lastPathComponent)” is no longer there.")
                }
                missing.insert(url, at: 0)
                url = url.deletingLastPathComponent()
            }
            // What is there already must be a real folder inside the root, not a link out of it.
            guard Sync.realPath(url) == url.path, url.path == root.path || url.path.hasPrefix(root.path + "/") else {
                throw OpError("“\(url.lastPathComponent)” isn't where it was when compared (it may now be a link), so nothing was put in it.")
            }
            for url in missing { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            return missing.map { .created($0) }
        }

        private func publish(force: Bool) {
            let now = Date()
            guard force || now.timeIntervalSince(lastPublished) > 0.1 else { return }
            lastPublished = now
            let snapshot = progress
            let report = report
            DispatchQueue.main.async { report?(snapshot) }
        }
    }
}

/// Stored as [size, date]: a folder with size −1, a symbolic link with a 1 after the date.
extension Sync.Item: Codable {
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let size = try values.decode(Int64.self)
        let modified = try values.decode(Double.self)
        let link = values.isAtEnd ? false : try values.decode(Int.self) == 1
        self.init(folder: size < 0, size: max(size, 0), modified: modified, link: link)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(folder ? -1 : size)
        try values.encode(modified)
        if link { try values.encode(1) }
    }
}
