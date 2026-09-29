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
        try compared(mode, by: by).plan
    }

    func compared(_ mode: Sync.Mode, by: Sync.Comparison = .dateAndSize) throws -> (scan: Sync.Scan, plan: Sync.Plan) {
        let scan = try compare(by)
        return (scan, Sync.plan(scan, mode: mode))
    }

    /// Compare, then Synchronize; deletions are permanent, to leave the Trash alone.
    @discardableResult
    func sync(_ mode: Sync.Mode) throws -> Sync.Job.Outcome {
        let (scan, plan) = try compared(mode)
        return Sync.Job(scan, rows: plan.rows, permanently: true).perform()
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
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.deleted == 0)
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
        let (scan, plan) = try p.compared(.mirror)
        try p.file("R/a.txt", "edited meanwhile", age: 1)
        try p.file("R/extra.txt", "edited meanwhile", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 2)
        #expect(p.text("R/a.txt") == "edited meanwhile")
        #expect(p.text("R/extra.txt") == "edited meanwhile")
    }

    @Test func mirrorLeavesAFolderThatGainedAFileAfterTheCompare() throws {
        let p = try Pair()
        try p.file("R/Photos/old.jpg")
        try p.file("R/Photos/2024/older.jpg")
        let (scan, plan) = try p.compared(.mirror)
        #expect(plan.action("Photos") == .deleteRight)
        try p.file("R/Photos/NEW.jpg", "new", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 1)
        #expect(outcome.deleted == 0)
        #expect(p.text("R/Photos/NEW.jpg") == "new")
    }

    @Test func aFolderDeletedWholeIsCheckedAllTheWayDown() throws {
        let p = try Pair()
        try p.file("R/Photos/2024/older.jpg")
        let (scan, plan) = try p.compared(.mirror)
        // Deep inside: the top folder's own date doesn't change.
        try p.file("R/Photos/2024/NEW.jpg", "new", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.deleted == 0)
        #expect(p.text("R/Photos/2024/NEW.jpg") == "new")
    }

    @Test func twoWayLeavesAFolderThatGainedAFileAfterTheCompare() throws {
        let p = try Pair()
        try p.file("L/Project/a.txt")
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("R/Project"))
        let (scan, plan) = try p.compared(.twoWay)
        #expect(plan.action("Project") == .deleteLeft)
        try p.file("L/Project/NEW.txt", "new", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 1)
        #expect(p.text("L/Project/NEW.txt") == "new")
    }

    @Test func aFolderReplacedByAFileIsCheckedToo() throws {
        let p = try Pair()
        try p.file("L/thing", "file")
        try p.file("R/thing/inside.txt")
        let (scan, plan) = try p.compared(.mirror)
        try p.file("R/thing/NEW.txt", "new", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 1)
        #expect(p.text("R/thing/NEW.txt") == "new")
    }

    @Test func aWholeFolderStillAsComparedIsDeleted() throws {
        let p = try Pair()
        try p.file("R/Photos/2024/older.jpg")
        try p.file("R/Photos/.DS_Store")
        let (scan, plan) = try p.compared(.mirror)
        // Finder writing its .DS_Store changes nothing that counts.
        try p.file("R/Photos/2024/.DS_Store", "view settings", age: 1)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.isEmpty)
        #expect(!p.exists("R/Photos"))
    }

    @Test func aCancelledSyncDoesntReadBothFoldersAgain() throws {
        let p = try Pair()
        try p.file("L/a.txt")
        let (scan, plan) = try p.compared(.mirror)
        let job = Sync.Job(scan, rows: plan.rows, permanently: true)
        job.cancel()
        let outcome = job.perform()
        #expect(outcome.cancelled)
        #expect(outcome.scan == nil)
        #expect(!p.exists("R/a.txt"))
    }

    @Test func deletingEverythingOnOneSideAsksFirstHoweverLittleThereIs() throws {
        let p = try Pair()
        try p.file("R/a.txt")
        try p.file("R/b.txt")
        let (scan, plan) = try p.compared(.mirror)
        #expect(plan.worries(scan) == ["Everything in the right folder would be deleted."])
        try p.file("L/a.txt")
        let (fewer, some) = try p.compared(.mirror)
        #expect(some.worries(fewer).isEmpty)
    }

    @Test func memoryKeepsOneEntryWhenBothSidesAreAlike() throws {
        let same = Sync.Item(folder: false, size: 3, modified: 100)
        let other = Sync.Item(folder: false, size: 4, modified: 200)
        let memory = Sync.Memory(left: "/a", right: "/b", items: ["x": .init(left: same, right: same), "y": .init(left: same, right: other)])
        let json = String(decoding: try JSONEncoder().encode(memory.items), as: UTF8.self)
        #expect(json.contains("\"x\":[[3,100]]"))
        #expect(json.contains("\"y\":[[3,100],[4,200]]"))
        let back = try JSONDecoder().decode([String: Sync.Memory.Pair].self, from: Data(json.utf8))
        #expect(back["x"]?.right == same && back["y"]?.right == other)
    }

    @Test func aDeletionIsCalledOffWhenTheOtherCopyIsBack() throws {
        let p = try Pair()
        try p.file("L/a.txt", "old")
        try p.sync(.twoWay)
        try FileManager.default.removeItem(at: p.url("L/a.txt"))
        let (scan, plan) = try p.compared(.twoWay)
        #expect(plan.action("a.txt") == .deleteRight)
        try p.file("L/a.txt", "old")
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.deleted == 0 && outcome.failures.count == 1)
        #expect(p.text("R/a.txt") == "old")
        // …and the next sync doesn't take the other one either.
        try p.sync(.twoWay)
        #expect(p.text("L/a.txt") == "old" && p.text("R/a.txt") == "old")
    }

    @Test func contentKeepsAnEditThatKeptItsSizeAndDate() throws {
        let p = try Pair()
        try p.file("L/a.txt", "old")
        try p.file("R/a.txt", "old")
        _ = try p.compare(.content)
        try p.file("L/a.txt", "NEW")
        try FileManager.default.removeItem(at: p.url("R/a.txt"))
        let (scan, plan) = try p.compared(.twoWay, by: .content)
        #expect(plan.action("a.txt") == .toRight)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.isEmpty)
        #expect(p.text("L/a.txt") == "NEW" && p.text("R/a.txt") == "NEW")
    }

    @Test func contentSeesAFileEditedOnBothSides() throws {
        let p = try Pair()
        try p.file("L/a.txt", "old")
        try p.file("R/a.txt", "old")
        _ = try p.compare(.content)
        try p.file("L/a.txt", "AAA")
        try p.file("R/a.txt", "BBB", age: 60)
        #expect(try p.plan(.twoWay, by: .content).row("a.txt")?.conflict == "Changed on both sides")
    }

    @Test func withoutRememberedContentContentModeDoesntGuess() throws {
        let p = try Pair()
        try p.file("L/a.txt", "old")
        try p.file("R/a.txt", "old")
        _ = try p.compare(.dateAndSize)
        try FileManager.default.removeItem(at: p.url("R/a.txt"))
        let plan = try p.plan(.twoWay, by: .content)
        #expect(plan.action("a.txt") == Sync.Action.none)
        #expect(plan.row("a.txt")?.conflict != nil)
    }

    @Test func afterASyncByContentTheContentIsRemembered() throws {
        let p = try Pair()
        try p.file("L/a.txt", "abc")
        let (scan, plan) = try p.compared(.mirror, by: .content)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.scan?.comparison == .content)
        #expect(outcome.scan?.memory.hashes?["a.txt"] != nil)
    }

    @Test func aTargetEditedWithinTwoSecondsIsLeftAlone() throws {
        let p = try Pair()
        try p.file("L/a.txt", "NEW", age: 7200)
        try p.file("R/a.txt", "old", age: 60)
        let (scan, plan) = try p.compared(.mirror, by: .content)
        try p.file("R/a.txt", "EDI", age: 59)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 1)
        #expect(p.text("R/a.txt") == "EDI")
    }

    @Test func aTargetEditedWithItsDateSetBackIsLeftAlone() throws {
        let p = try Pair()
        try p.file("L/a.txt", "NEW", age: 60)
        let target = try p.file("R/a.txt", "old", age: 7200)
        let (scan, plan) = try p.compared(.mirror)
        let date = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate]
        try "EDI".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: target.path)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 1)
        #expect(p.text("R/a.txt") == "EDI")
    }

    @Test func aFolderTurnedIntoALinkLeadsNowhere() throws {
        let p = try Pair()
        try p.file("L/sub/new.txt", "incoming")
        try p.folder("L/other")
        try p.folder("R/sub")
        try p.file("R/other/extra.txt", "data")
        let (scan, plan) = try p.compared(.mirror)
        let outside = p.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside data".write(to: outside.appendingPathComponent("extra.txt"), atomically: false, encoding: .utf8)
        for name in ["sub", "other"] {
            try FileManager.default.removeItem(at: p.url("R/\(name)"))
            try FileManager.default.createSymbolicLink(at: p.url("R/\(name)"), withDestinationURL: outside)
        }
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.failures.count == 2)
        #expect(!FileOps.exists(outside.appendingPathComponent("new.txt")))
        #expect(FileOps.exists(outside.appendingPathComponent("extra.txt")))
    }

    @Test func anotherFolderInTheSamePlaceStopsTheSync() throws {
        let p = try Pair()
        try p.file("R/a.txt")
        let (scan, plan) = try p.compared(.mirror)
        try FileManager.default.removeItem(at: p.right)
        try p.file("R/a.txt")
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.deleted == 0 && outcome.failures.count == 1)
        #expect(p.exists("R/a.txt"))
    }

    @Test func linksAreComparedByWhereTheyPoint() throws {
        let p = try Pair()
        try FileManager.default.createSymbolicLink(atPath: p.url("L/link").path, withDestinationPath: "one")
        try FileManager.default.createSymbolicLink(atPath: p.url("R/link").path, withDestinationPath: "two")
        try FileManager.default.createSymbolicLink(atPath: p.url("L/same").path, withDestinationPath: "x")
        try FileManager.default.createSymbolicLink(atPath: p.url("R/same").path, withDestinationPath: "x")
        try p.file("R/plain", "one")
        try FileManager.default.createSymbolicLink(atPath: p.url("L/plain").path, withDestinationPath: "one")
        for by in Sync.Comparison.allCases {
            let plan = try p.plan(.mirror, by: by)
            #expect(Set(plan.rows.map(\.name)) == ["link", "plain"])
        }
        try p.sync(.mirror)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: p.url("R/link").path) == "one")
    }

    @Test func whatIsNeverSyncedStaysOutOfAFolderCopiedWhole() throws {
        let p = try Pair()
        try p.file("L/new/document.txt", "real")
        try p.file("L/new/.DS_Store", "metadata")
        try p.file("L/new/deeper/.recovery.foldera-sync", "partial")
        try p.file("L/new/deeper/._resource", "apple double")
        let plan = try p.plan(.mirror)
        #expect(plan.rows.count == 1 && plan.rows[0].whole)
        try p.sync(.mirror)
        #expect(p.text("R/new/document.txt") == "real")
        #expect(p.exists("R/new/deeper"))
        #expect(!p.exists("R/new/.DS_Store"))
        #expect(!p.exists("R/new/deeper/.recovery.foldera-sync"))
        #expect(!p.exists("R/new/deeper/._resource"))
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
        let (scan, plan) = try p.compared(.mirror)
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        #expect(outcome.copied == 1)
        guard case .created(let made)? = outcome.changes.last else { Issue.record("nothing recorded"); return }
        #expect(made.key == p.url("R/a.txt").key)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.right.path)
        #expect(leftovers == ["a.txt"])
    }
}
