import Foundation
import Testing
@testable import Foldera

/// A fresh folder per test, removed afterwards.
private final class Sandbox {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func text(_ path: String) -> String? { try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileOps.exists(url.appendingPathComponent(path)) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Answers every question the same way, and counts them.
private final class Answers {
    var asked: [String] = []
    let answer: Transfer.Clash
    init(_ answer: Transfer.Clash) { self.answer = answer }
    func ask(_ name: String, _ folders: Bool, _ many: Bool) -> (Transfer.Clash, remember: Bool) {
        asked.append(name)
        return (answer, false)
    }
}

@Suite struct Transfers {
    @Test func copiesAFolderTreeWithItsContents() throws {
        let s = try Sandbox()
        try s.file("src/Project/a.txt", "A")
        try s.file("src/Project/sub/b.txt", "B")
        let dest = try s.folder("dest")
        let plan = try #require(Transfer.plan([s.url.appendingPathComponent("src/Project")], into: dest, move: false, ask: Answers(.stop).ask))
        let outcome = Transfer(plan: plan, move: false).perform()
        #expect(outcome.failures.isEmpty)
        #expect(s.text("dest/Project/a.txt") == "A")
        #expect(s.text("dest/Project/sub/b.txt") == "B")
        #expect(s.exists("src/Project/a.txt"))
    }

    @Test func movingOnTheSameDriveIsARename() throws {
        let s = try Sandbox()
        let source = try s.file("a/report.txt", "R")
        let dest = try s.folder("b")
        let plan = try #require(Transfer.plan([source], into: dest, move: true, ask: Answers(.stop).ask))
        let outcome = Transfer(plan: plan, move: true).perform()
        #expect(!s.exists("a/report.txt"))
        #expect(s.text("b/report.txt") == "R")
        guard case .moved(let from, let to)? = outcome.changes.first else { Issue.record("no move recorded"); return }
        #expect(from.key == source.key && to.lastPathComponent == "report.txt")
    }

    @Test func mergingFoldersKeepsBothSidesAndAsksAboutClashingFiles() throws {
        let s = try Sandbox()
        try s.file("src/Photos/new.jpg", "new")
        try s.file("src/Photos/same.jpg", "incoming")
        try s.file("dest/Photos/old.jpg", "old")
        try s.file("dest/Photos/same.jpg", "existing")
        var questions: [(String, Bool)] = []
        let plan = try #require(Transfer.plan([s.url.appendingPathComponent("src/Photos")], into: s.url.appendingPathComponent("dest"), move: false) { name, folders, _ in
            questions.append((name, folders))
            return (folders ? .merge : .keepBoth, false)
        })
        _ = Transfer(plan: plan, move: false).perform()
        #expect(questions.map(\.0) == ["Photos", "same.jpg"])
        #expect(questions.map(\.1) == [true, false])
        #expect(s.text("dest/Photos/old.jpg") == "old")
        #expect(s.text("dest/Photos/new.jpg") == "new")
        #expect(s.text("dest/Photos/same.jpg") == "existing")
        #expect(s.text("dest/Photos/same (2).jpg") == "incoming")
    }

    @Test func mergingOnAMoveEmptiesAndRemovesTheSource() throws {
        let s = try Sandbox()
        try s.file("src/Music/a.mp3")
        try s.file("dest/Music/b.mp3")
        let plan = try #require(Transfer.plan([s.url.appendingPathComponent("src/Music")], into: s.url.appendingPathComponent("dest"), move: true, ask: Answers(.merge).ask))
        _ = Transfer(plan: plan, move: true).perform()
        #expect(s.exists("dest/Music/a.mp3") && s.exists("dest/Music/b.mp3"))
        #expect(!s.exists("src/Music"))
    }

    @Test func skipAndStop() throws {
        let s = try Sandbox()
        let a = try s.file("src/a.txt", "new a")
        let b = try s.file("src/b.txt", "new b")
        try s.file("dest/a.txt", "old a")
        let dest = s.url.appendingPathComponent("dest")
        let skipped = try #require(Transfer.plan([a, b], into: dest, move: false, ask: Answers(.skip).ask))
        #expect(skipped.steps.map(\.from.lastPathComponent) == ["b.txt"])
        #expect(Transfer.plan([a, b], into: dest, move: false, ask: Answers(.stop).ask) == nil)
    }

    @Test func copyingIntoTheSameFolderMakesACopy() throws {
        let s = try Sandbox()
        let a = try s.file("notes.txt", "n")
        let plan = try #require(Transfer.plan([a], into: s.url, move: false, ask: Answers(.stop).ask))
        _ = Transfer(plan: plan, move: false).perform()
        #expect(s.text("notes - Copy.txt") == "n")
    }

