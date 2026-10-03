import Foundation
import Testing
@testable import Foldera

/// A fresh folder per test, removed afterwards.
private final class Bench {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `age` in seconds before now.
    @discardableResult
    func file(_ name: String, _ text: String = "x", age: TimeInterval = 0) throws -> URL {
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        return file
    }

    func text(_ name: String) -> String? { try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) }

    func items() throws -> [FileItem] {
        try FileItem.contents(of: url, showHidden: false).sorted(by: SortSpec(key: .name, ascending: true))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite @MainActor struct Tools {
    @Test func patternsSelectByWildcardsAndWords() throws {
        let p = try Bench()
        for name in ["song.mp3", "Song2.MP3", "photo.jpg", "notes"] { try p.file(name) }
        let items = try p.items()
        #expect(Set(ExplorerTab.matching("*.mp3", in: items).map(\.name)) == ["song.mp3", "Song2.MP3"])
        #expect(Set(ExplorerTab.matching("*.jpg; notes", in: items).map(\.name)) == ["photo.jpg", "notes"])
        #expect(ExplorerTab.matching("*.*", in: items).count == 4)
        #expect(ExplorerTab.matching(" ; ", in: items).isEmpty)
    }

    @Test func checksumFilesAreReadInEveryUsualForm() {
        let hash = String(repeating: "ab", count: 32)
        let text = "\(hash)  a.txt\n\(hash.uppercased()) *b c.bin\nSHA256 (d.txt) = \(hash)\n# a note\nnot a checksum\n"
        let entries = Checksum.entries(in: text)
        #expect(entries.map(\.name) == ["a.txt", "b c.bin", "d.txt"])
        #expect(entries.allSatisfy { $0.hash == hash })
    }

    @Test func sha256IsTheKnownOne() throws {
        let p = try Bench()
        let file = try p.file("abc.txt", "abc")
        let digest = try #require(Sync.digest(file, cancelled: CancelFlag()))
        #expect(Checksum.hex(digest) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Checksum.line(digest, name: "abc.txt").hasSuffix("  abc.txt"))
    }

    @Test func filesAreComparedByteByByte() throws {
        let p = try Bench()
        let a = try p.file("a", "hello world")
        let b = try p.file("b", "hello world")
        let c = try p.file("c", "hello there")
        #expect(FileCompare.compare(a, b, cancelled: CancelFlag()) == .same)
        #expect(FileCompare.compare(a, c, cancelled: CancelFlag()) == .differ(at: 6))
        #expect(FileCompare.compare(a, p.url.appendingPathComponent("gone"), cancelled: CancelFlag()) == nil)
    }

    @Test func panesFindWhatIsNewerOrMissing() throws {
        let left = try Bench()
        let right = try Bench()
        try left.file("same.txt", age: 3600)
        try right.file("same.txt", age: 3600)
        try left.file("newer.txt", age: 60)
        try right.file("NEWER.txt", age: 3600)
        try left.file("only-left.txt")
        try right.file("only-right.txt")
        let (mine, theirs) = ExplorerTab.newerOrMissing(try left.items(), try right.items())
        #expect(Set(mine.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["newer.txt", "only-left.txt"])
        #expect(Set(theirs.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["only-right.txt"])
    }

    @Test func paneSyncUsesChosenDirectionInsteadOfRememberedDirection() {
        let left = URL(fileURLWithPath: "/tmp/Foldera-left")
        let right = URL(fileURLWithPath: "/tmp/Foldera-right")
        let saved = SyncWindow.Setup(left: right.key, right: left.key, mode: .twoWay, comparison: .content)
        let forward = SyncWindow.Setup.forFolders([left, right], mode: .mirror, recent: [saved])
        #expect(forward.left == left.key && forward.right == right.key)
        #expect(forward.mode == .mirror && forward.comparison == .content)
        #expect(forward.towardLeft == false)
        let reverse = SyncWindow.Setup.forFolders([right, left], mode: .update, recent: [forward])
        #expect(reverse.left == right.key && reverse.right == left.key)
        #expect(reverse.mode == .update)
        #expect(SyncWindow.Setup.forFolders([left, right], mode: nil, recent: [saved]) == saved)
    }

    @Test func oldSyncSetupsStillDecodeAndNewOnesRememberDirection() throws {
        let old = Data(#"{"left":"/tmp/left","right":"/tmp/right","mode":"mirror","comparison":"dateAndSize","permanently":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SyncWindow.Setup.self, from: old)
        #expect(decoded.towardLeft == nil)
        var reverse = decoded
        reverse.towardLeft = true
        #expect(try JSONDecoder().decode(SyncWindow.Setup.self, from: JSONEncoder().encode(reverse)) == reverse)
    }

    @Test func renamePatternsFillTokensCountAndReplace() throws {
        let p = try Bench()
        try p.file("IMG_001.JPG")
        try p.file("IMG_002.JPG")
        let items = try p.items()
        var rule = RenameRule()
        rule.name = "Holiday [C]"
        rule.digits = 2
        rule.caseChange = .lower
        #expect(items.indices.map { rule.newName(for: items[$0], index: $0) } == ["holiday 01.jpg", "holiday 02.jpg"])
        rule = RenameRule()
        rule.find = "img_"
        rule.replace = "Photo "
        #expect(rule.newName(for: items[0], index: 0) == "Photo 001.JPG")
        rule = RenameRule()
        rule.regex = true
        rule.find = #"IMG_(\d+)"#
        rule.replace = "$1-pic"
        #expect(rule.newName(for: items[1], index: 1, regex: try NSRegularExpression(pattern: rule.find)) == "002-pic.JPG")
        rule = RenameRule()
        rule.name = "[N] [x]"
        #expect(rule.newName(for: items[0], index: 0) == "IMG_001 [x].JPG")
    }

    @Test func renamingManySwapsNamesAndUndoesThem() throws {
        let p = try Bench()
        try p.file("a.txt", "A")
        try p.file("b.txt", "B")
        let items = try p.items()
        let swap = [BatchRename.Row(item: items[0], newName: "b.txt"), BatchRename.Row(item: items[1], newName: "a.txt")]
        let (changes, failures) = BatchRename.perform(swap)
        #expect(failures.isEmpty)
        #expect(p.text("a.txt") == "B" && p.text("b.txt") == "A")
        #expect(changes.count == 4)

        let undo = FileUndo.Manager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        FileUndo.record(changes, name: "Rename", in: undo)
        undo.endUndoGrouping()
        undo.undo()
        #expect(p.text("a.txt") == "A" && p.text("b.txt") == "B")
    }

    @Test func renamingManyRefusesNamesThatClash() throws {
        let p = try Bench()
        try p.file("a.txt")
        try p.file("b.txt")
        try p.file("c.txt")
        let items = try p.items()
        var rule = RenameRule()
        rule.name = "a"
        // a.txt keeps its name, so c.txt can't have it.
        let keeping = BatchRename.rows(for: [items[0], items[2]], rule: rule)
        #expect(keeping[0].problem == nil && !keeping[0].changes)
        #expect(keeping[1].problem != nil)
        // b.txt isn't being renamed, and is in the way.
        rule.name = "b"
        let taken = BatchRename.rows(for: [items[0], items[2]], rule: rule)
        #expect(taken.contains { $0.problem != nil })
        // Two items can't both become "same.txt".
        rule.name = "same"
        #expect(BatchRename.rows(for: [items[0], items[2]], rule: rule).allSatisfy { $0.problem != nil })
    }
}
