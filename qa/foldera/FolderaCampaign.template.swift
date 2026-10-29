import AppKit
import CryptoKit
import Testing
@testable import Foldera

private struct CampaignCase: Codable, CustomTestStringConvertible {
    let id: String
    let operation: String
    let name: String
    let fixture: String
    let fixture_index: Int
    var testDescription: String { "\(id) \(operation) \(fixture) \(name)" }
    static let all: [Self] = {
        let all = try! JSONDecoder().decode([Self].self,
            from: Data(base64Encoded: "__CASES_BASE64__")!)
        guard let selected = ProcessInfo.processInfo.environment["FOLDERA_CAMPAIGN_RETRY_IDS"] else { return all }
        let ids = Set(selected.split(separator: ",").map(String.init))
        return all.filter { ids.contains($0.id) }
    }()
}

private struct CampaignFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// All paths start inside a freshly created temporary directory, never a user's
/// documents, real clipboard, Trash, synced folders or mounted network shares.
private final class CampaignScratch {
    let root: URL
    private let fm = FileManager.default
    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FolderaCampaign-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func owned(_ url: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard parent.hasPrefix(base), url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw CampaignFailure("Refusing non-owned path: \(url.path)")
        }
    }
    @discardableResult func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try owned(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ url: URL, _ data: Data) throws {
        try owned(url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
    }
    func fixture(_ c: CampaignCase, at url: URL) throws {
        try owned(url)
        switch c.fixture {
        case "empty-file": try write(url, Data())
        case "text": try write(url, Data("Foldera \(c.id)\nline two\n".utf8))
        case "unicode-content": try write(url, Data("ČćŽšĐ — Радни сто — 柜子 🪚\n\(c.id)".utf8))
        case "binary-4k", "binary-128k":
            let size = c.fixture == "binary-4k" ? 4096 : 131072
            try write(url, Data((0..<size).map { UInt8(($0 * 31 + c.fixture_index) % 256) }))
        case "symlink":
            let reference = root.appendingPathComponent("reference-\(UUID().uuidString).txt")
            try write(reference, Data("symlink referent \(c.id)".utf8))
            try fm.createSymbolicLink(at: url, withDestinationURL: reference)
        default:
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            if c.fixture == "nested-folder" {
                try write(url.appendingPathComponent("inner/child.txt"), Data(c.id.utf8))
                try write(url.appendingPathComponent(".hidden"), Data("hidden".utf8))
            } else if c.fixture == "wide-folder" {
                for i in 0..<12 { try write(url.appendingPathComponent("child-\(i).bin"), Data(repeating: UInt8(i), count: i * 100)) }
            } else if c.fixture == "deep-folder" {
                try write(url.appendingPathComponent("one/two/three/four/five/six/leaf.txt"), Data(c.id.utf8))
            }
        }
    }
    func remove(_ url: URL) throws { try owned(url); try fm.removeItem(at: url) }
    deinit {
        // root is constructed above, not supplied by a case, model or user path.
        let temporary = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        if resolved.path.hasPrefix(temporary), resolved.lastPathComponent.hasPrefix("FolderaCampaign-") {
            try? fm.removeItem(at: resolved)
        }
    }
}

private func snapshot(_ root: URL) throws -> [String: String] {
    let fm = FileManager.default
    var manifest = [String: String]()
    func visit(_ url: URL, _ path: String) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            manifest[path] = "symlink:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
        } else if type == .typeDirectory {
            manifest[path] = "directory"
            for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                try visit(url.appendingPathComponent(name), path.isEmpty ? name : path + "/" + name)
            }
        } else {
            let bytes = try Data(contentsOf: url)
            manifest[path] = "file:\(bytes.count):" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
    try visit(root, "")
    return manifest
}

private func must(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw CampaignFailure(reason) }
}

