import Foundation
import Darwin
import Testing
@testable import Foldera

private final class RetryFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaRetry-\(UUID().uuidString)")
    let source: URL
    let target: URL

    init() throws {
        source = root.appendingPathComponent("source.dxf")
        target = root.appendingPathComponent("destination/source.dxf")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
    }

    func destinationNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).sorted()
    }

    deinit { FileOps.removeOwn(root) }
}

@Suite struct TransferRetries {
    @Test(arguments: ["metadata", "data"])
    func aSourceFinalizedDuringTheFirstCopyIsRetriedFromScratch(_ change: String) throws {
        let files = try RetryFiles()
        let before = try #require(FileOps.revision(of: files.source))
        let modified = try #require(FileManager.default.attributesOfItem(atPath: files.source.path)[.modificationDate] as? Date)
        let copier = TreeCopier(cancelled: CancelFlag())
        var changed = false
        copier.copied = { bytes in
            guard bytes == 0, !changed else { return }
            changed = true
            do {
                if change == "metadata" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.source.path)
                } else {
                    // Same length and restored mtime: ctime must still reject
                    // this first attempt before a stable retry is published.
                    try Data("updated!".utf8).write(to: files.source)
                    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: files.source.path)
                }
            } catch { Issue.record(error) }
        }

        try copier.copy(files.source, to: files.target, retryBusySource: true)

        #expect(changed)
        #expect(FileOps.revision(of: files.source) != before)
        #expect(try Data(contentsOf: files.target) == Data((change == "data" ? "updated!" : "original").utf8))
        #expect(copier.errors.isEmpty, "A successful retry must discard the previous attempt's failure")
        #expect(try files.destinationNames() == ["source.dxf"])
    }

    @Test func aSourceThatKeepsChangingStopsAfterThreeAttemptsAndLeavesNoCopy() throws {
        let files = try RetryFiles()
        let copier = TreeCopier(cancelled: CancelFlag())
        var changes = 0
        copier.copied = { bytes in
            guard bytes == 0 else { return }
            changes += 1
            do {
                try FileManager.default.setAttributes([.posixPermissions: changes.isMultiple(of: 2) ? 0o644 : 0o600],
                                                       ofItemAtPath: files.source.path)
            } catch { Issue.record(error) }
        }

        #expect(throws: TreeCopier.SourceChangedError.self) {
            try copier.copy(files.source, to: files.target, retryBusySource: true)
        }

        #expect(changes == 3)
        #expect(try Data(contentsOf: files.source) == Data("original".utf8))
        #expect(!FileOps.exists(files.target))
        #expect(try files.destinationNames().isEmpty)
        #expect(copier.errors.first?.contains("changed while copying") == true)
    }

    @Test func cancellingDuringTheRetryWaitStopsWithoutPublishing() throws {
        let files = try RetryFiles()
        let cancelled = CancelFlag(), changed = CancelFlag()
        let copier = TreeCopier(cancelled: cancelled)
        copier.copied = { bytes in
            guard bytes == 0, !changed.isSet else { return }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.source.path)
                changed.set()
            } catch { Issue.record(error) }
        }
        copier.waiting = { waiting in
            if waiting && changed.isSet { cancelled.set() }
        }

        #expect(throws: CancellationError.self) {
            try copier.copy(files.source, to: files.target, retryBusySource: true)
        }

        #expect(changed.isSet && cancelled.isSet)
        #expect(FileOps.exists(files.source))
        #expect(!FileOps.exists(files.target))
        #expect(try files.destinationNames().isEmpty)
    }

    @Test(arguments: [false, true])
    func ordinaryCopierAndMoveVerificationKeepTheirOriginalStrictBaseline(verifyingSource: Bool) throws {
        let files = try RetryFiles()
        let copier = TreeCopier(cancelled: CancelFlag())
        var changes = 0
        copier.copied = { bytes in
            guard bytes == 0, changes == 0 else { return }
            changes += 1
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.source.path)
            } catch { Issue.record(error) }
        }

        #expect(throws: TreeCopier.SourceChangedError.self) {
            if verifyingSource {
                // Even an accidental opt-in cannot relax a Move baseline.
                try copier.copy(files.source, to: files.target, verifyingSource: true, retryBusySource: true)
            } else {
                try copier.copy(files.source, to: files.target)
            }
        }

        #expect(changes == 1)
        #expect(FileOps.exists(files.source))
        #expect(try files.destinationNames().isEmpty)
        #expect(throws: OpError.self) { try copier.removeCopiedSource(files.source) }
    }

    @Test func aDestinationCreatedWhileRetryingIsNeverRemovedOrOverwritten() throws {
        let files = try RetryFiles()
        let copier = TreeCopier(cancelled: CancelFlag())
        let changed = CancelFlag()
        copier.copied = { bytes in
            guard bytes == 0, !changed.isSet else { return }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.source.path)
                changed.set()
            } catch { Issue.record(error) }
        }
        copier.waiting = { waiting in
            guard waiting, changed.isSet, !FileOps.exists(files.target) else { return }
            do { try Data("another writer".utf8).write(to: files.target) }
            catch { Issue.record(error) }
        }

        do {
            try copier.copy(files.source, to: files.target, retryBusySource: true)
            Issue.record("Publishing must refuse another writer's destination")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST))
        }

        #expect(try Data(contentsOf: files.target) == Data("another writer".utf8))
        #expect(try Data(contentsOf: files.source) == Data("original".utf8))
        #expect(try files.destinationNames() == ["source.dxf"])
    }
}
