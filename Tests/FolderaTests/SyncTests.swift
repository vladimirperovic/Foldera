import Foundation
import Testing
@testable import Foldera

/// Two folders side by side, and a place of their own for Sync's memory.
private final class Pair {
    let root: URL
    let left: URL
    let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaSync-\(UUID().uuidString)")
        Sync.Memory.folder = root.appendingPathComponent("memory", isDirectory: true)
        left = root.appendingPathComponent("left", isDirectory: true)
        right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    /// "L/a.txt" or "R/a.txt"; `age` in seconds before now.
    @discardableResult
    func file(_ path: String, _ text: String = "x", age: TimeInterval = 3600) throws -> URL {
        let url = self.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL {
        let side = path.hasPrefix("L/") ? left : right
        return side.appendingPathComponent(String(path.dropFirst(2)))
    }

    func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileOps.exists(url(path)) }

    func compare(_ by: Sync.Comparison = .dateAndSize) throws -> Sync.Scan {
        try Sync.compare(left, right, by: by, cancelled: CancelFlag())
    }

    func plan(_ mode: Sync.Mode, by: Sync.Comparison = .dateAndSize) throws -> Sync.Plan {
        Sync.plan(try compare(by), mode: mode)
    }

    /// Compare, then Synchronize; deletions are permanent, to leave the Trash alone.
    @discardableResult
    func sync(_ mode: Sync.Mode) throws -> Sync.Job.Outcome {
        let plan = try self.plan(mode)
        return Sync.Job(left: left, right: right, rows: plan.rows, permanently: true).perform()
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private extension Sync.Plan {
    func action(_ name: String) -> Sync.Action? { rows.first { $0.name == name }?.action }
    func row(_ name: String) -> Sync.Row? { rows.first { $0.name == name } }
}

/// One after another: they share where Sync keeps its memory.
@Suite(.serialized) struct SyncFolders {
    @Test func mirrorMakesTheRightAnExactCopy() throws {
        let p = try Pair()
        try p.file("L/new.txt", "new")
        try p.file("L/changed.txt", "left version", age: 60)
        try p.file("R/changed.txt", "old", age: 7200)
        try p.file("L/same.txt", "same")
        try p.file("R/same.txt", "same")
        try p.file("R/extra.txt", "extra")
        try p.file("R/Old stuff/a.txt")
        try p.file("R/Old stuff/b.txt")
        let outcome = try p.sync(.mirror)
        #expect(outcome.failures.isEmpty)
        #expect(p.text("R/new.txt") == "new")
        #expect(p.text("R/changed.txt") == "left version")
        #expect(!p.exists("R/extra.txt"))
        #expect(!p.exists("R/Old stuff"))
        #expect(p.text("L/changed.txt") == "left version")
        #expect(try p.plan(.mirror).rows.isEmpty)
    }

    @Test func mirrorOverwritesANewerFileOnTheRightToo() throws {
        let p = try Pair()
        try p.file("L/a.txt", "left", age: 7200)
        try p.file("R/a.txt", "right, newer", age: 60)
        try p.sync(.mirror)
        #expect(p.text("R/a.txt") == "left")
    }

    @Test func updateCopiesNewAndNewerButDeletesNothing() throws {
        let p = try Pair()
        try p.file("L/new.txt", "new")
        try p.file("L/newer.txt", "left newer", age: 60)
        try p.file("R/newer.txt", "old", age: 7200)
        try p.file("L/older.txt", "left older", age: 7200)
        try p.file("R/older.txt", "right newer", age: 60)
        try p.file("R/only right.txt")
        let plan = try p.plan(.update)
        #expect(plan.row("older.txt")?.note == "Newer on the right")
        #expect(plan.action("only right.txt") == Sync.Action.none)
        try p.sync(.update)
        #expect(p.text("R/new.txt") == "new")
        #expect(p.text("R/newer.txt") == "left newer")
        #expect(p.text("R/older.txt") == "right newer")
        #expect(p.exists("R/only right.txt"))
        #expect(!p.exists("L/only right.txt"))
    }

    @Test func aNewFolderIsOneRowForEverythingInside() throws {
        let p = try Pair()
        try p.file("L/Photos/2025/a.jpg", "aaaa")
        try p.file("L/Photos/2025/b.jpg", "bb")
        try p.file("L/Photos/c.jpg", "c")
        let plan = try p.plan(.mirror)
        #expect(plan.rows.count == 1)
        let row = try #require(plan.row("Photos"))
        #expect(row.whole && row.action == .toRight)
        #expect(row.leftFiles == 3 && row.leftBytes == 7)
        try p.sync(.mirror)
        #expect(p.text("R/Photos/2025/b.jpg") == "bb")
    }

    @Test func twoWayFirstSyncCopiesBothWaysAndTheNewerFileWins() throws {
        let p = try Pair()
        try p.file("L/only left.txt", "L")
        try p.file("R/only right.txt", "R")
        try p.file("L/doc.txt", "newer on the left", age: 60)
        try p.file("R/doc.txt", "older", age: 7200)
        try p.file("L/note.txt", "older", age: 7200)
        try p.file("R/note.txt", "newer on the right", age: 60)
        try p.sync(.twoWay)
        #expect(p.text("R/only left.txt") == "L")
        #expect(p.text("L/only right.txt") == "R")
        #expect(p.text("R/doc.txt") == "newer on the left")
        #expect(p.text("L/note.txt") == "newer on the right")
        #expect(try p.plan(.twoWay).rows.isEmpty)
    }

    @Test func twoWayWithoutMemoryNeverDeletes() throws {
        let p = try Pair()
        try p.file("L/a.txt")
        let plan = try p.plan(.twoWay)
        #expect(plan.action("a.txt") == .toRight)
    }

    @Test func twoWayCarriesADeletionToTheOtherSide() throws {
        let p = try Pair()
        try p.file("L/keep.txt")
        try p.file("L/gone.txt")
        try p.file("L/Old/x.txt")
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("R/gone.txt"))
        try FileManager.default.removeItem(at: p.url("L/Old"))
        let plan = try p.plan(.twoWay)
        #expect(plan.action("gone.txt") == .deleteLeft)
        #expect(plan.action("Old") == .deleteRight)
        #expect(plan.row("Old")?.whole == true)
        try p.sync(.twoWay)
        #expect(!p.exists("L/gone.txt"))
        #expect(!p.exists("R/Old"))
        #expect(p.exists("L/keep.txt") && p.exists("R/keep.txt"))
    }

    @Test func twoWayKeepsAFileChangedAfterTheOtherCopyWasDeleted() throws {
        let p = try Pair()
        try p.file("L/a.txt", "first", age: 7200)
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("R/a.txt"))
        try p.file("L/a.txt", "edited since", age: 60)
        #expect(try p.plan(.twoWay).action("a.txt") == .toRight)
    }

