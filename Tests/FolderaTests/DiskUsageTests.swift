import Foundation
import Testing
@testable import Foldera

@Suite struct DiskUsage {
    @Test func treemapFillsTheRectangleWithoutOverlap() {
        let values: [Double] = [60, 25, 10, 3, 2]
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rects = Treemap.layout(values, in: rect)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - rect.width * rect.height) < 1)
        for (value, r) in zip(values, rects) {
            #expect(abs(r.width * r.height / (rect.width * rect.height) - value / 100) < 0.001)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        // Squarified: the big one should not be a sliver.
        #expect(min(rects[0].width, rects[0].height) / max(rects[0].width, rects[0].height) > 0.5)
    }

    @Test func emptyOrZeroGivesNothing() {
        #expect(Treemap.layout([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(Treemap.layout([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == [.zero, .zero])
    }

    @Test func scanningAddsUpFoldersAndKeepsBigFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaUsage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("big/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("small"), withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: root.appendingPathComponent("big/inner/movie.mov"))
        try Data(count: 4096).write(to: root.appendingPathComponent("small/a.txt"))
        try Data(count: 4096).write(to: root.appendingPathComponent("small/b.txt"))
        let tree = try #require(UsageScanner().scan(root))
        #expect(tree.files == 3)
        #expect(tree.children.map(\.name) == ["big", "small"])
        let movie = try #require(tree.find(root.appendingPathComponent("big/inner/movie.mov")))
        #expect(movie.kind == .video)
        #expect(movie.size >= 2 * 1024 * 1024)
        let small = try #require(tree.find(root.appendingPathComponent("small")))
        #expect(small.children.isEmpty && small.smallCount == 2)
        #expect(small.blocks.count == 1 && small.blocks[0].isRest)

        let before = tree.size
        movie.remove()
        #expect(tree.size == before - movie.size)
        #expect(tree.find(root.appendingPathComponent("big/inner"))?.children.isEmpty == true)
    }

    /// An exFAT disk (or FAT, or a share) is measured without asking for what
    /// lives in "._" files there: the same tree, packages known by their names.
    @Test func aForeignDiskIsMeasuredTheSameWithoutTheExtraQuestions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FolderaForeign-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("big"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
        try Data(count: 2 * 1024 * 1024).write(to: root.appendingPathComponent("big/movie.mov"))
        try Data(count: 4096).write(to: root.appendingPathComponent("Tool.app/Contents/Info.plist"))
        try Data(count: 4096).write(to: root.appendingPathComponent("notes.txt"))
        #expect(!UsageScanner.isForeign(root)) // The temporary folder is on APFS.

        let native = try #require(UsageScanner().scan(root, foreign: false))
        let scanner = UsageScanner()
        let foreign = try #require(scanner.scan(root, foreign: true))
        #expect(foreign.files == native.files && foreign.files == 3)
        #expect(foreign.children.map(\.name) == native.children.map(\.name))
        #expect(foreign.size >= 2 * 1024 * 1024)
        #expect(foreign.find(root.appendingPathComponent("Tool.app"))?.isPackage == true)
        #expect(foreign.find(root.appendingPathComponent("big"))?.isPackage == false)
        // Done: the status line has the whole count, and no folder being read.
        #expect(scanner.progress.files == 3 && scanner.progress.folder == nil)
    }

    @Test func theStatusLineSaysWhichFolderASlowDiskIsOn() {
        let now = Date()
        var progress = UsageScanner.Progress(files: 9500, bytes: Int64(94) << 30,
                                             folder: URL(fileURLWithPath: "/Volumes/MOODBOARD/_katalog"), since: now)
        #expect(progress.note(now: now).hasPrefix("Measuring… "))
        #expect(!progress.note(now: now).contains("reading"))
        progress.since = now.addingTimeInterval(-12)
        #expect(progress.note(now: now).hasSuffix(" · reading “_katalog” (12 s)"))
    }
}
