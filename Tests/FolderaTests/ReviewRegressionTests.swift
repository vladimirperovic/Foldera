import AppKit
import Testing
@testable import Foldera

private final class ReviewFiles {
    let root: URL
    init() throws {
        let base = ProcessInfo.processInfo.environment["FOLDERA_TEST_VOLUME"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("FolderaReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    @discardableResult func folder(_ path: String) throws -> URL {
        let result = url(path)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    @discardableResult func file(_ path: String, _ text: String) throws -> URL {
        let result = url(path)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: result, atomically: true, encoding: .utf8)
        return result
    }
    func text(_ path: String) -> String? { TextFile.read(url(path)) }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) @MainActor struct ReviewRegressions {
    private func undoManager(_ changes: [Change]) -> FileUndo.Manager {
        let manager = FileUndo.Manager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        FileUndo.record(changes, name: "Test move", in: manager)
        manager.endUndoGrouping()
        return manager
    }

    private func finish(_ manager: FileUndo.Manager) async throws {
        for _ in 0..<500 where manager.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!manager.isBusy, "Undo did not finish within five seconds")
    }

    @Test func renameRefusesADifferentEntryEvenWhenItIsAHardLink() throws {
        let files = try ReviewFiles()
        let source = try files.file("a.txt", "original")
        try FileManager.default.linkItem(at: source, to: files.url("b.txt"))
        #expect(throws: OpError.self) { try FileOps.rename(source, to: "b.txt") }
        #expect(files.text("a.txt") == "original")
        #expect(files.text("b.txt") == "original")
    }

    @Test func caseSensitiveRenameDoesNotReplaceAnotherFile() throws {
        let files = try ReviewFiles()
        let source = try files.file("a.txt", "first")
        guard !FileOps.exists(files.url("A.txt")) else { return } // exercised on the optional test volume
        try files.file("A.txt", "second")
        #expect(throws: OpError.self) { try FileOps.rename(source, to: "A.txt") }
        #expect(files.text("a.txt") == "first")
        #expect(files.text("A.txt") == "second")
    }

    @Test func keepBothReservesEveryIncomingName() throws {
        let files = try ReviewFiles()
        let a = try files.file("a/report.txt", "A")
        let b = try files.file("b/report.txt", "B")
        let c = try files.file("c/report (2).txt", "C")
        try files.file("dest/report.txt", "existing")
        let plan = try #require(Transfer.plan([a, b, c], into: files.url("dest"), move: false) { _, _, _ in (.keepBoth, false) })
        #expect(Set(plan.steps.map(\.to.key)).count == 3)
        let outcome = Transfer(plan: plan, move: false).perform()
        #expect(outcome.failures.isEmpty)
        #expect(files.text("dest/report.txt") == "existing")
        #expect(Set(outcome.made.compactMap(TextFile.read)) == ["A", "B", "C"])
    }

    @Test func duplicateNamesAlsoWorkInAnEmptyDestination() throws {
        let files = try ReviewFiles()
        let sources = try [files.file("one/a.txt", "one"), files.file("two/a.txt", "two")]
        let target = try files.folder("dest")
        let plan = try #require(Transfer.plan(sources, into: target, move: true) { _, _, _ in
            Issue.record("A collision within the plan should keep both automatically")
            return (.stop, false)
        })
        let result = Transfer(plan: plan, move: true).perform()
        #expect(result.failures.isEmpty)
        #expect(files.text("dest/a.txt") == "one" && files.text("dest/a (2).txt") == "two")
    }

    @Test func nestedMergeRemovesEmptySourcesAndUndoRestoresEveryFolder() async throws {
        let files = try ReviewFiles()
        try files.file("source/Tree/deep/file.txt", "incoming")
        try files.folder("source/Tree/deep/empty")
        try files.file("dest/Tree/keep.txt", "existing")
        try files.folder("dest/Tree/deep/empty")
        let plan = try #require(Transfer.plan([files.url("source/Tree")], into: files.url("dest"), move: true) { _, _, _ in (.merge, false) })
        let result = Transfer(plan: plan, move: true).perform()
        #expect(result.failures.isEmpty)
        #expect(!FileOps.exists(files.url("source/Tree")))
        let manager = undoManager(result.changes)
        manager.undo()
        try await finish(manager)
        #expect(files.text("source/Tree/deep/file.txt") == "incoming")
        #expect(FileOps.isFolder(files.url("source/Tree/deep/empty")))
        #expect(files.text("dest/Tree/keep.txt") == "existing")
        #expect(!FileOps.exists(files.url("dest/Tree/deep/file.txt")))
    }

    @Test func mergingOnlyEmptyFoldersStillCreatesUndoHistory() throws {
        let files = try ReviewFiles()
        try files.folder("source/empty")
        try files.folder("dest/empty")
        let plan = try #require(Transfer.plan([files.url("source/empty")], into: files.url("dest"), move: true) { _, _, _ in (.merge, false) })
        #expect(plan.steps.isEmpty)
        let result = Transfer(plan: plan, move: true).perform()
        #expect(result.changes.count == 1)
        let manager = undoManager(result.changes)
        manager.undo()
        #expect(FileOps.isFolder(files.url("source/empty")))
    }

    @Test func asynchronousUndoFinishesBeforeRedoCanRun() async throws {
        let files = try ReviewFiles()
        let destination = try files.file("dest/item.txt", "incoming")
        let backup = try files.file("backup/item.txt", "replaced")
        // Missing parent triggers the same background path as a different volume.
        let source = files.url("removed-source/item.txt")
        let manager = undoManager([.moved(from: destination, to: backup), .moved(from: source, to: destination)])
        manager.undo()
        #expect(manager.isBusy && !manager.canRedo && !manager.canUndo)
        manager.redo() // must be ignored until the inverse is complete
        try await finish(manager)
        #expect(files.text("removed-source/item.txt") == "incoming")
        #expect(files.text("dest/item.txt") == "replaced")
        #expect(manager.canRedo)
        manager.redo()
        try await finish(manager)
        #expect(files.text("dest/item.txt") == "incoming")
        #expect(files.text("backup/item.txt") == "replaced")
        #expect(!FileOps.exists(source))
    }

    @Test func crossVolumeMoveReplacementUndoAndRedo() async throws {
        guard ProcessInfo.processInfo.environment["FOLDERA_TEST_VOLUME"] != nil else { return }
        let files = try ReviewFiles()
        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaOtherVolume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let source = sourceFolder.appendingPathComponent("item.txt")
        try "incoming".write(to: source, atomically: true, encoding: .utf8)
        let destination = try files.file("dest/item.txt", "replaced")
        let backup = files.url("backup.txt")
        #expect(!DragOps.sameVolume(source, destination))
        try FileManager.default.moveItem(at: destination, to: backup)
        let plan = Transfer.Plan(steps: [.init(from: source, to: destination, replace: false)])
        let result = Transfer(plan: plan, move: true).perform()
        #expect(result.failures.isEmpty)
        #expect(!FileOps.exists(source) && files.text("dest/item.txt") == "incoming")
        let manager = undoManager([.moved(from: destination, to: backup)] + result.changes)
        manager.undo()
        #expect(manager.isBusy && !manager.canRedo)
        try await finish(manager)
        #expect(TextFile.read(source) == "incoming" && files.text("dest/item.txt") == "replaced")
        manager.redo()
        try await finish(manager)
        #expect(!FileOps.exists(source) && files.text("dest/item.txt") == "incoming")
        #expect(files.text("backup.txt") == "replaced")
    }

    @Test func archiveReadOnlyIsEnforcedByOperations() throws {
        let files = try ReviewFiles()
        let archived = ArchiveFolders.root.appendingPathComponent("test-do-not-create/item.md")
        let folder = archived.deletingLastPathComponent()
        let source = try files.file("source.md", "outside")
        #expect(throws: OpError.self) { try FileOps.rename(archived, to: "renamed.md") }
        #expect(throws: OpError.self) { try FileOps.makeFolder(in: folder) }
        #expect(throws: OpError.self) { try FileOps.makeTextFile(in: folder) }
        #expect(throws: OpError.self) { try TextFile.write("change", to: archived) }
        #expect(throws: OpError.self) { try Tags.set(["Red"], on: archived) }
        #expect(throws: OpError.self) { try Archive.extractAll(source, into: folder) }
        let incoming = Transfer.Plan(steps: [.init(from: source, to: archived, replace: false)])
        #expect(!Transfer(plan: incoming, move: false).perform().failures.isEmpty)
        let outgoing = Transfer.Plan(steps: [.init(from: archived, to: files.url("out.md"), replace: false)])
        #expect(!Transfer(plan: outgoing, move: true).perform().failures.isEmpty)
        let (made, problem) = Archive.compress([archived]).runAndWait()
        #expect(made == nil && problem != nil)
        #expect(!FileOps.exists(folder))
        #expect(files.text("source.md") == "outside")
    }

    @Test func markdownSentinelCharactersRemainLiteral() {
        let source = "\u{E000}0\u{E001} and \u{E000}999999999\u{E001} with `code`"
        let result = Markdown.html(source)
        #expect(result.contains("\u{E000}0\u{E001}"))
        #expect(result.contains("<code>code</code>"))
        #expect(!Markdown.html("\0" + "123" + "\0 `safe`").contains("\0"))
        #expect(Markdown.html("Heading\n---") == "<h2>Heading</h2>\n")
    }

    @Test func externalChangesAreDetectedEvenWithTheSameTimestamp() throws {
        let files = try ReviewFiles()
        let file = try files.file("draft.md", "original")
        let date = try #require(TextFile.version(of: file))
        #expect(!TextFile.hasChanged(file, since: "original"))
        try files.file("draft.md", "external")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(TextFile.hasChanged(file, since: "original"))
        try FileManager.default.removeItem(at: file)
        #expect(TextFile.hasChanged(file, since: "original"))
        #expect(throws: (any Error).self) { try TextFile.write("draft", to: files.url("missing/draft.md")) }
    }

    @Test func unavailableFileAndConflictingDraftsKeepSeparateEditors() throws {
        _ = NSApplication.shared
        let files = try ReviewFiles()
        let file = files.url("missing/draft.md")
        let first = try #require(MarkdownEditor.show(file, unsaved: "first draft"))
        let second = try #require(MarkdownEditor.show(file, unsaved: "second draft"))
        defer { first.close(); second.close() }
        #expect(first !== second)
        #expect(first.draftText == "first draft" && second.draftText == "second draft")
        #expect(first.window?.isDocumentEdited == true && second.window?.isDocumentEdited == true)
    }

    @Test func movingADraftToAWindowKeepsItsOriginalConflictBaseline() throws {
        _ = NSApplication.shared
        let files = try ReviewFiles()
        let file = try files.file("draft.md", "external changes")
        let editor = try #require(MarkdownEditor.show(file, unsaved: "my changes", previouslySaved: "original"))
        defer { editor.close() }
        #expect(editor.draftText == "my changes")
        #expect(TextFile.hasChanged(file, since: editor.saved))
        #expect(files.text("draft.md") == "external changes")
    }

    @Test func usageCacheInvalidatesAncestorsDescendantsButNotSiblings() {
        let root = URL(fileURLWithPath: "/FolderaReviewCache")
        func node(_ path: String) -> UsageNode {
            let url = root.appendingPathComponent(path)
            return UsageNode(url: url, name: url.lastPathComponent, isFolder: true, kind: .folders)
        }
        defer { UsageCache.forget(root) }
        let inside = node("parent/child"), sibling = node("parent2")
        UsageCache.store(inside); UsageCache.store(sibling)
        UsageCache.forget(root.appendingPathComponent("parent"))
        #expect(UsageCache.node(for: inside.url) == nil)
        #expect(UsageCache.node(for: sibling.url) === sibling)
        UsageCache.changed(sibling.url.appendingPathComponent("new.txt"))
        #expect(UsageCache.node(for: sibling.url) == nil)
        UsageCache.store(inside)
        UsageCache.forget(URL(fileURLWithPath: "/"))
        #expect(UsageCache.node(for: inside.url) == nil)
    }

    @Test func missingUsageFolderIsReportedAsIncomplete() throws {
        let files = try ReviewFiles()
        let tree = try #require(UsageScanner().scan(files.url("missing")))
        #expect(tree.unreadable > 0)
        #expect(tree.files == 0)
    }

    @Test func compressionDrainsMoreThanAPipeBufferAndBoundsDiagnostics() throws {
        let files = try ReviewFiles()
        let file = try files.file("input.txt", "x")
        let job = Archive.compress([file])
        job.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        job.process.arguments = ["-c", "i=0; while [ $i -lt 10000 ]; do printf 'archive error: entry could not be read abcdefghijklmnopqrstuvwxyz\\n' >&2; i=$((i+1)); done; exit 1"]
        let timeout = DispatchWorkItem { job.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let (made, problem) = job.runAndWait()
        #expect(made == nil)
        let message = try #require(problem, "Compression stalled until cancellation")
        #expect(message.contains("Further diagnostics omitted"))
        #expect(message.utf8.count < Archive.Job.diagnosticLimit + 100)
        #expect(!FileOps.exists(job.output))
    }

    @Test func compressionCancelledBeforeLaunchCreatesNothing() throws {
        let files = try ReviewFiles()
        let job = Archive.compress([try files.file("input.txt", "x")])
        job.cancel()
        let (made, problem) = job.runAndWait()
        #expect(made == nil && problem == nil)
        #expect(!job.process.isRunning && !FileOps.exists(job.output))
    }

    @Test func explicitNetworkAddressesDoNotCaptureLocalPaths() {
        for value in [#"\\server\share"#, "smb://nas/Photos", "SMB://nas/Photos", "afp://nas/share"] {
            #expect(Servers.isNetworkAddress(value))
            #expect(Servers.address(value) != nil)
        }
        for value in ["/Users/me", "~/Documents", "relative/path", "file:///tmp", "nas.local"] {
            #expect(!Servers.isNetworkAddress(value))
        }
        #expect(Servers.address(#"\\server\share name"#)?.host == "server")
        #expect(Servers.address("smb://") == nil)
    }

    @Test func crowdedTabsShrinkToIconsAndKeepAddButtonInsideWindow() {
        #expect(TabStrip.widthForTabs(count: 2, room: 900) == 220)
        #expect(TabStrip.widthForTabs(count: 10, room: 500) == 50)
        #expect(TabStrip.widthForTabs(count: 50, room: 500) == 32)
        let strip = TabStrip(frame: NSRect(x: 0, y: 0, width: 640, height: 40))
        let tabs = (0..<50).map { _ in ExplorerTab(location: .thisMac) }
        strip.reload(tabs, selected: tabs.last)
        strip.layoutSubtreeIfNeeded()
        let add = strip.subviews.compactMap { $0 as? ToolButton }.first
        #expect(add != nil && add!.frame.maxX <= strip.bounds.maxX)
        let scroll = strip.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scroll?.documentView?.frame.width == 1600)
        #expect(scroll?.documentVisibleRect.maxX == 1600)
        tabs.forEach { $0.tearDown() }
    }
}