    @Test func twoWayCopiesWhatChangedOnOneSide() throws {
        let p = try Pair()
        try p.file("L/a.txt", "one", age: 7200)
        try p.sync(.twoWay)
        // Older date, but it is the side that changed.
        try p.file("R/a.txt", "changed on the right", age: 10_000)
        #expect(try p.plan(.twoWay).action("a.txt") == .toLeft)
        try p.sync(.twoWay)
        #expect(p.text("L/a.txt") == "changed on the right")
    }

    @Test func twoWayLeavesAFileChangedOnBothSidesForYou() throws {
        let p = try Pair()
        try p.file("L/a.txt", "one", age: 7200)
        try p.sync(.twoWay)
        try p.file("L/a.txt", "left edit", age: 60)
        try p.file("R/a.txt", "right edit!", age: 120)
        let plan = try p.plan(.twoWay)
        #expect(plan.action("a.txt") == Sync.Action.none)
        #expect(plan.row("a.txt")?.conflict == "Changed on both sides")
        try p.sync(.twoWay)
        #expect(p.text("L/a.txt") == "left edit")
        #expect(p.text("R/a.txt") == "right edit!")
        // Still a conflict the next time: the memory isn't overwritten by an unsettled file.
        #expect(try p.plan(.twoWay).row("a.txt")?.conflict == "Changed on both sides")
    }

