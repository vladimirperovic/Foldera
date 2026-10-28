import AppKit
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct ClipboardMoves {
    private let a = URL(fileURLWithPath: "/tmp/FolderaClipboard/a.txt")
    private let b = URL(fileURLWithPath: "/tmp/FolderaClipboard/b.txt")

    @Test func aFinishedMoveDoesNotClearANewerCut() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.put([a], cut: true)
        let started = clipboard.changeCount
        clipboard.put([b], cut: true)

        clipboard.completeMove(of: [a], changeCount: started, moved: [a])

        #expect(clipboard.urls == [b])
        #expect(clipboard.isCut(b.key))
        #expect(clipboard.hasFiles)
    }

    @Test func aPartialMoveKeepsOnlyUnmovedSourcesReadyToMove() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.put([a, b], cut: true)
        let started = clipboard.changeCount
        #expect(clipboard.hasFiles)

        clipboard.completeMove(of: [a, b], changeCount: started, moved: [a])

        #expect(clipboard.urls == [b])
        #expect(!clipboard.isCut(a.key))
        #expect(clipboard.isCut(b.key))
        #expect(clipboard.hasFiles)

        clipboard.completeMove(of: [b], changeCount: started, moved: [b])

        #expect(clipboard.urls.isEmpty)
        #expect(!clipboard.isCut)
        #expect(!clipboard.hasFiles)
    }

    @Test func aFailedOrCancelledMoveLeavesCutReadyToRetry() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.put([a, b], cut: true)

        clipboard.completeMove(of: [a, b], changeCount: clipboard.changeCount, moved: [])

        #expect(clipboard.urls == [a, b])
        #expect(clipboard.isCut(a.key) && clipboard.isCut(b.key))
        #expect(clipboard.hasFiles)
    }

    @Test func movingAChildDoesNotConsumeAPartiallyMergedFolder() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        let folder = a.deletingLastPathComponent()
        clipboard.put([folder], cut: true)

        clipboard.completeMove(of: [folder], changeCount: clipboard.changeCount, moved: [a])

        #expect(clipboard.urls == [folder])
        #expect(clipboard.isCut(folder.key))
        #expect(clipboard.hasFiles)
    }

    @Test func pasteMoveConsumesAnExternalCopyOnlyForItsCurrentGeneration() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        pasteboard.writeObjects([a as NSURL])

        clipboard.completeMove(of: [a], changeCount: clipboard.changeCount, moved: [a])

        #expect(clipboard.urls.isEmpty)
        #expect(!clipboard.hasFiles)
        // Another app can publish even the same URL again; it is a new request.
        pasteboard.clearContents()
        pasteboard.writeObjects([a as NSURL])
        #expect(clipboard.urls == [a])
        #expect(clipboard.hasFiles)
        #expect(!clipboard.isCut)
    }

    @Test func clearingCutDoesNotBringAlreadyMovedSourcesBack() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pasteboard)
        clipboard.put([a, b], cut: true)
        clipboard.completeMove(of: [a, b], changeCount: clipboard.changeCount, moved: [a])

        clipboard.clearCut()

        #expect(clipboard.urls == [b])
        #expect(!clipboard.isCut)
        #expect(clipboard.hasFiles)
    }
}