/// Append one independent record per parameterized invocation; suite serialized.
private func record(_ c: CampaignCase, started: Date, error: Error?) throws {
    guard let directory = ProcessInfo.processInfo.environment["FOLDERA_CAMPAIGN_RESULTS"] else {
        throw CampaignFailure("Use run-on-mac.sh to set the separate report directory")
    }
    let row: [String: Any] = ["id": c.id, "operation": c.operation, "name": c.name,
        "fixture": c.fixture, "status": error == nil ? "passed" : "needs_reproduction",
        "seconds": Date().timeIntervalSince(started), "error": error.map { String(describing: $0) } ?? "",
        "attempt": Int(ProcessInfo.processInfo.environment["FOLDERA_CAMPAIGN_ATTEMPT"] ?? "1") ?? 1,
        "layer": "real Foldera API, not GUI", "finished": ISO8601DateFormatter().string(from: Date())]
    var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    bytes.append(0x0A)
    let path = URL(fileURLWithPath: directory).appendingPathComponent("cases.jsonl")
    if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path, options: .withoutOverwriting) }
    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
}

@Suite(.serialized) @MainActor
struct FolderaCampaign {
    @Test(arguments: CampaignCase.all)
    fileprivate func operations(_ c: CampaignCase) throws {
        let started = Date()
        do {
            try run(c)
        } catch {
            try record(c, started: started, error: error)
            throw error
        }
        try record(c, started: started, error: nil)
    }

