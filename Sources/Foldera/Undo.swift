import AppKit

/// One reversible change to the file system.
enum Change {
    case moved(from: URL, to: URL)
    /// Something new: a copy, a new folder, an unzipped folder. Undone by the Trash.
    case created(URL)
    /// A folder left empty by a move and removed. Undone by making it again.
    case removedFolder(URL)
}

/// ⌘Z for files. Every copy, move, rename, new item and trip to the Trash
/// is recorded, and undone newest first; ⇧⌘Z does it again. One history for
/// the whole app, as in Finder.
enum FileUndo {
    /// UndoManager needs its inverse registered during undo/redo. Keep it
    /// unavailable until the asynchronous work has filled in that inverse.
    final class Manager: UndoManager {
        fileprivate(set) var isBusy = false
        fileprivate var pendingRecords: [() -> Void] = []
        override var canUndo: Bool { !isBusy && super.canUndo }
        override var canRedo: Bool { !isBusy && super.canRedo }
        override func undo() { if !isBusy { super.undo() } }
        override func redo() { if !isBusy { super.redo() } }

        fileprivate func finished() {
            isBusy = false
            let records = pendingRecords
            pendingRecords = []
            records.forEach { $0() }
        }
    }

    static let manager: Manager = {
        let manager = Manager()
        manager.levelsOfUndo = 100
        return manager
    }()

    private static let token = NSObject()

    /// A path can be reused by another app between recording an operation
    /// and Undo. Edits to the same entry are allowed, but a different entry
    /// must never be moved or sent to the Trash in its place.
    private struct ItemIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let kind: mode_t

