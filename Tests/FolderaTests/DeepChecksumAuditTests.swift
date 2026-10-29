import Foundation
import Darwin
import Testing
@testable import Foldera

private final class ChecksumFiles {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaChecksumAudit-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    @discardableResult func file(_ name: String, _ bytes: Data) throws -> URL {
        let target = url(name)
        try bytes.write(to: target)
        return target
    }
    deinit { FileOps.removeOwn(root) }
}

@Suite struct DeepChecksumAudit {
    @Test(arguments: [" leading and trailing ", "a\\b.txt", "line\nbreak", "line\rbreak", "😀\u{2028}name", "*name"])
    func checksumNamesRoundTripExactly(_ name: String) throws {
        let digest = Data(repeating: 0xab, count: 32)
        let line = Checksum.line(digest, name: name)
        let entries = Checksum.entries(in: line + "\r\n")
        #expect(entries.count == 1)
        #expect(entries.first?.name == name)
        #expect(entries.first?.hash == String(repeating: "ab", count: 32))
        #expect(!line.contains("\n") && !line.contains("\r"))
    }

    @Test func checksumParserRejectsMalformedRecordsAndSupportsEscapedBSDNames() {
        let hash = String(repeating: "a", count: 64)
        let invalid = ["\(hash) x", "\(hash)  ", "\\\(hash)  bad\\q", "\\\(hash)  bad\\", "\(hash)  nul\0name",
                       String(repeating: "Ａ", count: 64) + "  name"]
        #expect(Checksum.entries(in: invalid.joined(separator: "\n")).isEmpty)
        let entries = Checksum.entries(in: "\\SHA256 ( leading\\ntrailing ) = \(hash)\n")
        #expect(entries.first?.name == " leading\ntrailing ")
    }

    @Test(arguments: [false, true])
    func hashingRejectsChangedOrReplacedContent(replace: Bool) throws {
        let files = try ChecksumFiles()
        let bytes = Data(repeating: 0x61, count: (1 << 20) + 31)
        let file = try files.file("input", bytes)
        var changed = false
        let digest = Sync.digest(file, cancelled: CancelFlag()) { _ in
            guard !changed else { return }
            changed = true
            do {
                if replace {
                    try bytes.write(to: file, options: .atomic)
                } else {
                    let writer = try FileHandle(forWritingTo: file)
                    defer { try? writer.close() }
                    try writer.write(contentsOf: Data("z".utf8))
                }
            } catch { Issue.record(error) }
        }
        #expect(changed && digest == nil)
    }

    @Test func comparisonRejectsEditingAnAlreadyComparedPart() throws {
        let files = try ChecksumFiles()
        let bytes = Data(repeating: 0x61, count: (1 << 20) + 31)
        let a = try files.file("a", bytes), b = try files.file("b", bytes)
        var changed = false
        let result = FileCompare.compare(a, b, cancelled: CancelFlag()) { _ in
            guard !changed else { return }
            changed = true
            do {
                let writer = try FileHandle(forWritingTo: a)
                defer { try? writer.close() }
                try writer.write(contentsOf: Data("z".utf8))
            } catch { Issue.record(error) }
        }
        #expect(changed && result == nil)
    }

    @Test func specialFilesNeverWaitForAWriterAndSymlinksStillRead() throws {
        let files = try ChecksumFiles()
        let fifo = files.url("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let regular = try files.file("regular", Data("abc".utf8))
        #expect(StableFileReader(fifo) == nil)
        #expect(Sync.digest(fifo, cancelled: CancelFlag()) == nil)
        #expect(FileCompare.compare(regular, fifo, cancelled: CancelFlag()) == nil)
        #expect(Sync.digest(files.root, cancelled: CancelFlag()) == nil)
        let link = files.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(Sync.digest(link, cancelled: CancelFlag()) == Sync.digest(regular, cancelled: CancelFlag()))
        #expect(FileCompare.compare(link, regular, cancelled: CancelFlag()) == .same)
    }

    @Test func cancellingDuringAReadNeverPublishesADigestOrComparison() throws {
        let files = try ChecksumFiles()
        let a = try files.file("a", Data("abc".utf8)), b = try files.file("b", Data("abc".utf8))
        let hashCancelled = CancelFlag(), compareCancelled = CancelFlag()
        #expect(Sync.digest(a, cancelled: hashCancelled) { _ in hashCancelled.set() } == nil)
        #expect(FileCompare.compare(a, b, cancelled: compareCancelled) { _ in compareCancelled.set() } == nil)
    }

    @Test func verificationPlansKeepExactNamesAndReportUnreadableLists() throws {
        let files = try ChecksumFiles()
        let file = try files.file(" leading\\name ", Data("abc".utf8))
        let digest = try #require(Sync.digest(file, cancelled: CancelFlag()))
        let text = Checksum.line(digest, name: file.lastPathComponent) + "\n" + Checksum.line(digest, name: "missing") + "\n"
        let list = try files.file("check.sha256", Data(text.utf8))
        let fifo = files.url("pipe.sha256")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let plan = Checksum.verification([list, fifo], cancelled: CancelFlag())
        #expect(plan.present.map(\.url.key) == [file.key])
        #expect(plan.present.first?.hash == Checksum.hex(digest))
        #expect(plan.problems.count == 2)
        let cancelled = CancelFlag(); cancelled.set()
        let skipped = Checksum.verification([list], cancelled: cancelled)
        #expect(skipped.present.isEmpty && skipped.problems.isEmpty)
    }
}
