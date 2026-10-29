import Foundation
import Darwin
import Testing
@testable import Foldera

/// Both flags synchronize their storage; the probe only shares those flags.
private final class ThumbnailProbe: @unchecked Sendable {
    let finished = CancelFlag()
    let rejected = CancelFlag()
}

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

        let probe = ThumbnailProbe()
        DispatchQueue.global(qos: .userInitiated).async {
            if ThumbnailSource(target) == nil { probe.rejected.set() }
            probe.finished.set()
        }
        // If opening regresses to a blocking open, provide a writer after
        // the assertion deadline so this regression cannot hang the suite.
        defer {
            let rescue = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if rescue >= 0 { close(rescue) }
        }
        let deadline = Date().addingTimeInterval(3)
        while !probe.finished.isSet, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.finished.isSet && probe.rejected.isSet)
    }
}
