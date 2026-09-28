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

    static func record(_ changes: [Change], name: String, in manager: Manager = manager) {
        guard !changes.isEmpty else { return }
        invalidateSizes(changes)
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
    private static func revert(_ changes: [Change], name: String, in manager: Manager) {
        let steps = Array(changes.reversed())
        let slowFrom = steps.firstIndex(where: isSlow) ?? steps.count
        let done = Done()
        var failures: [String] = []
        for change in steps[..<slowFrom] { undo(change, into: &done.changes, failures: &failures) }
        invalidateSizes(done.changes)
        manager.registerUndo(withTarget: token) { _ in revert(done.changes, name: name, in: manager) }
        manager.setActionName(name)
        DispatchQueue.main.async { FileOps.report(failures) }
        guard slowFrom < steps.count else { return }
        manager.isBusy = true
        let rest = Array(steps[slowFrom...])
        DispatchQueue.global(qos: .userInitiated).async {
            var back: [Change] = []
            var problems: [String] = []
            for change in rest { undo(change, into: &back, failures: &problems) }
            DispatchQueue.main.async {
                done.changes += back
                invalidateSizes(back)
                manager.finished()
                FileOps.report(problems)
            }
        }
    }

    /// What an undo managed, filled in as it goes (see `revert`).
    private final class Done { var changes: [Change] = [] }

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
        return !DragOps.sameVolume(to, from.deletingLastPathComponent())
    }

    /// Undoes one change, on whichever thread; what it did goes into `back`.
    private static func undo(_ change: Change, into back: inout [Change], failures: inout [String]) {
        let fm = FileManager.default
        switch change {
        case let .moved(from, to):
            guard FileOps.exists(to) else {
                return failures.append("“\(to.lastPathComponent)” is no longer where it was put.")
            }
            guard !FileOps.exists(from) else {
                return failures.append("Something named “\(from.lastPathComponent)” is already in its old place.")
            }
            do {
                try fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: to, to: from)
                back.append(.moved(from: to, to: from))
            } catch {
                failures.append(error.localizedDescription)
            }
        case let .created(url):
            guard FileOps.exists(url) else { return }
            do {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { back.append(.moved(from: url, to: trashed as URL)) }
            } catch {
                failures.append(error.localizedDescription)
            }
        case let .removedFolder(url):
            guard !FileOps.exists(url) else {
                return failures.append("Something named “\(url.lastPathComponent)” is already in its old place.")
            }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                back.append(.created(url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
    }
}
