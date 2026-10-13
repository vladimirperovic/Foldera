import Foundation
import Testing
@testable import Foldera

/// CI provisions a small disk image; each serialized test owns its files on it.
private final class DisposableDisk {
    let root: URL
    let mount: URL
    let sourceFolder: URL
    let destination: URL
    let payload = Data(repeating: 0xA5, count: 16 * 1024 * 1024)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderaDiskFailure-\(UUID().uuidString)").resolvingSymlinksInPath()
        guard let path = ProcessInfo.processInfo.environment["FOLDERA_DISK_FAILURE_VOLUME"] else {
            throw OpError("The disposable disk image was not provisioned")
        }
        mount = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        sourceFolder = root.appendingPathComponent("source")
        destination = mount.appendingPathComponent("destination-\(UUID().uuidString)")
        let image = mount.deletingLastPathComponent().appendingPathComponent("disposable.dmg")
        let capacity = try FileManager.default.attributesOfFileSystem(forPath: mount.path)[.systemSize] as? NSNumber
        guard mount.lastPathComponent == "mounted", FileOps.exists(image),
              TextFile.read(mount.appendingPathComponent(".foldera-disposable"))?.trimmingCharacters(in: .whitespacesAndNewlines) == image.path,
              let capacity, capacity.int64Value <= 80 * 1024 * 1024 else {
            throw OpError("Refusing to fill anything other than the provisioned small disk image")
        }
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try payload.write(to: sourceFolder.appendingPathComponent("item.bin"))
    }

    /// Leave enough space to begin copying, but not to finish a 16 MB file.
    func leaveFourMegabytesFree() throws {
        let filler = mount.appendingPathComponent("filler.bin")
        guard FileManager.default.createFile(atPath: filler.path, contents: nil) else {
            throw OpError("Couldn't create the disposable disk's filler")
        }
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x5A, count: 1024 * 1024)
        // Bound writes even if the image unexpectedly mounts on another filesystem.
        for _ in 0..<64 {
            let free = try FileManager.default.attributesOfFileSystem(forPath: mount.path)[.systemFreeSize] as? NSNumber
            guard let free else { throw OpError("Can't read free space on the disposable disk") }
            if free.int64Value <= 4 * 1024 * 1024 { return }
            try handle.write(contentsOf: chunk)
        }
        throw OpError("The disposable disk did not reach its expected capacity")
    }

    func releaseSpace() throws { try FileManager.default.removeItem(at: mount.appendingPathComponent("filler.bin")) }

    deinit {
        try? FileManager.default.removeItem(at: mount.appendingPathComponent("filler.bin"))
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: root)
    }
}

extension SyncTestIsolation {
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FOLDERA_DISK_FAILURE_VOLUME"] != nil))
struct DiskFailures {
    @Test(arguments: [false, true], [false, true])
    func aFullDiskKeepsTheSourceAndAnyReplacedFile(move: Bool, replace: Bool) throws {
        let disk = try DisposableDisk()
        let source = disk.sourceFolder.appendingPathComponent("item.bin")
        let target = disk.destination.appendingPathComponent("item.bin")
        if replace { try "original destination".write(to: target, atomically: false, encoding: .utf8) }
        try disk.leaveFourMegabytesFree()
        let outcome = Transfer(plan: .init(steps: [.init(from: source, to: target, replace: replace)]), move: move).perform()
        #expect(!outcome.failures.isEmpty && !outcome.cancelled)
        #expect(outcome.changes.isEmpty && outcome.made.isEmpty)
        #expect(try Data(contentsOf: source) == disk.payload)
        #expect(replace ? TextFile.read(target) == "original destination" : !FileOps.exists(target))
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.destination.path) == (replace ? ["item.bin"] : []))
    }

    @Test func cancellingAfterBytesArriveRemovesThePartialCopy() throws {
        let disk = try DisposableDisk()
        let source = disk.sourceFolder.appendingPathComponent("item.bin")
        let target = disk.destination.appendingPathComponent("item.bin")
        let neighbour = disk.destination.appendingPathComponent("keep.txt")
        try "untouched".write(to: neighbour, atomically: false, encoding: .utf8)
        let cancelled = CancelFlag()
        let copier = TreeCopier(cancelled: cancelled)
        var observedBytes: Int64 = 0
        copier.copied = { bytes in
            if bytes > 0 { observedBytes = bytes; cancelled.set() }
        }
        #expect(throws: CancellationError.self) { try copier.copy(source, to: target) }
        #expect(observedBytes > 0)
        #expect(try Data(contentsOf: source) == disk.payload)
        #expect(TextFile.read(neighbour) == "untouched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.destination.path) == ["keep.txt"])
    }

    @Test func aSyncReplacementOnAFullDiskCanBeRetriedWithoutLosingEitherVersion() throws {
        let disk = try DisposableDisk()
        let previousMemory = Sync.Memory.folder
        Sync.Memory.folder = disk.root.appendingPathComponent("memory")
        defer { Sync.Memory.folder = previousMemory }
        let target = disk.destination.appendingPathComponent("item.bin")
        try "original destination".write(to: target, atomically: false, encoding: .utf8)
        try disk.leaveFourMegabytesFree()
        func sync() throws -> Sync.Job.Outcome {
            let scan = try Sync.compare(disk.sourceFolder, disk.destination, by: .dateAndSize, cancelled: CancelFlag())
            return Sync.Job(scan, rows: Sync.plan(scan, mode: .mirror).rows, permanently: true).perform()
        }
        let failed = try sync()
        #expect(!failed.failures.isEmpty)
        #expect(failed.copied == 0 && failed.deleted == 0 && failed.changes.isEmpty)
        #expect(TextFile.read(target) == "original destination")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.destination.path) == ["item.bin"])
        try disk.releaseSpace()
        let retried = try sync()
        #expect(retried.failures.isEmpty && retried.copied == 1)
        #expect(try Data(contentsOf: target) == disk.payload)
        #expect(try Data(contentsOf: disk.sourceFolder.appendingPathComponent("item.bin")) == disk.payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: disk.destination.path) == ["item.bin"])
    }
}
}
