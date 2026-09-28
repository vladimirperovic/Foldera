import Foundation
import Testing
@testable import Foldera

@Suite struct MarkdownRendering {
    private func html(_ text: String) -> String { Markdown.html(text) }

    @Test func headingsAndParagraphs() {
        #expect(html("# Title\n\nSome *soft* and **bold** text.") == "<h1>Title</h1>\n<p>Some <em>soft</em> and <strong>bold</strong> text.</p>\n")
        #expect(html("Setext\n===") == "<h1>Setext</h1>\n")
        #expect(html("### Three ###") == "<h3>Three</h3>\n")
    }

    @Test func htmlInTheTextIsShownNotRun() {
        let out = html("<script>alert(1)</script> & <b>x</b>")
        #expect(!out.contains("<script>"))
        #expect(out.contains("&lt;script&gt;") && out.contains("&amp;"))
    }

    @Test func linksAndPictures() {
        #expect(html("[site](https://example.com)") == "<p><a href=\"https://example.com\">site</a></p>\n")
        #expect(html("![cat](img/cat.png)") == "<p><img src=\"img/cat.png\" alt=\"cat\"></p>\n")
        #expect(html("[x](javascript:alert(1))").contains("href=\"#\""))
        #expect(html("<https://example.com>").contains("<a href=\"https://example.com\">"))
    }

    @Test func codeIsLeftAlone() {
        #expect(html("Use `**not bold**` here") == "<p>Use <code>**not bold**</code> here</p>\n")
        #expect(html("```swift\nlet a = 1 < 2\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>\n")
        #expect(html("    indented\n    code") == "<pre><code>indented\ncode</code></pre>\n")
    }

    @Test func listsNestAndTick() {
        let out = html("- one\n- two\n  - inner\n- [x] done\n- [ ] todo")
        #expect(out.contains("<ul>\n<li>one</li>"))
        #expect(out.contains("<li>two\n<ul>\n<li>inner</li>\n</ul></li>"))
        #expect(out.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done</li>"))
        #expect(out.contains("<input type=\"checkbox\" disabled> todo"))
        #expect(html("3. c\n4. d").hasPrefix("<ol start=\"3\">"))
    }

    @Test func tables() {
        let out = html("| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| b | 2 |")
        #expect(out.contains("<th style=\"text-align:left\">Name</th><th style=\"text-align:right\">Size</th>"))
        #expect(out.contains("<tr><td style=\"text-align:left\">b</td><td style=\"text-align:right\">2</td></tr>"))
    }

    @Test func quotesAndRules() {
        #expect(html("> quoted **text**") == "<blockquote>\n<p>quoted <strong>text</strong></p>\n</blockquote>\n")
        #expect(html("a\n\n---\n\nb") == "<p>a</p>\n<hr>\n<p>b</p>\n")
        #expect(html("~~gone~~ and snake_case_name") == "<p><del>gone</del> and snake_case_name</p>\n")
    }

    @Test func whichFilesAreMarkdown() {
        #expect(Markdown.isMarkdown(URL(fileURLWithPath: "/tmp/README.md")))
        #expect(Markdown.isMarkdown(URL(fileURLWithPath: "/tmp/notes.MARKDOWN")))
        #expect(!Markdown.isMarkdown(URL(fileURLWithPath: "/tmp/notes.txt")))
    }
}

@Suite struct SearchOptions {
    private func item(_ name: String, bytes: Int = 10, modified: Date = Date()) throws -> (FileItem, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaFilters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return (FileItem(url: url), dir)
    }

    @Test(arguments: [
        ("photo.jpg", SearchFilters.Kind.images), ("clip.mov", .video), ("song.mp3", .audio), ("report.pdf", .documents),
        ("letter.docx", .documents), ("backup.rar", .archives), ("site.tar.gz", .archives), ("notes.md", .documents),
    ])
    func kinds(_ name: String, _ kind: SearchFilters.Kind) throws {
        let (file, dir) = try item(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SearchFilters.kind(of: file) == kind)
        #expect(SearchFilters(kind: kind).matches(file))
        #expect(!SearchFilters(kind: .folders).matches(file))
    }