    private func run(_ c: CampaignCase) throws {
        let s = try CampaignScratch()
        let fm = FileManager.default
        let sourceFolder = try s.folder("source")
        let destination = try s.folder("destination")
        let source = sourceFolder.appendingPathComponent(c.name)
        let sentinel = s.root.appendingPathComponent("untouched-sentinel.bin")
        try s.write(sentinel, Data("DO NOT CHANGE \(c.id)".utf8))
        let sentinelBefore = try snapshot(sentinel)
        try s.fixture(c, at: source)
        let before = try snapshot(source)
        let sourceFolderBefore = try snapshot(sourceFolder)
        let references = try fm.contentsOfDirectory(at: s.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("reference-") }
        let referenceBefore = try references.map { try snapshot($0) }
        let target = destination.appendingPathComponent(c.name)

        func plan(_ into: URL, move: Bool, choice: Transfer.Clash = .stop) throws -> Transfer.Plan {
            try s.owned(into.appendingPathComponent("guard"))
            guard let p = Transfer.plan([source], into: into, move: move, ask: { _, _, _ in (choice, false) }) else {
                throw CampaignFailure("Unexpected cancelled plan")
            }
            for step in p.steps {
                try s.owned(step.from); try s.owned(step.to)
                // A replacement sends the previous destination to the real
                // macOS Trash. This campaign never executes that operation.
                try must(!step.replace, "Unexpected real-Trash replacement in isolated campaign")
            }
            try must(p.problems.isEmpty, "Plan problems: \(p.problems)")
            return p
        }
        func perform(_ p: Transfer.Plan, move: Bool) throws -> Transfer.Outcome {
            let result = Transfer(plan: p, move: move).perform()
            try must(result.failures.isEmpty, "Transfer failed: \(result.failures)")
            try must(!result.cancelled, "Unexpected transfer cancellation")
            return result
        }

        switch c.operation {
        case "copy", "move":
            let move = c.operation == "move"
            let result = try perform(plan(destination, move: move), move: move)
            try must(result.made.count == 1, "Expected one completed transfer")
            try must(try snapshot(target) == before, "Destination bytes/tree/link differs")
            try must(FileOps.exists(source) == !move, "Incorrect source retention")
            if !move { try must(try snapshot(source) == before, "Copy changed original") }
        case "same-copy", "same-move":
            let move = c.operation == "same-move"
            let p = try plan(sourceFolder, move: move)
            if move {
                try must(p.steps.isEmpty, "Move into same directory must be a no-op")
                _ = try perform(p, move: true)
                try must(try snapshot(sourceFolder) == sourceFolderBefore, "Same-folder move changed directory")
            } else {
                try must(p.steps.count == 1, "Same-folder copy needs one separate target")
                let copy = try #require(p.steps.first?.to)
                try must(copy != source, "Copy targeted original")
                try must(copy.lastPathComponent.contains(" - Copy"), "Expected Copy naming")
                _ = try perform(p, move: false)
                try must(try snapshot(copy) == before, "Same-folder copy differs")
                try must(try snapshot(source) == before, "Original was changed")
            }
        case "keep-copy", "keep-move", "skip-copy", "skip-move", "stop":
            try s.write(target, Data("KEEP EXISTING \(c.id)".utf8))
            let oldTarget = try snapshot(target)
            let move = c.operation.hasSuffix("move")
            if c.operation == "stop" {
                let p = Transfer.plan([source], into: destination, move: false, ask: { _, _, _ in (.stop, false) })
                try must(p == nil, "Stop must cancel planning")
            } else if c.operation.hasPrefix("skip") {
                let p = try plan(destination, move: move, choice: .skip)
                try must(p.steps.isEmpty, "Skip must not schedule a transfer")
                _ = try perform(p, move: move)
            } else {
                let p = try plan(destination, move: move, choice: .keepBoth)
                try must(p.steps.count == 1, "Keep Both needs one new target")
                let alternative = try #require(p.steps.first?.to)
                try must(alternative != target, "Keep Both targeted existing item")
                _ = try perform(p, move: move)
                try must(try snapshot(alternative) == before, "Keep Both lost source content")
            }
            try must(try snapshot(target) == oldTarget, "Existing target was changed")
            let retained = !c.operation.hasPrefix("keep") || !move
            try must(FileOps.exists(source) == retained, "Incorrect source retention after clash")
            if retained { try must(try snapshot(source) == before, "Clash changed source") }
        case "rename", "rename-trim":
            let name = "renamed-" + c.name
            let proposed = c.operation == "rename-trim" ? " \t" + name + "\n " : name
            let renamed = try FileOps.rename(source, to: proposed)
            try s.owned(renamed)
            try must(renamed.lastPathComponent == name, "Incorrect renamed name/space trimming")
            try must(!FileOps.exists(source), "Old name remains after rename")
            try must(try snapshot(renamed) == before, "Rename changed bytes/tree/link")
            // Rename undo/redo uses only owned same-volume moves, no Trash.
            let undo = FileUndo.Manager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            FileUndo.record([.moved(from: source, to: renamed)], name: "QA Rename", in: undo)
            undo.endUndoGrouping()
            try must(undo.canUndo, "Rename did not enter undo history")
            undo.undo()
            try must(try snapshot(source) == before, "Rename undo failed to restore content")
            try must(!FileOps.exists(renamed), "Renamed entry remains after undo")
            try must(undo.canRedo, "Rename redo unavailable")
            undo.redo()
            try must(try snapshot(renamed) == before, "Rename redo changed content")
            try must(!FileOps.exists(source), "Old entry remains after redo")
        case "rename-collision", "rename-invalid":
            var proposed = "existing-" + c.name
            let existing = sourceFolder.appendingPathComponent(proposed)
            if c.operation == "rename-collision" {
                try s.write(existing, Data("EXISTING \(c.id)".utf8))
            } else {
                proposed = ["", "   ", ".", "..", "a/b", "a:b", "\t\r\n", "../escape", "/absolute", "a/b/c"][c.fixture_index]
            }
            let originalFolder = try snapshot(sourceFolder)
            var rejected = false
            do { _ = try FileOps.rename(source, to: proposed) } catch { rejected = true }
            try must(rejected, "Unsafe/colliding rename was accepted")
            try must(try snapshot(sourceFolder) == originalFolder, "Rejected rename changed files")
        case "descendant":
            // Wrap every fixture in a directory so all 100 cases exercise
            // self-descendant protection with different real content.
            let child = try s.folder("source/inside")
            let folderBefore = try snapshot(sourceFolder)
            let p = try #require(Transfer.plan([sourceFolder], into: child, move: c.fixture_index % 2 == 0,
                ask: { _, _, _ in (.stop, false) }))
            try must(p.steps.isEmpty && !p.problems.isEmpty, "Descendant destination was not rejected")
            try must(try snapshot(sourceFolder) == folderBefore, "Rejected descendant plan changed files")
        case "stale-copy", "stale-move":
            let move = c.operation == "stale-move"
            let p = try plan(destination, move: move)
            let missingSource = c.fixture_index % 2 == 0
            if missingSource {
                try s.remove(source)
            } else {
                // Another writer takes the target after planning: never clobber.
                try s.write(target, Data("another writer \(c.id)".utf8))
            }
            let destinationBefore = try snapshot(destination)
            let result = Transfer(plan: p, move: move).perform()
            try must(!result.failures.isEmpty, "Stale source/destination reported successful transfer")
            try must(result.made.isEmpty && result.changes.isEmpty, "Failed transfer entered completed changes")
            try must(try snapshot(destination) == destinationBefore, "Stale plan damaged destination/staging leaked")
            if !missingSource { try must(try snapshot(source) == before, "Raced transfer damaged original") }
        case "new-items":
            // Number of pre-existing default names varies with fixture, while
            // the varied real source fixture must remain unchanged.
            let count = c.fixture_index + 1
            var folders = [URL](), documents = [URL]()
            for _ in 0..<count {
                folders.append(try FileOps.makeFolder(in: sourceFolder))
                documents.append(try FileOps.makeTextFile(in: sourceFolder))
            }
            try must(Set(folders.map(\.path)).count == count, "Duplicate new folder names")
            try must(Set(documents.map(\.path)).count == count, "Duplicate new text file names")
            for (i, url) in folders.enumerated() {
                try must(url.lastPathComponent == (i == 0 ? "New folder" : "New folder (\(i + 1))"), "Wrong new-folder collision suffix")
            }
            for (i, url) in documents.enumerated() {
                try must(url.lastPathComponent == (i == 0 ? "New Text Document.txt" : "New Text Document (\(i + 1)).txt"), "Wrong text-file collision suffix")
                try must(try Data(contentsOf: url).isEmpty, "New text document is not empty")
            }
            try must(try snapshot(source) == before, "Creating default items modified original")
        case "remove-tree":
            try s.owned(source)
            try FileOps.removeTree(source)
            try must(!FileOps.exists(source), "Deleted disposable item remains")
        case "merge-copy", "merge-move":
            let move = c.operation == "merge-move"
            let mergeSource = try s.folder("merge-source")
            let mergeDestination = try s.folder("merge-destination")
            let oldParent = source.deletingLastPathComponent()
            let wrapped = mergeSource.appendingPathComponent(oldParent.lastPathComponent)
            try fm.createDirectory(at: wrapped, withIntermediateDirectories: false)
            // A separate varied fixture avoids changing the setup source.
            try s.fixture(c, at: wrapped.appendingPathComponent(c.name))
            let mergingBefore = try snapshot(wrapped)
            let receiving = mergeDestination.appendingPathComponent(wrapped.lastPathComponent)
            try fm.createDirectory(at: receiving, withIntermediateDirectories: false)
            let retainedFile = receiving.appendingPathComponent("KEEP-\(UUID().uuidString).bin")
            try s.write(retainedFile, Data("existing destination child".utf8))
            let retainedBefore = try snapshot(retainedFile)
            let p = try #require(Transfer.plan([wrapped], into: mergeDestination, move: move,
                ask: { _, folders, _ in (folders ? .merge : .stop, false) }))
            try must(p.problems.isEmpty && p.steps.allSatisfy { !$0.replace }, "Unexpected merge replacement/problems")
            for step in p.steps { try s.owned(step.from); try s.owned(step.to) }
            _ = try perform(p, move: move)
            var received = try snapshot(receiving)
            received.removeValue(forKey: retainedFile.lastPathComponent)
            try must(received == mergingBefore, "Merged content differs")
            try must(try snapshot(retainedFile) == retainedBefore, "Merge changed existing unrelated child")
            try must(FileOps.exists(wrapped) == !move, "Merge move did not clean empty source / copy removed source")
            try must(try snapshot(source) == before, "Merge affected unrelated original fixture")
        default: throw CampaignFailure("Unknown case family: \(c.operation)")
        }
        try must(try snapshot(sentinel) == sentinelBefore, "Unrelated sentinel was damaged")
        for (index, reference) in references.enumerated() {
            try must(try snapshot(reference) == referenceBefore[index], "Symlink referent was damaged")
        }
        let leftovers = try fm.subpathsOfDirectory(atPath: s.root.path).filter { $0.hasSuffix(".foldera-transfer") }
        try must(leftovers.isEmpty, "Transfer staging leftovers: \(leftovers)")
    }
}
