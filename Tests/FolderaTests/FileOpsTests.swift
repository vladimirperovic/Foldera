import Foundation
import Testing
@testable import Foldera

/// A fresh folder per test, removed afterwards.
private final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String) -> URL {
        let file = url.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        return file
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite struct Naming {
    @Test func newFoldersCountUpLikeWindows() throws {
        let s = try Scratch()
        #expect(try FileOps.makeFolder(in: s.url).lastPathComponent == "New folder")
        #expect(try FileOps.makeFolder(in: s.url).lastPathComponent == "New folder (2)")
        #expect(try FileOps.makeFolder(in: s.url).lastPathComponent == "New folder (3)")
    }

    @Test func newTextDocumentsKeepTheirExtension() throws {
        let s = try Scratch()
        #expect(try FileOps.makeTextFile(in: s.url).lastPathComponent == "New Text Document.txt")
        #expect(try FileOps.makeTextFile(in: s.url).lastPathComponent == "New Text Document (2).txt")
    }

    @Test func copiesInTheSameFolderAreCalledCopy() throws {
        let s = try Scratch()
        let report = s.file("report.pdf")
        #expect(FileOps.copyName(for: report, in: s.url).lastPathComponent == "report - Copy.pdf")
        s.file("report - Copy.pdf")
        #expect(FileOps.copyName(for: report, in: s.url).lastPathComponent == "report - Copy (2).pdf")
    }

    @Test func foldersWithDotsAreNotSplitAtTheDot() throws {
        let s = try Scratch()
        let folder = try s.folder("v1.2 release")
        #expect(FileOps.copyName(for: folder, in: s.url).lastPathComponent == "v1.2 release - Copy")
        #expect(FileOps.keepBothName(for: folder, in: s.url).lastPathComponent == "v1.2 release (2)")
    }

    @Test func keepBothStartsAtTwo() throws {
        let s = try Scratch()
        let photo = s.file("photo.jpg")
        #expect(FileOps.keepBothName(for: photo, in: s.url).lastPathComponent == "photo (2).jpg")
    }
}

@Suite struct Renaming {
    @Test func renamesAFile() throws {
        let s = try Scratch()
        let renamed = try FileOps.rename(s.file("a.txt"), to: "b.txt")
        #expect(renamed.lastPathComponent == "b.txt")
        #expect(FileOps.exists(renamed))
        #expect(!FileOps.exists(s.url.appendingPathComponent("a.txt")))
    }

    @Test func refusesToOverwrite() throws {
        let s = try Scratch()
        let a = s.file("a.txt")
        s.file("b.txt")
        #expect(throws: OpError.self) { try FileOps.rename(a, to: "b.txt") }
        #expect(FileOps.exists(a))
    }

    @Test func changingOnlyTheCaseWorks() throws {
        let s = try Scratch()
        let renamed = try FileOps.rename(s.file("readme.md"), to: "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: s.url.path)
        #expect(renamed.lastPathComponent == "README.md")
        #expect(names == ["README.md"])
    }

    @Test(arguments: ["", "   ", "a/b", "a:b", ".", ".."])
    func refusesBadNames(_ name: String) throws {
        let s = try Scratch()
        let a = s.file("a.txt")
        #expect(throws: OpError.self) { try FileOps.rename(a, to: name) }
    }

    @Test func trimsSurroundingSpaces() throws {
        let s = try Scratch()
        #expect(try FileOps.rename(s.file("a.txt"), to: "  b.txt ").lastPathComponent == "b.txt")
    }
}

@Suite struct Places {
    @Test func insideMeansTheSameFolderOrBelow() throws {
        let s = try Scratch()
        let parent = try s.folder("p")
        let child = try s.folder("p/c")
        let sibling = try s.folder("p2")
        #expect(FileOps.isInside(child, parent))
        #expect(FileOps.isInside(parent, parent))
        #expect(!FileOps.isInside(parent, child))
        #expect(!FileOps.isInside(sibling, parent))
    }

    @Test func addressBarPartsStartAtThisMac() {
        let parts = AddressBar.parts(for: .folder(URL(fileURLWithPath: "/Users/someone/Documents")))
        #expect(parts.map(\.title).first == "This Mac")
        #expect(parts.map(\.title).suffix(3) == ["Users", "someone", "Documents"])
        #expect(parts.last?.location == .folder(URL(fileURLWithPath: "/Users/someone/Documents")))
    }

    @Test func externalDrivesAreTheirOwnRoot() {
        let parts = AddressBar.parts(for: .folder(URL(fileURLWithPath: "/Volumes/USB/Photos")))
        #expect(parts.map(\.location) == [
            .thisMac, .folder(URL(fileURLWithPath: "/Volumes/USB")), .folder(URL(fileURLWithPath: "/Volumes/USB/Photos")),
        ])
    }

    @Test func locationsIgnoreTrailingSlashes() {
        #expect(Location.folder(URL(fileURLWithPath: "/tmp/x/")) == .folder(URL(fileURLWithPath: "/tmp/x")))
    }
}

@Suite struct Listing {
    @Test func foldersComeFirstThenNaturalOrder() throws {
        let s = try Scratch()
        s.file("file10.txt")
        s.file("file2.txt")
        try s.folder("zeta")
        try s.folder("Alpha")
        let names = try FileItem.contents(of: s.url, showHidden: false)
            .sorted(by: SortSpec(key: .name, ascending: true)).map(\.name)
        #expect(names == ["Alpha", "zeta", "file2.txt", "file10.txt"])
        let reversed = try FileItem.contents(of: s.url, showHidden: false)
            .sorted(by: SortSpec(key: .name, ascending: false)).map(\.name)
        #expect(reversed == ["file10.txt", "file2.txt", "zeta", "Alpha"])
    }

    @Test func hiddenFilesOnlyWhenAsked() throws {
        let s = try Scratch()
        s.file(".secret")
        s.file("plain")
        #expect(try FileItem.contents(of: s.url, showHidden: false).map(\.name) == ["plain"])
        #expect(try FileItem.contents(of: s.url, showHidden: true).count == 2)
    }

    @Test func sizesAreWrittenInKilobytesRoundedUp() {
        #expect(Format.kilobytes(0) == "0 KB")
        #expect(Format.kilobytes(1) == "1 KB")
        #expect(Format.kilobytes(1024) == "1 KB")
        #expect(Format.kilobytes(1025) == "2 KB")
    }

    @Test func searchMatchesWordsAndWildcards() {
        let words = FolderSearch.matcher(for: "report")
        #expect(words("Annual Report 2026.pdf"))
        #expect(!words("summary.pdf"))
        let wildcard = FolderSearch.matcher(for: "*.PDF")
        #expect(wildcard("scan.pdf"))
        #expect(!wildcard("scan.pdf.zip"))
        #expect(FolderSearch.matcher(for: "cafe")("Café menu.txt"))
    }
}