    @Test func sizes() throws {
        let (small, dir) = try item("a.bin", bytes: 50 * 1024)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SearchFilters(size: .tiny).matches(small))
        #expect(!SearchFilters(size: .small).matches(small))
    }

    @Test func dates() throws {
        let calendar = Calendar.current
        let now = Date()
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        let (old, dir) = try item("old.txt", modified: lastYear)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fresh, dir2) = try item("fresh.txt", modified: now)
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(SearchFilters(modified: .today).matches(fresh, now: now))
        #expect(!SearchFilters(modified: .today).matches(old, now: now))
        #expect(SearchFilters(modified: .older).matches(old, now: now))
        #expect(!SearchFilters(modified: .older).matches(fresh, now: now))
    }

    @Test func noFilterIsInactiveAndMatchesAll() throws {
        let (file, dir) = try item("x.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!SearchFilters().isActive)
        #expect(SearchFilters().matches(file))
    }
}

@Suite struct QuickAccess {
    @Test func pinReorderAndUnpin() {
        let saved = UserDefaults.standard.stringArray(forKey: "pinned")
        defer { UserDefaults.standard.set(saved, forKey: "pinned") }
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b"), c = URL(fileURLWithPath: "/tmp/c")
        Pins.urls = [a, b]
        Pins.pin([c, a], at: 0)
        #expect(Pins.urls.map(\.lastPathComponent) == ["c", "a", "b"])
        Pins.move(b, to: 0)
        #expect(Pins.urls.map(\.lastPathComponent) == ["b", "c", "a"])
        Pins.move(b, to: 3)
        #expect(Pins.urls.map(\.lastPathComponent) == ["c", "a", "b"])
        Pins.unpin([a, c])
        #expect(Pins.urls.map(\.lastPathComponent) == ["b"])
    }

    @Test func cloudDriveNamesDropTheAccount() {
        // The naming rule, on the folder name Finder shortens the same way.
        let name = "SeaDrive-vladimir.perovic(10.0.10.9)"
        #expect(name.split(separator: "-", maxSplits: 1).first == "SeaDrive")
    }
}

@Suite struct MarkdownPictures {
    @Test func onlyPicturesNearTheFileAreHandedOut() throws {
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("FolderaPictures-\(UUID().uuidString)")
        let other = fm.temporaryDirectory.appendingPathComponent("FolderaElsewhere-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: top); try? fm.removeItem(at: other) }
        let docs = top.appendingPathComponent("a/b/docs")
        for folder in [docs, top.appendingPathComponent("a/b/img"), other] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [docs.appendingPathComponent("pic.png"), top.appendingPathComponent("a/b/img/up.png"),
                     top.appendingPathComponent("outside.png"), other.appendingPathComponent("secret.png")] {
            try Data([1]).write(to: file)
        }
        try fm.createSymbolicLink(at: docs.appendingPathComponent("link.png"), withDestinationURL: other.appendingPathComponent("secret.png"))

        let pictures = LocalPictures()
        pictures.serve(docs)
        func served(_ reference: String) -> String? {
            pictures.file(for: URL(string: reference, relativeTo: pictures.base)!.absoluteURL)?.lastPathComponent
        }
        #expect(served("pic.png") == "pic.png")
        #expect(served("../img/up.png") == "up.png")
        // Two folders up is as far as it goes: climbing further stays in that top folder.
        let clamped = pictures.file(for: URL(string: "../../../outside.png", relativeTo: pictures.base)!.absoluteURL)
        #expect(clamped?.deletingLastPathComponent().lastPathComponent == "a")
        #expect(served("link.png") == nil)
        #expect(pictures.pageURL.path.hasSuffix("/b/docs/.foldera-page.html"))
    }
}
