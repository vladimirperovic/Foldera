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
/// Nothing inside a folder that couldn't be read is touched.
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

        init(folder: Bool, size: Int64, modified: Double) {
            self.folder = folder
            self.size = size
            self.modified = modified
        }

        init(_ values: URLResourceValues) {
            folder = values.isDirectory == true && values.isSymbolicLink != true
            size = folder ? 0 : Int64(values.fileSize ?? 0)
            modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        }

        /// The same as far as size and date tell.
        func matches(_ other: Item) -> Bool {
            folder == other.folder && (folder || (size == other.size && abs(modified - other.modified) <= Sync.tolerance))
        }
    }

    /// FAT drives keep dates to two seconds.
    static let tolerance: Double = 2

    /// Half-copied replacements are named so; they are never synced.
    static let partialSuffix = ".foldera-sync"

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

    /// What is at `url` now, if anything.
    static func item(at url: URL) -> Item? {
        (try? url.resourceValues(forKeys: Set(keys))).map(Item.init)
    }

    /// Never synced: Finder's and the drive's own bookkeeping.
    static func isIgnored(_ name: String, atTop: Bool) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name.hasSuffix(partialSuffix) || (atTop && driveNames.contains(name))
    }

    private static let driveNames: Set<String> = [
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".VolumeIcon.icns", ".apdisk",
    ]

    // MARK: Reading both sides

    /// One folder, read to the bottom.
    struct Listing {
        /// By key: the path inside the folder, lowercased when names are compared ignoring case.
        var items: [String: Item] = [:]
        /// The path as this side spells it, where that differs from the key.
        var spelled: [String: String] = [:]
        /// Folders whose contents couldn't be read, and items that couldn't be looked at.
        var unreadable: Set<String> = []
        var problems: [String] = []

        func path(_ key: String) -> String { spelled[key] ?? key }

        var files: Int { items.values.filter { !$0.folder }.count }
    }

    /// What a compare found.
    struct Scan {
        let left: URL
        let right: URL
        let comparison: Comparison
        var leftSide = Listing()
        var rightSide = Listing()
        /// Files of equal size read byte by byte (Content only): key → the same.
        var sameContent: [String: Bool] = [:]
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
            if l.size != r.size { return true }
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
    static func compare(_ left: URL, _ right: URL, by comparison: Comparison, cancelled: CancelFlag,
                        progress: @escaping (String) -> Void = { _ in }) throws -> Scan {
        // A folder chosen through a symbolic link is read, and synced, where it really is.
        let left = left.resolvingSymlinksInPath()
        let right = right.resolvingSymlinksInPath()
        let ignoreCase = !(caseSensitive(left) && caseSensitive(right))
        var last = Date.distantPast
        func report(_ text: @autoclosure () -> String) {
            guard Date().timeIntervalSince(last) > 0.1 else { return }
            last = Date()
            progress(text())
        }
        var scan = Scan(left: left, right: right, comparison: comparison)
        scan.leftSide = try list(left, ignoreCase: ignoreCase, cancelled: cancelled) {
            report("Reading “\(left.lastPathComponent)”… \(Format.items($0))")
        }
        scan.rightSide = try list(right, ignoreCase: ignoreCase, cancelled: cancelled) {
            report("Reading “\(right.lastPathComponent)”… \(Format.items($0))")
        }
        if comparison == .content {
            let keys = scan.leftSide.items.compactMap { key, l -> String? in
                guard !l.folder, let r = scan.rightSide.items[key], !r.folder, l.size == r.size else { return nil }
                return key
            }.sorted()
            for (index, key) in keys.enumerated() {
                if cancelled.isSet { throw CancellationError() }
                report("Comparing contents… \(Format.count(Int64(index + 1))) of \(Format.count(Int64(keys.count)))")
                let a = left.appendingPathComponent(scan.leftSide.path(key))
                let b = right.appendingPathComponent(scan.rightSide.path(key))
                // A symbolic link is compared as a link: by size and date.
                if isLink(a) || isLink(b) { continue }
                if let same = sameBytes(a, b, cancelled: cancelled) {
                    scan.sameContent[key] = same
                } else if !cancelled.isSet {
                    scan.leftSide.unreadable.insert(key)
                    scan.leftSide.problems.append("“\(scan.leftSide.path(key))” couldn't be read on both sides.")
                }
            }
        }
        if cancelled.isSet { throw CancellationError() }
        scan.memory = Memory.load(left, right)
        scan.memory.remember(scan)
        try? scan.memory.save()
        return scan
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func list(_ root: URL, ignoreCase: Bool, cancelled: CancelFlag, found: (Int) -> Void = { _ in }) throws -> Listing {
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
            if isIgnored(url.lastPathComponent, atTop: !path.contains("/")) {
                walker?.skipDescendants()
                continue
            }
            let key = ignoreCase ? path.lowercased() : path
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
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
            listing.items[key] = Item(values)
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

    /// Byte by byte; nil when either can't be read.
    static func sameBytes(_ a: URL, _ b: URL, cancelled: CancelFlag) -> Bool? {
        guard let x = FileHandle(forReadingAtPath: a.path), let y = FileHandle(forReadingAtPath: b.path) else { return nil }
        defer {
            try? x.close()
            try? y.close()
        }
        do {
            while !cancelled.isSet {
                let p = try x.read(upToCount: 1 << 20) ?? Data()
                let q = try y.read(upToCount: 1 << 20) ?? Data()
                if p != q { return false }
                if p.isEmpty { return true }
            }
        } catch {}
        return nil
    }

    // MARK: Deciding

    enum Action { case none, toRight, toLeft, deleteLeft, deleteRight }

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
    }

    /// What a folder holds, as far as deciding about the folder goes.
    private struct Tally {
        var actions = Set<Action>()
        var files = 0
        var bytes: Int64 = 0
        var unreadable = false
    }

    static func plan(_ scan: Scan, mode: Mode) -> Plan {
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

        func newer(_ l: Item, _ r: Item) -> Action? {
            if l.modified > r.modified + tolerance { return .toRight }
            if r.modified > l.modified + tolerance { return .toLeft }
            return nil
        }
        let sameDate = scan.comparison == .content ? "Same date, different content" : "Same date, different size"
        let fileAndFolder = "A file on one side, a folder on the other"

        typealias Decision = (action: Action, conflict: String?, note: String?)

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
                        let leftSame = l.matches(was.left)
                        let rightSame = r.matches(was.right)
                        if leftSame && !rightSame { return (.toLeft, nil, nil) }
                        if rightSame && !leftSame { return (.toRight, nil, nil) }
                        if !leftSame && !rightSame { return (.none, "Changed on both sides", nil) }
                    }
                    // Never synced before: the newer one wins.
                    if let direction = newer(l, r) { return (direction, nil, nil) }
                    return (.none, sameDate, nil)
                case let (l?, nil):
                    // Gone from the right since the last sync: deleted there, unless changed here since.
                    if let was, l.matches(was.left) { return (.deleteLeft, nil, nil) }
                    return (.toRight, nil, nil)
                case let (nil, r?):
                    if let was, r.matches(was.right) { return (.deleteRight, nil, nil) }
                    return (.toLeft, nil, nil)
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
            if wanted == delete && (inside.unreadable || !inside.actions.isSubset(of: [delete])) {
                // Something inside stays, so the folder does too.
                return inside.actions.contains(copy) ? (copy, nil, nil) : (.none, nil, "Some of what is inside stays")
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
            }
            decided[key] = decision
            var up = tallies[parent(key)] ?? Tally()
            up.actions.insert(decision.action)
            up.actions.formUnion(inside.actions)
            let existing = l ?? r
            up.files += inside.files + (existing?.folder == false ? 1 : 0)
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
                if l != nil { choices.append(.toRight) }
                if r != nil { choices.append(.toLeft) }
                let deletable = !inside.unreadable && (whole || l?.folder != true && r?.folder != true)
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
                choices: choices))
        }
        return plan
    }

    // MARK: Remembering

    /// What both sides held when they were last found the same, path by path.
    /// One small file per pair of folders, in ~/Library/Application Support/Foldera/Sync.
    struct Memory: Codable {
        struct Pair: Codable {
            var left: Item
            var right: Item
        }

        var left = ""
        var right = ""
        var items: [String: Pair] = [:]

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
                              items: memory.items.mapValues { Pair(left: $0.right, right: $0.left) })
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
            for (key, l) in scan.leftSide.items {
                if let r = scan.rightSide.items[key], scan.same(key, l, r) { now[key] = Pair(left: l, right: r) }
            }
            for (key, pair) in items where now[key] == nil {
                if scan.leftSide.items[key] != nil || scan.rightSide.items[key] != nil || scan.isBlocked(key) { now[key] = pair }
            }
            items = now
        }
    }

    // MARK: Synchronizing

    /// Does what the rows say: copies first, in order, so folders come before
    /// what goes in them; deletions last, deepest first. Whatever is
    /// replaced or deleted must still be as the compare found it.
    final class Job {
        struct Outcome {
            var changes: [Change] = []
            var failures: [String] = []
            var copied = 0
            var deleted = 0
            var cancelled = false
            /// Both folders read again afterwards, by date and size, so what is
            /// now the same is remembered even if nobody compares again.
            var scan: Scan?
        }

        let left: URL
        let right: URL
        let rows: [Row]
        let permanently: Bool
        private let cancelled = CancelFlag()
        private let copier: TreeCopier
        // Touched only from the worker thread.
        private var progress = Transfer.Progress()
        private var base: Int64 = 0
        private var trashFailed = false
        private var lastPublished = Date.distantPast
        private var report: ((Transfer.Progress) -> Void)?

        init(left: URL, right: URL, rows: [Row], permanently: Bool) {
            self.left = left
            self.right = right
            self.rows = rows.filter { $0.action != .none }
            self.permanently = permanently
            copier = TreeCopier(cancelled: cancelled)
            copier.copied = { [unowned self] bytes in
                self.progress.bytesDone = self.base + bytes
                self.publish(force: false)
            }
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
            guard FileOps.exists(left), FileOps.exists(right) else {
                outcome.failures = ["One of the folders is no longer there."]
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
                do {
                    try work(row)
                } catch is CancellationError {
                    outcome.cancelled = true
                    return false
                } catch {
                    outcome.failures.append("“\(row.name)”: \(error.localizedDescription)")
                }
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
            progress.current = "Checking the result…"
            publish(force: true)
            outcome.scan = try? Sync.compare(left, right, by: .dateAndSize, cancelled: CancelFlag())
            return outcome
        }

        private func url(_ row: Row, onLeft: Bool) -> URL {
            onLeft ? left.appendingPathComponent(row.leftPath) : right.appendingPathComponent(row.rightPath)
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
            guard let expected = toRight ? row.right : row.left else {
                outcome.changes += try makeFolders(target.deletingLastPathComponent(), below: toRight ? right : left)
                try copier.copy(source, to: target)
                outcome.changes.append(.created(target))
                outcome.failures += copier.errors
                outcome.copied += 1
                return
            }
            // A replacement: the new version is copied in beside the old one
            // first, so a failed copy leaves the old one as it was.
            guard let now = Sync.item(at: target), now.matches(expected) else {
                throw OpError("It changed on the \(side) since the comparison, so it was left alone.")
            }
            let partial = target.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString.prefix(8))-\(target.lastPathComponent)\(Sync.partialSuffix)")
            try copier.copy(source, to: partial)
            guard copier.errors.isEmpty else {
                try? FileManager.default.removeItem(at: partial)
                throw OpError(copier.errors.joined(separator: " "))
            }
            do {
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
            guard let now = Sync.item(at: target), now.matches(expected) else {
                throw OpError("It changed on the \(onLeft ? "left" : "right") since the comparison, so it was left alone.")
            }
            if let change = try remove(target) { outcome.changes.append(change) }
            outcome.deleted += 1
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
                guard url.key.hasPrefix(root.key == "/" ? "/" : root.key + "/") else {
                    throw OpError("“\(root.lastPathComponent)” is no longer there.")
                }
                missing.insert(url, at: 0)
                url = url.deletingLastPathComponent()
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

/// Stored as [size, date], a folder with size −1: the memory of a big folder stays small.
extension Sync.Item: Codable {
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let size = try values.decode(Int64.self)
        self.init(folder: size < 0, size: max(size, 0), modified: try values.decode(Double.self))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(folder ? -1 : size)
        try values.encode(modified)
    }
}
