import AppKit
import Testing
@testable import Foldera

/// Explicit completion makes cancellation and late delivery deterministic.
private final class TestPromise {
    private let offeredNames: [String]
    private var names: [String] = []
    private var reader: ((URL, Error?) -> Void)?
    private var queue: OperationQueue?
    private(set) var folder: URL?

    init(_ names: [String]) { offeredNames = names }

    var source: PromisedFiles.Source {
        PromisedFiles.Source(names: { self.names }, typeCount: offeredNames.count) { folder, queue, reader in
            self.folder = folder
            self.queue = queue
            self.reader = reader
            self.names = self.offeredNames
        }
    }

    @discardableResult func send(_ name: String, text: String = "received", error: Error? = nil) throws -> URL {
        let url = try #require(folder).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        complete(url, error: error)
        return url
    }

    func complete(_ url: URL, error: Error? = nil) {
        guard let queue, let reader else { Issue.record("Promise was not requested"); return }
        queue.addOperation { reader(url, error) }
    }
}

private final class PasteboardPromise: NSObject, NSFilePromiseProviderDelegate {
    private(set) var writes = 0
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "remote.txt"
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        writes += 1
        completionHandler(nil)
    }
}

@MainActor private func promiseEventually(_ condition: () -> Bool) async throws {
    Awake.hold()
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Suite @MainActor struct PromisedFileTests {
    @Test func promiseOnlyClipboardEnablesPasteWithoutReceivingFiles() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let delegate = PasteboardPromise()
        let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: delegate)
        #expect(board.writeObjects([provider]))
        let clipboard = FileClipboard(pasteboard: board)
        #expect(clipboard.urls.isEmpty)
        #expect(clipboard.hasFiles)
        #expect(clipboard.promises.count == 1)
        #expect(delegate.writes == 0)
    }

    @Test func waitsForEveryFileAndKeepsThemUntilTransferFinishes() async throws {
        let source = TestPromise(["one.txt", "two.txt"])
        let job = PromisedFiles(sources: [source.source])
        var outcome: PromisedFiles.Outcome?
        job.start { outcome = $0 }
        let folder = try #require(source.folder)
        let one = try source.send("one.txt", text: "first")
        let two = try source.send("two.txt", text: "second")
        try await promiseEventually { outcome != nil }
        let received = try #require(outcome)
        #expect(Set(received.urls) == Set([one, two]))
        #expect(received.failures.isEmpty)
        #expect(!received.cancelled)
        #expect(try String(contentsOf: one, encoding: .utf8) == "first")
        #expect(try String(contentsOf: two, encoding: .utf8) == "second")
        received.cleanup()
        try await promiseEventually { !FileOps.exists(folder) }
    }

    @Test func cancelLeavesProviderFolderUntilItsLateCallback() async throws {
        let source = TestPromise(["late.txt"])
        let job = PromisedFiles(sources: [source.source])
        var outcome: PromisedFiles.Outcome?
        var completions = 0
        job.start { outcome = $0; completions += 1 }
        let folder = try #require(source.folder)
        job.cancel()
        try await promiseEventually { outcome != nil }
        #expect(outcome?.cancelled == true)
        #expect(outcome?.urls.isEmpty == true)
        outcome?.cleanup()
        #expect(FileOps.exists(folder))
        try source.send("late.txt")
        try await promiseEventually { !FileOps.exists(folder) }
        #expect(completions == 1)
    }

    @Test func failedPromiseDoesNotPublishItsPartialFile() async throws {
        let source = TestPromise(["partial.txt", "whole.txt"])
        let job = PromisedFiles(sources: [source.source])
        var outcome: PromisedFiles.Outcome?
        job.start { outcome = $0 }
        let folder = try #require(source.folder)
        try source.send("partial.txt", error: CocoaError(.fileReadUnknown))
        let whole = try source.send("whole.txt")
        try await promiseEventually { outcome != nil }
        #expect(outcome?.urls == [whole])
        #expect(outcome?.failures.count == 1)
        outcome?.cleanup()
        try await promiseEventually { !FileOps.exists(folder) }
    }

    @Test func repeatedCallbackDoesNotFinishBeforeTheOtherFile() async throws {
        let source = TestPromise(["one.txt", "two.txt"])
        let job = PromisedFiles(sources: [source.source])
        var outcome: PromisedFiles.Outcome?
        job.start { outcome = $0 }
        let folder = try #require(source.folder)
        let first = try source.send("one.txt")
        source.complete(first)
        let second = try source.send("two.txt")
        try await promiseEventually { outcome != nil }
        #expect(Set(outcome?.urls ?? []) == Set([first, second]))
        outcome?.cleanup()
        try await promiseEventually { !FileOps.exists(folder) }
    }

    @Test func missingNamesStillWaitForTheErrorCallback() async throws {
        let source = TestPromise([])
        let job = PromisedFiles(sources: [source.source])
        var outcome: PromisedFiles.Outcome?
        job.start { outcome = $0 }
        let folder = try #require(source.folder)
        source.complete(folder, error: CocoaError(.fileReadUnknown))
        try await promiseEventually { outcome != nil }
        #expect(outcome?.urls.isEmpty == true)
        #expect(outcome?.failures.count == 1)
        outcome?.cleanup()
        try await promiseEventually { !FileOps.exists(folder) }
    }

    @Test func rejectsOutsidePathsAndSymlinksButKeepsPromisedFoldersWhole() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaPromiseTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { FileOps.removeOwn(root) }
        let receiving = root.appendingPathComponent("receiving")
        try fm.createDirectory(at: receiving, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = receiving.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!PromisedFiles.isReceivedFile(outside, in: receiving))
        #expect(!PromisedFiles.isReceivedFile(link, in: receiving))
        #expect(!PromisedFiles.isReceivedFile(receiving.appendingPathComponent("missing.txt"), in: receiving))
        let folder = receiving.appendingPathComponent("Project")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
        #expect(PromisedFiles.isReceivedFile(folder, in: receiving))
        #expect(!PromisedFiles.isReceivedFile(folder.appendingPathComponent("child.txt"), in: receiving))
    }
}
