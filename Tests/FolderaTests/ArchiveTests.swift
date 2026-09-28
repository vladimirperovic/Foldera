import Foundation
import Testing
@testable import Foldera

/// A fresh folder per test, removed afterwards.
private final class Workshop {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaArchives-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func text(_ path: String) -> String? { try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileOps.exists(url.appendingPathComponent(path)) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private func crc32(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
    }
    return ~crc
}

private extension Array where Element == UInt8 {
    mutating func le16(_ v: Int) { append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    mutating func le32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(v >> UInt32(shift) & 0xff)) } }
}

/// A zip with stored (uncompressed) entries and whatever names it is given,
/// including the dangerous ones no zip tool would write.
private func storedZip(_ entries: [(String, String)]) -> Data {
    var out: [UInt8] = []
    var central: [UInt8] = []
    for (name, text) in entries {
        let data = Array(text.utf8), nameBytes = Array(name.utf8), crc = crc32(data), offset = UInt32(out.count)
        out.le32(0x0403_4b50); out.le16(20); out.le16(0); out.le16(0); out.le16(0); out.le16(0x21)
        out.le32(crc); out.le32(UInt32(data.count)); out.le32(UInt32(data.count)); out.le16(nameBytes.count); out.le16(0)
        out += nameBytes + data
        central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0); central.le16(0); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count)); central.le16(nameBytes.count)
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
        central += nameBytes
    }
    let start = UInt32(out.count)
    out += central
    out.le32(0x0605_4b50); out.le16(0); out.le16(0); out.le16(entries.count); out.le16(entries.count)
    out.le32(UInt32(central.count)); out.le32(start); out.le16(0)
    return Data(out)
}

/// A RAR 4 archive with one stored file, built from the format's technote
/// (no tool here can write RAR; only WinRAR can).
private func storedRar(name: String, text: String) -> Data {
    let data = Array(text.utf8), nameBytes = Array(name.utf8)
    func block(_ type: UInt8, flags: Int, body: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [type]
        header.le16(flags)
        header.le16(7 + body.count)
        header += body
        var out: [UInt8] = []
        out.le16(Int(crc32(header) & 0xffff))
        return out + header
    }
    var archive: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]
    archive += block(0x73, flags: 0, body: [0, 0, 0, 0, 0, 0])
    var file: [UInt8] = []
    file.le32(UInt32(data.count))           // packed size
    file.le32(UInt32(data.count))           // unpacked size
    file.append(0)                          // host OS: MS-DOS
    file.le32(crc32(data))
    file.le32(0x5821_0000)                  // 2024-01-01 00:00
    file.append(29)                         // needs RAR 2.9
    file.append(0x30)                       // method: store
    file.le16(nameBytes.count)
    file.le32(0x20)                         // archive attribute
    file += nameBytes
    archive += block(0x74, flags: 0x8000, body: file) + data
    archive += block(0x7b, flags: 0x4000, body: [])
    return Data(archive)
}

@Suite struct Archives {
    @Test(arguments: Archive.Format.allCases)
    func packAndUnpackEveryFormat(_ format: Archive.Format) throws {
        let w = try Workshop()
        let a = try w.file("pack/a.txt", "alpha")
        let b = try w.file("pack/sub/b.txt", "beta")
        let (archive, problem) = Archive.compress([a, b.deletingLastPathComponent()], as: format).runAndWait()
        #expect(problem == nil)
        let made = try #require(archive)
        #expect(made.lastPathComponent == "Archive.\(format.rawValue)")
        #expect(ArchiveFolders.isArchive(made))
        let (folder, skipped) = try Archive.extractAll(made)
        #expect(skipped.isEmpty)
        #expect(folder.lastPathComponent == "Archive")
        #expect(w.text("pack/Archive/a.txt") == "alpha")
        #expect(w.text("pack/Archive/sub/b.txt") == "beta")
    }

