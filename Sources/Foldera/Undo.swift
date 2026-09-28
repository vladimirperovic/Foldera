import AppKit

/// One reversible change to the file system.
enum Change {
    case moved(from: URL, to: URL)
    /// Something new: a copy, a new folder, an unzipped folder. Undone by the Trash.
    case created(URL)
}

/// ⌘Z for files. Every copy, move, rename, new item and trip to the Trash
/// is recorded, and undone newest first; ⇧⌘Z does it again. One history for
/// the whole app, as in Finder.
enum FileUndo {
    static let manager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()

    private static let token = NSObject()

    static func record(_ changes: [Change], name: String, in manager: UndoManager = manager) {
        guard !changes.isEmpty else { return }
        manager.registerUndo(withTarget: token) { _ in revert(changes, name: name, in: manager) }
        manager.setActionName(name)
    }

    /// Puts things back. What it does is recorded in turn, which is how redo works.
    private static func revert(_ changes: [Change], name: String, in manager: UndoManager) {
        let fm = FileManager.default
        var back: [Change] = []
        var failures: [String] = []
        var slow: [(from: URL, to: URL)] = []
        for change in changes.reversed() {
            switch change {
            case let .moved(from, to):
                guard FileOps.exists(to) else {
                    failures.append("“\(to.lastPathComponent)” is no longer where it was put.")
                    continue
                }
                guard !FileOps.exists(from) else {
                    failures.append("Something named “\(from.lastPathComponent)” is already in its old place.")
                    continue
                }
                do {
                    try fm.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if DragOps.sameVolume(to, from.deletingLastPathComponent()) {
                        try fm.moveItem(at: to, to: from)
                    } else {
                        // Across drives a move is a copy: do it in the background.
                        slow.append((to, from))
                    }
                    back.append(.moved(from: to, to: from))
                } catch {
                    failures.append(error.localizedDescription)
                }
            case let .created(url):
                guard FileOps.exists(url) else { continue }
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                    if let trashed { back.append(.moved(from: url, to: trashed as URL)) }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        }
        record(back, name: name, in: manager)
        if !slow.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                var problems: [String] = []
                for move in slow {
                    do { try FileManager.default.moveItem(at: move.from, to: move.to) } catch { problems.append(error.localizedDescription) }
                }
                DispatchQueue.main.async { FileOps.report(problems) }
            }
        }
        DispatchQueue.main.async { FileOps.report(failures) }
    }
}