    @Test func aFolderCannotGoInsideItself() throws {
        let s = try Sandbox()
        let parent = try s.folder("parent")
        let child = try s.folder("parent/child")
        let plan = try #require(Transfer.plan([parent], into: child, move: true, ask: Answers(.stop).ask))
        #expect(plan.steps.isEmpty)
        #expect(plan.problems.count == 1)
    }

    @Test func cancelledCopiesLeaveNothingHalfDone() throws {
        let s = try Sandbox()
        try s.file("src/big/one.txt", "1")
        let plan = try #require(Transfer.plan([s.url.appendingPathComponent("src/big")], into: try s.folder("dest"), move: false, ask: Answers(.stop).ask))
        let job = Transfer(plan: plan, move: false)
        job.cancel()
        let outcome = job.perform()
        #expect(outcome.cancelled)
        #expect(!s.exists("dest/big"))
    }
}

@Suite @MainActor struct Undoing {
    private func manager() -> FileUndo.Manager {
        let manager = FileUndo.Manager()
        manager.groupsByEvent = false
        return manager
    }

    @Test func undoMovesBackAndRedoMovesAgain() throws {
        let s = try Sandbox()
        let from = try s.file("a/doc.txt", "d")
        let to = try s.folder("b").appendingPathComponent("doc.txt")
        try FileManager.default.moveItem(at: from, to: to)
        let undo = manager()
        undo.beginUndoGrouping()
        FileUndo.record([.moved(from: from, to: to)], name: "Move", in: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Move")
        undo.undo()
        #expect(s.exists("a/doc.txt") && !s.exists("b/doc.txt"))
        #expect(undo.canRedo)
        undo.redo()
        #expect(!s.exists("a/doc.txt") && s.exists("b/doc.txt"))
    }

    @Test func undoingARenameRestoresTheName() throws {
        let s = try Sandbox()
        let original = try s.file("old name.txt")
        let renamed = try FileOps.rename(original, to: "new name.txt")
        let undo = manager()
        undo.beginUndoGrouping()
        FileUndo.record([.moved(from: original, to: renamed)], name: "Rename", in: undo)
        undo.endUndoGrouping()
        undo.undo()
        #expect(s.exists("old name.txt") && !s.exists("new name.txt"))
    }
}

@Suite struct Extras {
    @Test func tagsToggleOnAndOff() throws {
        let s = try Sandbox()
        let a = try s.file("a.txt")
        let b = try s.file("b.txt")
        #expect(Tags.toggle("Red", on: [a]).isEmpty)
        #expect(Tags.names(of: a) == ["Red"])
        _ = Tags.toggle("Red", on: [a, b])
        #expect(Tags.names(of: b) == ["Red"])
        _ = Tags.toggle("Red", on: [a, b])
        #expect(Tags.names(of: a).isEmpty && Tags.names(of: b).isEmpty)
        #expect(Tags.color(of: "Red") != nil && Tags.color(of: "Work") == nil)
    }

    @Test(arguments: [
        ("nas.local/Photos", "smb://nas.local/Photos"),
        ("192.168.1.10", "smb://192.168.1.10"),
        (#"\\server\share"#, "smb://server/share"),
        ("afp://mac.local/Share", "afp://mac.local/Share"),
    ])
    func serverAddresses(_ typed: String, _ expected: String) {
        #expect(Servers.address(typed)?.absoluteString == expected)
    }

    @Test func emptyServerAddressIsNothing() {
        #expect(Servers.address("smb://") == nil)
        #expect(Servers.address("  ") == nil)
    }
}

@Suite struct Listings {
    @Test func listedItemsCarryTheirTags() throws {
        let s = try Sandbox()
        let a = try s.file("tagged.txt")
        try Tags.set(["Red", "Blue"], on: a)
        #expect(FileItem(url: a).tags == ["Red", "Blue"])
        let listed = try FileItem.contents(of: s.url, showHidden: false)
        #expect(listed.first { $0.name == "tagged.txt" }?.tags == ["Red", "Blue"])
    }
}

@Suite struct Counting {
    @Test func countingStopsWhenCancelled() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("FolderaCount-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try Data(count: 10).write(to: folder.appendingPathComponent(name)) }
        #expect(Transfer.size(of: folder) == 30)
        let cancelled = CancelFlag()
        cancelled.set()
        #expect(Transfer.size(of: folder, cancelled: cancelled) == 0)
    }
}