    @Test func aZippedFolderDoesNotEndUpNestedTwice() throws {
        let w = try Workshop()
        try w.file("work/Report/page.txt", "p")
        let (zip, _) = Archive.compress([w.url.appendingPathComponent("work/Report")]).runAndWait()
        #expect(zip?.lastPathComponent == "Report.zip")
        let (folder, _) = try Archive.extractAll(try #require(zip))
        #expect(folder.lastPathComponent == "Report (2)")
        #expect(w.text("work/Report (2)/page.txt") == "p")
    }

    @Test func rarArchivesOpen() throws {
        let w = try Workshop()
        let rar = w.url.appendingPathComponent("song lyrics.rar")
        try storedRar(name: "readme.txt", text: "hello from rar").write(to: rar)
        #expect(ArchiveFolders.isArchive(rar))
        let destination = w.url.appendingPathComponent("out")
        try Unpacker(rar).unpack(into: destination)
        #expect(w.text("out/readme.txt") == "hello from rar")
    }

    @Test func namesThatClimbOutAreLeftOut() throws {
        let w = try Workshop()
        let zip = w.url.appendingPathComponent("evil.zip")
        try storedZip([("../escaped.txt", "no"), ("/absolute.txt", "maybe"), ("good/ok.txt", "yes")]).write(to: zip)
        let destination = w.url.appendingPathComponent("inside/out")
        let skipped = try Unpacker(zip).unpack(into: destination)
        #expect(skipped == ["../escaped.txt"])
        #expect(!w.exists("inside/escaped.txt") && !w.exists("escaped.txt"))
        #expect(w.text("inside/out/good/ok.txt") == "yes")
        // An absolute name is kept, but inside the destination.
        #expect(w.text("inside/out/absolute.txt") == "maybe")
        #expect(!FileOps.exists(URL(fileURLWithPath: "/absolute.txt")))
    }

    @Test func passwordProtectedZips() throws {
        let w = try Workshop()
        try w.file("secret.txt", "classified")
        let zip = w.url.appendingPathComponent("locked.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipper.currentDirectoryURL = w.url
        zipper.arguments = ["-q", "-P", "open sesame", zip.path, "secret.txt"]
        try zipper.run()
        zipper.waitUntilExit()

        #expect {
            try Unpacker(zip).unpack(into: w.url.appendingPathComponent("a"))
        } throws: { ($0 as? Unpacker.Failure)?.needsPassword == true }
        #expect {
            try Unpacker(zip).unpack(into: w.url.appendingPathComponent("b"), password: "wrong")
        } throws: { ($0 as? Unpacker.Failure)?.needsPassword == true }
        try Unpacker(zip).unpack(into: w.url.appendingPathComponent("c"), password: "open sesame")
        #expect(w.text("c/secret.txt") == "classified")
    }

    @Test func somethingThatIsNotAnArchiveFailsCleanly() throws {
        let w = try Workshop()
        let fake = try w.file("fake.7z", "just text")
        #expect(throws: Unpacker.Failure.self) { try Unpacker(fake).unpack(into: w.url.appendingPathComponent("out")) }
    }

    @Test(arguments: [
        ("a.zip", true), ("a.rar", true), ("a.7z", true), ("a.tar", true), ("a.tar.gz", true), ("a.tgz", true),
        ("a.tar.xz", true), ("a.gz", false), ("a.txt", false), ("a.docx", false), ("a.iso", false),
    ])
    func whichFilesAreArchives(_ name: String, _ archive: Bool) {
        #expect(ArchiveFolders.isArchive(URL(fileURLWithPath: "/tmp/" + name)) == archive)
    }

    @Test func baseNames() {
        #expect(Archive.baseName(of: URL(fileURLWithPath: "/tmp/photos.tar.gz")) == "photos")
        #expect(Archive.baseName(of: URL(fileURLWithPath: "/tmp/photos.zip")) == "photos")
        #expect(Archive.baseName(of: URL(fileURLWithPath: "/tmp/v1.2.rar")) == "v1.2")
    }

    @Test func eachArchiveVersionGetsItsOwnCacheFolder() throws {
        let w = try Workshop()
        let zip = w.url.appendingPathComponent("a.zip")
        try storedZip([("x.txt", "1")]).write(to: zip)
        let first = ArchiveFolders.folder(for: zip)
        #expect(ArchiveFolders.folder(for: zip) == first)
        #expect(ArchiveFolders.isInside(first.appendingPathComponent("x.txt")))
        try storedZip([("x.txt", "22")]).write(to: zip)
        #expect(ArchiveFolders.folder(for: zip) != first)
    }
}