        static func read(_ url: URL) -> ItemIdentity? {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return nil }
            return ItemIdentity(device: value.st_dev, inode: value.st_ino, kind: value.st_mode & S_IFMT)
        }
    }

    private struct GuardedChange {
        let change: Change
        let expected: ItemIdentity?
    }

    /// An immutable filesystem snapshot, prepared by the worker before its
    /// result reaches the main thread. Registration only touches Undo/UI state.
    struct Prepared {
        private let changes: [GuardedChange]
        fileprivate init(_ source: [Change]) { changes = FileUndo.bind(source) }
        fileprivate func register(name: String, in manager: Manager) {
            FileUndo.record(changes, name: name, in: manager)
        }
    }

    static func prepare(_ changes: [Change]) -> Prepared { Prepared(changes) }

    static func record(_ prepared: Prepared, name: String, in manager: Manager = manager) {
        prepared.register(name: name, in: manager)
    }

    private struct LocatedItem {
        let identity: ItemIdentity
        /// The present-day location backing a path in the simulated history.
        let url: URL
    }

    private enum LocationState {
        case absent
        case item(LocatedItem)
        var item: LocatedItem? {
            if case let .item(value) = self { return value }
            return nil
        }
    }

    /// Rename Many records a -> temporary -> b after temporary is gone.
    /// Walk the history backwards to carry the final entry's identity to
    /// each earlier name, including name swaps and replacement groups.
    private static func bind(_ changes: [Change]) -> [GuardedChange] {
        var locations: [String: LocationState] = [:]
        func item(_ url: URL) -> LocatedItem? {
            if let state = locations[url.key] { return state.item }
            // Moving a directory changes every descendant's address. An
            // earlier child rename must be looked up beneath its parent's
            // final location, not at a path that no longer exists on disk.
            var ancestor = url.deletingLastPathComponent()
            while true {
                if let state = locations[ancestor.key] {
                    guard let parent = state.item else { return nil }
                    let suffix = url.key.dropFirst(ancestor.key == "/" ? 1 : ancestor.key.count + 1)
                    let actual = parent.url.appendingPathComponent(String(suffix))
                    return ItemIdentity.read(actual).map { LocatedItem(identity: $0, url: actual) }
                }
                guard ancestor.key != "/" else { break }
                ancestor = ancestor.deletingLastPathComponent()
            }
            return ItemIdentity.read(url).map { LocatedItem(identity: $0, url: url) }
        }
        func descendants(of url: URL) -> [String: LocationState] {
            locations.filter { $0.key.hasPrefix(url.key == "/" ? "/" : url.key + "/") && $0.key != url.key }
        }
        let bound = changes.reversed().map { change -> GuardedChange in
            switch change {
            case let .moved(from, to):
                let expected = item(to)
                // Ordinary file batches stay linear: only a directory can
                // have historical descendant overrides to move with it.
                let directory = expected?.identity.kind == S_IFDIR
                let children = directory ? descendants(of: to) : [:]
                if directory {
                    for key in children.keys { locations[key] = nil }
                    for key in descendants(of: from).keys { locations[key] = nil }
                }
                locations[to.key] = .absent
                locations[from.key] = expected.map(LocationState.item) ?? .absent
                for (key, state) in children {
                    locations[from.key + key.dropFirst(to.key.count)] = state
                }
                return GuardedChange(change: change, expected: expected?.identity)
            case let .created(url):
                let expected = item(url)
                if expected?.identity.kind == S_IFDIR {
                    for key in descendants(of: url).keys { locations[key] = nil }
                }
                locations[url.key] = .absent
                return GuardedChange(change: change, expected: expected?.identity)
            case .removedFolder:
                return GuardedChange(change: change, expected: nil)
            }
        }
        return bound.reversed()
    }

    private static func inverse(_ change: Change) -> GuardedChange {
        switch change {
        case let .moved(_, to): return GuardedChange(change: change, expected: ItemIdentity.read(to))
        case let .created(url): return GuardedChange(change: change, expected: ItemIdentity.read(url))
        case .removedFolder: return GuardedChange(change: change, expected: nil)
        }
    }

    static func record(_ changes: [Change], name: String, in manager: Manager = manager) {
        record(prepare(changes), name: name, in: manager)
    }

    private static func record(_ changes: [GuardedChange], name: String, in manager: Manager) {
        guard !changes.isEmpty else { return }
        invalidateSizes(changes.map(\.change))
        if manager.isBusy {
            manager.pendingRecords.append { record(changes, name: name, in: manager) }
            return
        }
        manager.registerUndo(withTarget: token) { _ in revert(changes, name: name, in: manager) }
        manager.setActionName(name)
    }

    /// Puts things back, newest first. What it does is recorded in turn,
    /// which is how redo works.
    ///
    /// A move across drives is a copy that takes a while, so from the first
    /// of those on the steps go on in the background, still one after
    /// another: a step that needs a place an earlier one frees (the old file
    /// coming back where a replacing one stood) finds it free. Redo is
    /// registered at once, as the undo manager expects, and takes back
    /// exactly what succeeded, including what the background part adds.
    private static func revert(_ changes: [GuardedChange], name: String, in manager: Manager) {
        let steps = Array(changes.reversed())
        let slowFrom = steps.firstIndex { isSlow($0.change) } ?? steps.count
        let done = Done()
        var failures: [String] = []
        for change in steps[..<slowFrom] { undo(change, into: &done.changes, failures: &failures) }
        invalidateSizes(done.changes.map(\.change))
        manager.registerUndo(withTarget: token) { _ in revert(done.changes, name: name, in: manager) }
        manager.setActionName(name)
        DispatchQueue.main.async { FileOps.report(failures) }
        guard slowFrom < steps.count else { return }
        manager.isBusy = true
        let rest = Array(steps[slowFrom...])
        DispatchQueue.global(qos: .userInitiated).async {
            var back: [GuardedChange] = []
            var problems: [String] = []
            for change in rest { undo(change, into: &back, failures: &problems) }
            DispatchQueue.main.async {
                done.changes += back
                invalidateSizes(back.map(\.change))
                manager.finished()
                FileOps.report(problems)
            }
        }
    }

    /// What an undo managed, filled in as it goes (see `revert`).
    private final class Done { var changes: [GuardedChange] = [] }

    private static func invalidateSizes(_ changes: [Change]) {
        for change in changes {
            switch change {
            case let .moved(from, to):
                UsageCache.changed(from)
                UsageCache.changed(to)
            case let .created(url), let .removedFolder(url):
                UsageCache.changed(url)
            }
        }
    }

    private static func isSlow(_ change: Change) -> Bool {
        guard case let .moved(from, to) = change else { return false }
        // A rename within one folder never copies, even when one of its names
        // is only there at another step (Rename Many goes by temporary names).
        if from.deletingLastPathComponent().key == to.deletingLastPathComponent().key { return false }
        return !DragOps.sameVolume(to, from.deletingLastPathComponent())
    }

    /// Undoes one change, on whichever thread; what it did goes into `back`.
    private static func undo(_ guarded: GuardedChange, into back: inout [GuardedChange], failures: inout [String]) {
        let fm = FileManager.default
        let change = guarded.change
        switch change {
        case let .moved(from, to):
            guard FileOps.exists(to) else {
                return failures.append("“\(to.lastPathComponent)” is no longer where it was put.")
            }
            guard let expected = guarded.expected, ItemIdentity.read(to) == expected else {
                return failures.append("“\(to.lastPathComponent)” was replaced since this operation, so it was left alone.")
            }
            // "readme.md" → "README.md" on a drive that ignores case: both names are the one file.
            if FileOps.isSameItem(from, to) {
                if renamex_np(to.path, from.path, UInt32(RENAME_EXCL)) == 0 {
                    back.append(inverse(.moved(from: to, to: from)))
                } else {
                    failures.append(String(cString: strerror(errno)))
                }
                return
            }
            guard !FileOps.exists(from) else {
                return failures.append("Something named “\(from.lastPathComponent)” is already in its old place.")
            }
            do {
                try fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                if isSlow(change) {
                    let copier = TreeCopier(cancelled: CancelFlag())
                    try copier.copy(to, to: from, verifyingSource: true)
                    // Keep a completed copy undoable even if source removal
                    // fails or its contents changed while crossing volumes.
                    back.append(inverse(.created(from)))
                    guard copier.errors.isEmpty else { throw OpError(copier.errors.joined(separator: "\n")) }
                    try copier.removeCopiedSource(to)
                    back[back.count - 1] = inverse(.moved(from: to, to: from))
                } else {
                    guard renamex_np(to.path, from.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    back.append(inverse(.moved(from: to, to: from)))
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        case let .created(url):
            guard FileOps.exists(url) else { return }
            guard let expected = guarded.expected, ItemIdentity.read(url) == expected else {
                return failures.append("“\(url.lastPathComponent)” was replaced since this operation, so it was left alone.")
            }
            do {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { back.append(inverse(.moved(from: url, to: trashed as URL))) }
            } catch {
                failures.append(error.localizedDescription)
            }
        case let .removedFolder(url):
            guard !FileOps.exists(url) else {
                return failures.append("Something named “\(url.lastPathComponent)” is already in its old place.")
            }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                back.append(inverse(.created(url)))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
    }
}
