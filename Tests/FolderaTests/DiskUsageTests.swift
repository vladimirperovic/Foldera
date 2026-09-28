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
}
