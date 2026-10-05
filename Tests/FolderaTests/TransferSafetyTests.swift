import AppKit
import Testing
@testable import Foldera

private final class TransferFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTransferSafety-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    @discardableResult func file(_ path: String, _ text: String) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func cleanTrash(_ changes: [Change]) {
        for change in changes {
            if case let .moved(_, to) = change, to.path.contains(".Trash") { try? FileManager.default.removeItem(at: to) }
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) @MainActor struct TransferSafety {
    @Test(arguments: [false, true])
    func anotherPathToTheSameFolderNeverReplacesTheSource(move: Bool) throws {
        let f = try TransferFiles()
        let source = try f.file("source/nested/document.txt", "original")
        let alias = f.url("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.url("source"))
        let destination = alias.appendingPathComponent("nested")
        let plan = try #require(Transfer.plan([source], into: destination, move: move) { _, _, _ in
            Issue.record("The same directory must not ask to replace its own file")
            return (.replace, false)
        })
        let outcome = Transfer(plan: plan, move: move).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(outcome.failures.isEmpty)
        #expect(TextFile.read(source) == "original")
        #expect(move ? plan.steps.isEmpty : TextFile.read(f.url("source/nested/document - Copy.txt")) == "original")
    }

    @Test(arguments: [false, true])
    func aFailedReplacementLeavesTheOldFileInPlace(move: Bool) throws {
        let f = try TransferFiles()
        let source = try f.file("source/document.txt", "new")
        let target = try f.file("dest/document.txt", "old")
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: move) { _, _, _ in (.replace, false) })
        try FileManager.default.removeItem(at: source)
        let outcome = Transfer(plan: plan, move: move).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(!outcome.failures.isEmpty)
        #expect(outcome.changes.isEmpty)
        #expect(TextFile.read(target) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["document.txt"])
    }

    @Test func aPreparedPlanCannotReplaceItsOwnSource() throws {
        let f = try TransferFiles()
        let source = try f.file("document.txt", "original")
        let outcome = Transfer(plan: .init(steps: [.init(from: source, to: source, replace: true)]), move: false).perform()
        #expect(!outcome.failures.isEmpty)
        #expect(outcome.changes.isEmpty)
        #expect(TextFile.read(source) == "original")
    }

    @Test func collisionDuringCopyDoesNotEnterUndo() async throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.bin", "")
        let target = f.url("dest/a.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lazy = try LazyFile(source, contents: LazyFile.bytes(4096), readyAfter: nil)
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: false) { _, _, _ in (.stop, false) })
        let job = Transfer(plan: plan, move: false)
        var supplied = false
        let result = await withCheckedContinuation { continuation in
            job.run(progress: { progress in
                guard progress.waiting, !supplied else { return }
                supplied = true
                do {
                    try "another writer".write(to: target, atomically: true, encoding: .utf8)
                    try lazy.contents.write(to: source)
                } catch { Issue.record(error); job.cancel() }
            }, done: { continuation.resume(returning: $0) })
        }
        #expect(supplied)
        #expect(!result.failures.isEmpty)
        #expect(result.changes.isEmpty && result.made.isEmpty)
        #expect(TextFile.read(target) == "another writer")
        #expect(try Data(contentsOf: source) == lazy.contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["a.bin"])
    }

    @Test func cancellationWhilePreparingAReplacementKeepsBothFiles() async throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.bin", "")
        let target = try f.file("dest/a.bin", "old")
        _ = try LazyFile(source, contents: LazyFile.bytes(4096), readyAfter: nil)
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: true) { _, _, _ in (.replace, false) })
        let job = Transfer(plan: plan, move: true)
        let result = await withCheckedContinuation { continuation in
            job.run(progress: { if $0.waiting { job.cancel() } }, done: { continuation.resume(returning: $0) })
        }
        defer { f.cleanTrash(result.changes) }
        #expect(result.cancelled)
        #expect(result.changes.isEmpty)
        #expect(FileOps.exists(source))
        #expect(TextFile.read(target) == "old")
    }

    @Test(arguments: [false, true])
    func successfulReplacementStillSupportsUndoAndRedo(move: Bool) throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.txt", "new")
        let target = try f.file("dest/a.txt", "old")
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: move) { _, _, _ in (.replace, false) })
        let outcome = Transfer(plan: plan, move: move).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(outcome.failures.isEmpty)
        #expect(TextFile.read(target) == "new")
        #expect(FileOps.exists(source) == !move)
        let undo = FileUndo.Manager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        FileUndo.record(outcome.changes, name: "Replace", in: undo)
        undo.endUndoGrouping()
        undo.undo()
        #expect(TextFile.read(target) == "old")
        #expect(TextFile.read(source) == "new")
        undo.redo()
        #expect(TextFile.read(target) == "new")
        #expect(FileOps.exists(source) == !move)
    }

    @Test(arguments: [false, true])
    func aDestinationChangedDuringPreparationIsLeftAlone(move: Bool) async throws {
        let f = try TransferFiles()
        let source = try f.file("source/document.txt", "")
        let target = try f.file("dest/document.txt", "old")
        let lazy = try LazyFile(source, contents: Data("new source".utf8), readyAfter: nil)
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: move) { _, _, _ in (.replace, false) })
        let job = Transfer(plan: plan, move: move)
        var changed = false
        let outcome: Transfer.Outcome = await withCheckedContinuation { done in
            job.run(progress: { progress in
                guard progress.waiting, !changed else { return }
                changed = true
                do {
                    try "another writer".write(to: target, atomically: true, encoding: .utf8)
                    try lazy.contents.write(to: source)
                } catch { Issue.record(error); job.cancel() }
            }, done: { done.resume(returning: $0) })
        }
        defer { f.cleanTrash(outcome.changes) }
        #expect(changed && !outcome.failures.isEmpty)
        #expect(outcome.changes.isEmpty)
        #expect(TextFile.read(target) == "another writer")
        #expect(TextFile.read(source) == "new source")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["document.txt"])
    }

    @Test func failedCopyKeepsADestinationSymlinkAndItsReferent() throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.txt", "new")
        let referred = try f.file("dest/original.txt", "keep")
        let target = f.url("dest/a.txt")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: referred)
        let plan = try #require(Transfer.plan([source], into: target.deletingLastPathComponent(), move: false) { _, _, _ in (.replace, false) })
        try FileManager.default.removeItem(at: source)
        let outcome = Transfer(plan: plan, move: false).perform()
        #expect(!outcome.failures.isEmpty && outcome.changes.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == referred.path)
        #expect(TextFile.read(referred) == "keep")
    }

    @Test func replacementMoveOnOneVolumePreservesHardLinks() throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.txt", "new")
        let target = try f.file("dest/a.txt", "old")
        let link = f.url("linked.txt")
        try FileManager.default.linkItem(at: source, to: link)
        let plan = Transfer.Plan(steps: [.init(from: source, to: target, replace: true)])
        let outcome = Transfer(plan: plan, move: true).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(outcome.failures.isEmpty)
        #expect(FileOps.isSameItem(target, link))
        #expect(!FileOps.exists(source))
    }

    @Test func failedReplacementRenameRestoresTheOldDestination() throws {
        let f = try TransferFiles()
        let source = try f.file("source/a.txt", "new")
        let target = try f.file("dest/a.txt", "old")
        let parent = source.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let outcome = Transfer(plan: .init(steps: [.init(from: source, to: target, replace: true)]), move: true).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(!outcome.failures.isEmpty && outcome.changes.isEmpty)
        #expect(TextFile.read(source) == "new")
        #expect(TextFile.read(target) == "old")
    }

    @Test func stagedReplacementAcrossVolumesSupportsUndoAndRedo() async throws {
        guard let volume = ProcessInfo.processInfo.environment["FOLDERA_TEST_VOLUME"] else { return }
        let f = try TransferFiles()
        let source = try f.file("source/a.txt", "new")
        let folder = URL(fileURLWithPath: volume).appendingPathComponent("FolderaReplacement-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let target = folder.appendingPathComponent("a.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        #expect(!DragOps.sameVolume(source, target))
        let outcome = Transfer(plan: .init(steps: [.init(from: source, to: target, replace: true)]), move: true).perform()
        defer { f.cleanTrash(outcome.changes) }
        #expect(outcome.failures.isEmpty)
        #expect(TextFile.read(target) == "new" && !FileOps.exists(source))
        let undo = FileUndo.Manager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        FileUndo.record(outcome.changes, name: "Replace", in: undo)
        undo.endUndoGrouping()
        func finishUndo() async throws {
            let deadline = Date().addingTimeInterval(5)
            while undo.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!undo.isBusy)
        }
        undo.undo()
        try await finishUndo()
        #expect(TextFile.read(source) == "new" && TextFile.read(target) == "old")
        undo.redo()
        try await finishUndo()
        #expect(TextFile.read(target) == "new" && !FileOps.exists(source))
    }
}