    @Test func twoWayDeletedFolderWithSomethingNewInsideIsKept() throws {
        let p = try Pair()
        try p.file("L/Project/old.txt")
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("R/Project"))
        try p.file("L/Project/new.txt", "new")
        let plan = try p.plan(.twoWay)
        #expect(plan.action("Project") == .toRight)
        #expect(plan.row("Project")?.whole == false)
        try p.sync(.twoWay)
        #expect(p.text("R/Project/new.txt") == "new")
        #expect(!p.exists("L/Project/old.txt"))
        #expect(!p.exists("R/Project/old.txt"))
    }

    @Test func memoryWorksWithTheSidesSwapped() throws {
        let p = try Pair()
        try p.file("L/a.txt")
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("L/a.txt"))
        let swapped = Sync.plan(try Sync.compare(p.right, p.left, by: .dateAndSize, cancelled: CancelFlag()), mode: .twoWay)
        #expect(swapped.action("a.txt") == .deleteLeft)
    }

    @Test func contentComparisonReadsTheBytes() throws {
        let p = try Pair()
        try p.file("L/a.txt", "abc", age: 60)
        try p.file("R/a.txt", "abd", age: 60)
        try p.file("L/b.txt", "same", age: 60)
        try p.file("R/b.txt", "same", age: 7200)
        #expect(try p.plan(.mirror).rows.map(\.name) == ["b.txt"])
        let plan = try p.plan(.mirror, by: .content)
        #expect(plan.rows.map(\.name) == ["a.txt"])
        #expect(plan.equal == 1)
    }

    @Test func finderLeftoversAreNotSynced() throws {
        let p = try Pair()
        try p.file("L/.DS_Store")
        try p.file("L/sub/._a.txt")
        try p.file("R/.DS_Store")
        #expect(try p.plan(.mirror).rows.map(\.name) == ["sub"])
    }

    @Test func namesAreMatchedIgnoringCaseOnAnOrdinaryDrive() throws {
        let p = try Pair()
        guard !Sync.caseSensitive(p.left) else { return }
        try p.file("L/Photo.JPG", "same", age: 60)
        try p.file("R/photo.jpg", "same", age: 60)
        try p.file("L/Docs/new.txt", "n")
        try p.folder("R/docs")
        let plan = try p.plan(.mirror)
        #expect(plan.rows.count == 1)
        #expect(plan.row("Docs/new.txt")?.rightPath == "docs/new.txt")
        try p.sync(.mirror)
        #expect(p.exists("R/photo.jpg"))
        #expect(p.text("R/docs/new.txt") == "n")
    }

    @Test func nothingInsideAnUnreadableFolderIsDeleted() throws {
        let p = try Pair()
        try p.file("L/Locked/a.txt")
        try p.file("R/Locked/a.txt")
        try p.file("R/Locked/b.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p.url("L/Locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.url("L/Locked").path) }
        let scan = try p.compare()
        #expect(!scan.problems.isEmpty)
        let plan = Sync.plan(scan, mode: .mirror)
        #expect(plan.rows.allSatisfy { $0.action == .none })
        #expect(plan.row("Locked")?.note != nil)
        Sync.Job(left: p.left, right: p.right, rows: plan.rows, permanently: true).perform()
        #expect(p.exists("R/Locked/b.txt"))
    }

    @Test func anUnreadableFolderIsNeverOneSidedDeleted() throws {
        let p = try Pair()
        try p.file("R/Locked/a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p.url("R/Locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.url("R/Locked").path) }
        let plan = try p.plan(.mirror)
        #expect(plan.action("Locked") == Sync.Action.none)
        #expect(plan.row("Locked")?.choices == [Sync.Action.none])
    }

    @Test func aFolderThatCantBeReadStopsTheCompare() throws {
        let p = try Pair()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: p.left.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.left.path) }
        #expect(throws: (any Error).self) { try p.compare() }
    }

    @Test func somethingChangedSinceTheCompareIsLeftAlone() throws {
        let p = try Pair()
        try p.file("L/a.txt", "left", age: 60)
        try p.file("R/a.txt", "right", age: 7200)
        try p.file("R/extra.txt", "extra", age: 7200)
        let plan = try p.plan(.mirror)
        try p.file("R/a.txt", "edited meanwhile", age: 1)
        try p.file("R/extra.txt", "edited meanwhile", age: 1)
        let outcome = Sync.Job(left: p.left, right: p.right, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 2)
        #expect(p.text("R/a.txt") == "edited meanwhile")
        #expect(p.text("R/extra.txt") == "edited meanwhile")
    }

    @Test func aFileFacingAFolderIsAConflictUnlessMirroring() throws {
        let p = try Pair()
        try p.file("L/thing", "file")
        try p.file("R/thing/inside.txt")
        let twoWay = try p.plan(.twoWay)
        #expect(twoWay.rows.count == 1)
        #expect(twoWay.row("thing")?.conflict != nil)
        let mirror = try p.plan(.mirror)
        #expect(mirror.rows.count == 1)
        #expect(mirror.action("thing") == .toRight)
        try p.sync(.mirror)
        #expect(p.text("R/thing") == "file")
    }

    @Test func aFolderChosenThroughALinkIsReadWhereItIs() throws {
        let p = try Pair()
        try p.file("L/a.txt")
        try p.file("R/a.txt")
        try p.file("R/b.txt")
        let link = p.root.appendingPathComponent("link to left")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: p.left)
        let plan = Sync.plan(try Sync.compare(link, p.right, by: .dateAndSize, cancelled: CancelFlag()), mode: .mirror)
        #expect(plan.rows.map(\.name) == ["b.txt"])
    }

    @Test func aReplacementIsRecordedForUndo() throws {
        let p = try Pair()
        try p.file("L/a.txt", "new", age: 60)
        try p.file("R/a.txt", "old", age: 7200)
        let plan = try p.plan(.mirror)
        let outcome = Sync.Job(left: p.left, right: p.right, rows: plan.rows, permanently: true).perform()
        #expect(outcome.copied == 1)
        guard case .created(let made)? = outcome.changes.last else { Issue.record("nothing recorded"); return }
        #expect(made.key == p.url("R/a.txt").key)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.right.path)
        #expect(leftovers == ["a.txt"])
    }
}
