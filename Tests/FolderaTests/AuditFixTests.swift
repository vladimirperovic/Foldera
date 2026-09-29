import AppKit
import Testing
@testable import Foldera

/// A folder of its own per test, removed afterwards (made readable again first).
private final class Place {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaAudit-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = self.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func lock(_ path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url(path).path)
    }

    func unlock(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(path).path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) @MainActor struct AuditFixes {
    @Test func aFailedArchiveNeverRemovesAFileItDidntMake() throws {
        let p = try Place()
        let source = try p.file("document.txt", "source")
        let job = Archive.compress([source])
        try "another writer's file".write(to: job.output, atomically: true, encoding: .utf8)
        let (made, problem) = job.runAndWait()
        #expect(problem == nil)
        #expect(TextFile.read(job.output) == "another writer's file")
        #expect(made?.lastPathComponent == "document (2).zip")
        #expect(!FileOps.exists(job.partial))
    }

    @Test func aCancelledArchiveLeavesNothingBehind() throws {
        let p = try Place()
        let job = Archive.compress([try p.file("a.txt")])
        job.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        job.process.arguments = ["-c", "echo partial > \"\(job.partial.path)\"; exit 3"]
        let (made, _) = job.runAndWait()
        #expect(made == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.root.path) == ["a.txt"])
    }

    @Test func markdownNestedWithoutEndDoesntRunOutOfStack() {
        for depth in [4_000, 20_000] {
            let html = Markdown.html(String(repeating: ">", count: depth) + " text")
            #expect(html.contains("text"))
            #expect(html.components(separatedBy: "<blockquote>").count - 1 == Markdown.deepest)
        }
        let list = (0..<200).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")
        #expect(Markdown.html(list).contains("item 199"))
    }

    @Test func aRenameThatOnlyChangesCaseCanBeUndoneAndRedone() async throws {
        let p = try Place()
        guard !Sync.caseSensitive(p.root) else { return }
        let source = try p.file("readme.md", "text")
        let target = try FileOps.rename(source, to: "README.md")
        let manager = FileUndo.Manager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        FileUndo.record([.moved(from: source, to: target)], name: "Rename", in: manager)
        manager.endUndoGrouping()
        manager.undo()
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.root.path) == ["readme.md"])
        manager.redo()
        #expect(try FileManager.default.contentsOfDirectory(atPath: p.root.path) == ["README.md"])
    }

    @Test func twoNamesForOneFileAreTheSameItemButAHardLinkIsNotAFreeName() throws {
        let p = try Place()
        let file = try p.file("a.txt", "first")
        let link = p.url("b.txt")
        try FileManager.default.linkItem(at: file, to: link)
        // A hard link is one file too, but its name is an entry of its own:
        // the undo rename refuses (RENAME_EXCL) rather than replace it.
        #expect(FileOps.isSameItem(file, link))
        #expect(renamex_np(link.path, file.path, UInt32(RENAME_EXCL)) != 0)
        #expect(!FileOps.isSameItem(file, p.url("missing.txt")))
    }

    @Test func anUnreadableFolderKeepsItsWarningWhenOpenedFromTheCache() throws {
        let p = try Place()
        try p.file("top/locked/data.txt", "not empty")
        try p.file("top/fine/data.txt", "readable")
        try p.lock("top/locked")
        defer { p.unlock("top/locked") }
        let tree = try #require(UsageScanner().scan(p.url("top")))
        UsageCache.store(tree)
        defer { UsageCache.forget(p.url("top")) }
        #expect(tree.unreadable == 1)
        #expect(UsageCache.node(for: p.url("top/locked"))?.unreadable == 1)
        #expect(UsageCache.node(for: p.url("top/fine"))?.unreadable == 0)
    }

    @Test func anUnreadableFolderInColumnsSaysSoInsteadOfLookingEmpty() throws {
        let p = try Place()
        try p.file("locked/data.txt")
        try p.lock("locked")
        defer { p.unlock("locked") }
        let children = ColumnNode(url: p.url("locked"), item: nil).loadChildren(sort: SortSpec.saved)
        #expect(children.count == 1)
        #expect(children.first?.problem != nil && children.first?.isLeaf == true)
    }

    @Test func searchSaysHowManyFoldersItCouldntLookInto() async throws {
        let p = try Place()
        try p.file("open/match.txt")
        try p.file("locked/match.txt")
        try p.lock("locked")
        defer { p.unlock("locked") }
        let search = FolderSearch()
        var found = 0
        let unreadable: Int = await withCheckedContinuation { done in
            search.start(in: p.root, for: "match", showHidden: false, found: { found += $0.count }) { _, unreadable in
                done.resume(returning: unreadable)
            }
        }
        #expect(found == 1)
        #expect(unreadable == 1)
    }
}
