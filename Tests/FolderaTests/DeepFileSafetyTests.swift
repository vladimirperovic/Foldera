import AppKit
import Testing
@testable import Foldera

private final class DeepSafetyFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaDeepSafety-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    @discardableResult func file(_ name: String, _ text: String) throws -> URL {
        let result = url(name)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: result)
        return result
    }
    func text(_ name: String) -> String? { try? String(contentsOf: url(name), encoding: .utf8) }
    deinit { FileOps.removeOwn(root) }
}

@Suite(.serialized) @MainActor struct DeepFileSafety {
    private func manager(_ changes: [Change]) -> FileUndo.Manager {
        let manager = FileUndo.Manager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        FileUndo.record(changes, name: "Test operation", in: manager)
        manager.endUndoGrouping()
        return manager
    }

    private func finish(_ manager: FileUndo.Manager) async throws {
        Awake.hold()
        let deadline = Date().addingTimeInterval(10)
        while manager.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!manager.isBusy)
    }

    @Test func undoOfACopyDoesNotTrashAReplacementEntry() async throws {
        let files = try DeepSafetyFiles()
        let copy = try files.file("copy.txt", "original copy")
        let undo = manager([.created(copy)])
        try FileManager.default.moveItem(at: copy, to: files.url("saved.txt"))
        try files.file("copy.txt", "another app's file")

        undo.undo()
        try await finish(undo)

        #expect(files.text("copy.txt") == "another app's file")
        #expect(files.text("saved.txt") == "original copy")
    }

    @Test func undoOfAMoveDoesNotMoveAReplacementEntry() async throws {
        let files = try DeepSafetyFiles()
        let original = try files.file("original.txt", "original")
        let destination = try FileOps.rename(original, to: "moved.txt")
        let undo = manager([.moved(from: original, to: destination)])
        try FileManager.default.moveItem(at: destination, to: files.url("saved.txt"))
        try files.file("moved.txt", "replacement")

        undo.undo()
        try await finish(undo)

        #expect(!FileOps.exists(original))
        #expect(files.text("moved.txt") == "replacement")
        #expect(files.text("saved.txt") == "original")
    }

    @Test func redoAlsoRefusesAnEntryReplacedAfterUndo() async throws {
        let files = try DeepSafetyFiles()
        let original = try files.file("original.txt", "original")
        let destination = try FileOps.rename(original, to: "moved.txt")
        let undo = manager([.moved(from: original, to: destination)])
        undo.undo()
        try await finish(undo)
        try FileManager.default.moveItem(at: original, to: files.url("saved.txt"))
        try files.file("original.txt", "replacement")

        undo.redo()
        try await finish(undo)

        #expect(files.text("original.txt") == "replacement")
        #expect(!FileOps.exists(destination))
        #expect(files.text("saved.txt") == "original")
    }

    @Test func editsToTheSameEntryRemainUndoableAndRedoable() async throws {
        let files = try DeepSafetyFiles()
        let original = try files.file("original.txt", "before")
        let destination = try FileOps.rename(original, to: "moved.txt")
        let undo = manager([.moved(from: original, to: destination)])
        // An in-place edit preserves identity. It moves with the same file.
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()

        undo.undo()
        try await finish(undo)
        #expect(files.text("original.txt") == "edited")
        undo.redo()
        try await finish(undo)
        #expect(files.text("moved.txt") == "edited")
    }

    @Test func aRenameSwapRetainsIdentityThroughTemporaryNamesAndRedo() async throws {
        let files = try DeepSafetyFiles()
        let a = try files.file("a.txt", "A"), b = try files.file("b.txt", "B")
        let result = BatchRename.perform([
            .init(item: FileItem(url: a), newName: "b.txt"),
            .init(item: FileItem(url: b), newName: "a.txt"),
        ])
        #expect(result.failures.isEmpty && result.changes.count == 4)
        #expect(files.text("a.txt") == "B" && files.text("b.txt") == "A")
        let undo = manager(result.changes)

        undo.undo()
        try await finish(undo)
        #expect(files.text("a.txt") == "A" && files.text("b.txt") == "B")
        undo.redo()
        try await finish(undo)
        #expect(files.text("a.txt") == "B" && files.text("b.txt") == "A")
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path).sorted() == ["a.txt", "b.txt"])
    }

    @Test func undoOfACopyDoesNotFollowAReplacementSymlink() async throws {
        let files = try DeepSafetyFiles()
        let copy = try files.file("copy.txt", "copy")
        let outside = try files.file("outside.txt", "unrelated")
        let undo = manager([.created(copy)])
        try FileManager.default.moveItem(at: copy, to: files.url("saved.txt"))
        try FileManager.default.createSymbolicLink(at: copy, withDestinationURL: outside)

        undo.undo()
        try await finish(undo)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.path) == outside.path)
        #expect(files.text("outside.txt") == "unrelated")
        #expect(files.text("saved.txt") == "copy")
    }

    @Test(arguments: [false, true])
    func exclusiveFilePublicationPreservesAnExistingFileOrLink(link: Bool) throws {
        let files = try DeepSafetyFiles()
        let existing = try files.file("existing.txt", "keep")
        let target: URL
        if link {
            target = files.url("link.txt")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: existing)
        } else { target = existing }

        #expect(throws: (any Error).self) { try FileOps.createFile(Data("overwrite".utf8), at: target) }

        #expect(files.text("existing.txt") == "keep")
        if link { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == existing.path) }
        let expected = link ? ["existing.txt", "link.txt"] : ["existing.txt"]
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path).sorted() == expected)
    }

    @Test func completeFilePublicationAndNewDocumentNamingLeaveNoStagingFiles() throws {
        let files = try DeepSafetyFiles()
        let bytes = Data(repeating: 0x5a, count: 4097)
        let target = files.url("checksum.sha256")
        try FileOps.createFile(bytes, at: target)
        #expect(try Data(contentsOf: target) == bytes)
        let first = try FileOps.makeTextFile(in: files.root)
        let second = try FileOps.makeTextFile(in: files.root)
        #expect(first.lastPathComponent == "New Text Document.txt")
        #expect(second.lastPathComponent == "New Text Document (2).txt")
        #expect(try Data(contentsOf: first).isEmpty && Data(contentsOf: second).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path).count == 3)
    }

    @Test(arguments: ["edit", "replace", "link"])
    func anArchiveChangedWithoutChangingSizeOrMtimeGetsAFreshCache(_ change: String) throws {
        let files = try DeepSafetyFiles()
        let archive = try files.file("archive.zip", "old archive")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: archive.path)
        let requested: URL
        if change == "link" {
            requested = files.url("alias.zip")
            try FileManager.default.createSymbolicLink(at: requested, withDestinationURL: archive)
        } else { requested = archive }
        let oldCache = ArchiveFolders.folder(for: requested)
        let oldRevision = try #require(FileOps.revision(of: archive))
        if change == "replace" { try FileManager.default.moveItem(at: archive, to: files.url("previous.zip")) }
        try Data("new archive".utf8).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: archive.path)
        let newRevision = try #require(FileOps.revision(of: archive))

        #expect(newRevision.size == oldRevision.size)
        #expect(newRevision.modified == oldRevision.modified && newRevision.modifiedNanos == oldRevision.modifiedNanos)
        #expect(ArchiveFolders.folder(for: requested) != oldCache)
    }
}
