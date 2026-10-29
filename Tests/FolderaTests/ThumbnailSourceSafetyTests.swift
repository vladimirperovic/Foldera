import Foundation
import Darwin
import Testing
@testable import Foldera

@Suite struct ThumbnailSourceSafety {
    @Test(arguments: [false, true])
    func aNamedPipeCannotHoldAThumbnailWorker(link: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaThumbnailPipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { FileOps.removeOwn(root) }
        let pipe = root.appendingPathComponent("pipe.jpg")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let target: URL
        if link {
            target = root.appendingPathComponent("link.jpg")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: pipe)
        } else { target = pipe }

        let finished = CancelFlag(), rejected = CancelFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            if ThumbnailSource(target) == nil { rejected.set() }
            finished.set()
        }
        // If opening regresses to a blocking open, provide a writer after
        // the assertion deadline so this regression cannot hang the suite.
        defer {
            let rescue = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if rescue >= 0 { close(rescue) }
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished.isSet, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished.isSet && rejected.isSet)
    }
}
