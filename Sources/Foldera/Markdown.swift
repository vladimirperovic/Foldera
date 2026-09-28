import AppKit
import UniformTypeIdentifiers
import WebKit

/// Markdown to HTML, the GitHub-flavoured parts people write: headings,
/// paragraphs, emphasis, links, pictures, lists (nested, and task lists),
/// quotes, code, tables, rules. HTML in the text is shown, not run.
enum Markdown {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func isMarkdown(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func html(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return blocks(lines[...])
    }

    // MARK: Blocks

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Patterns are compiled once; a long file asks for the same few on every line.
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let regex = compiled.object(forKey: pattern as NSString) { return regex }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiled.setObject(regex, forKey: pattern as NSString)
        return regex
    }

    private static func match(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = regex(pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(line[Range(m.range(at: $0), in: line)!]) }
    }

    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, start: Int, content: Int)? {
        guard let m = match(#"^( *)([-*+]|\d{1,9}[.)])( +|$)"#, line) else { return nil }
        let ordered = m[2].first?.isNumber == true
        return (m[1].count, ordered, ordered ? Int(m[2].dropLast()) ?? 1 : 1, m[0].count)
    }

    private static func isRule(_ line: String) -> Bool {
        match(#"^ {0,3}([-*_])( *\1){2,} *$"#, line) != nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        line.contains("-") && match(#"^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$"#, line) != nil && line.contains(where: { $0 == "|" || $0 == "-" })
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Does this line start something other than a paragraph?
    private static func startsBlock(_ line: String) -> Bool {
        match(#"^ {0,3}(#{1,6}( |$)|```|~~~|>)"#, line) != nil || isRule(line) || listMarker(line) != nil
    }

    private static func blocks(_ input: ArraySlice<String>) -> String {
        var out = ""
        var lines = input
        while let line = lines.first {
            if isBlank(line) {
                lines.removeFirst()
                continue
            }
            // Fenced code.
            if let fence = match(#"^ {0,3}(```+|~~~+) *([^ `]*)"#, line) {
                lines.removeFirst()
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence[1]) {
                    code.append(next)
                    lines.removeFirst()
                }
                if !lines.isEmpty { lines.removeFirst() }
                let language = fence[2].isEmpty ? "" : " class=\"language-\(escape(fence[2]))\""
                out += "<pre><code\(language)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            // Heading.
            if let h = match(#"^ {0,3}(#{1,6})(?: +(.*?))?(?: +#+)? *$"#, line) {
                lines.removeFirst()
                out += "<h\(h[1].count)>\(inline(h[2]))</h\(h[1].count)>\n"
                continue
            }
            if isRule(line) {
                lines.removeFirst()
                out += "<hr>\n"
                continue
            }
            // Quote: strip the markers and render what is inside.
            if match(#"^ {0,3}>"#, line) != nil {
                var inner: [String] = []
                while let next = lines.first, !isBlank(next), match(#"^ {0,3}>"#, next) != nil || !startsBlock(next) {
                    inner.append(next.replacingOccurrences(of: #"^ {0,3}> ?"#, with: "", options: .regularExpression))
                    lines.removeFirst()
                }
                out += "<blockquote>\n\(blocks(inner[...]))</blockquote>\n"
                continue
            }
            // List.
            if let first = listMarker(line) {
                out += list(&lines, first)
                continue
            }
            // Indented code.
            if indent(line) >= 4 {
                var code: [String] = []
                while let next = lines.first, indent(next) >= 4 || isBlank(next) {
                    code.append(String(next.dropFirst(min(4, indent(next)))))
                    lines.removeFirst()
                }
                while code.last.map(isBlank) == true { code.removeLast() }
                out += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            // Table: a row of cells over a divider row.
            if line.contains("|"), lines.count > 1, isTableDivider(lines[lines.startIndex + 1]) {
                out += table(&lines)
                continue
            }
            // Paragraph, or a setext heading when underlined.
            var text: [String] = []
            while let next = lines.first, !isBlank(next), text.isEmpty || !startsBlock(next) {
                if !text.isEmpty, let underline = match(#"^ {0,3}(=+|-+) *$"#, next) {
                    lines.removeFirst()
                    let level = underline[1].hasPrefix("=") ? 1 : 2
                    out += "<h\(level)>\(inline(text.joined(separator: " ")))</h\(level)>\n"
                    text = []
                    break
                }
                text.append(next)
                lines.removeFirst()
            }
            if !text.isEmpty { out += "<p>\(paragraph(text))</p>\n" }
        }
        return out
    }

    /// Lines joined; two trailing spaces or a backslash make a line break.
    private static func paragraph(_ text: [String]) -> String {
        text.enumerated().map { i, line -> String in
            let last = i == text.count - 1
            if !last && (line.hasSuffix("  ") || line.hasSuffix("\\")) {
                return inline(line.trimmingCharacters(in: CharacterSet(charactersIn: " \\"))) + "<br>"
            }
            return inline(line.trimmingCharacters(in: .whitespaces))
        }.joined(separator: "\n")
    }

    private static func list(_ lines: inout ArraySlice<String>, _ first: (indent: Int, ordered: Bool, start: Int, content: Int)) -> String {
        var items: [[String]] = []
        var loose = false
        while let line = lines.first {
            if let marker = listMarker(line), marker.indent < first.content, marker.ordered == first.ordered {
                lines.removeFirst()
                items.append([String(line.dropFirst(marker.content))])
                continue
            }
            if isBlank(line) {
                // A blank line ends the list unless the next line goes on with it.
                let after = lines.dropFirst().first
                guard let after, !isBlank(after),
                      indent(after) >= first.content || listMarker(after).map({ $0.indent < first.content && $0.ordered == first.ordered }) == true
                else { break }
                loose = true
                items[items.count - 1].append("")
                lines.removeFirst()
                continue
            }
            guard !items.isEmpty else { break }
            if indent(line) >= first.content || (!startsBlock(line) && items[items.count - 1].last.map(isBlank) == false) {
                items[items.count - 1].append(String(line.dropFirst(min(first.content, indent(line)))))
                lines.removeFirst()
                continue
            }
            break
        }
        let tag = first.ordered ? "ol" : "ul"
        let start = first.ordered && first.start != 1 ? " start=\"\(first.start)\"" : ""
        var out = "<\(tag)\(start)>\n"
        for item in items {
            var content = item
            var task = ""
            if let box = match(#"^\[([ xX])\] "#, content[0]) {
                task = "<input type=\"checkbox\" disabled\(box[1] == " " ? "" : " checked")> "
                content[0].removeFirst(4)
            }
            let inner = blocks(content[...])
            let tight = !loose && inner.hasPrefix("<p>") && inner.components(separatedBy: "<p>").count == 2
            let body = tight ? inner.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>", with: "") : inner
            out += "<li\(task.isEmpty ? "" : " class=\"task\"")>\(task)\(body.trimmingCharacters(in: .newlines))</li>\n"
        }
        return out + "</\(tag)>\n"
    }

    private static func table(_ lines: inout ArraySlice<String>) -> String {
        let header = cells(lines.removeFirst())
        let aligns = cells(lines.removeFirst()).map { cell -> String in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return " style=\"text-align:center\""
            case (false, true): return " style=\"text-align:right\""
            case (true, false): return " style=\"text-align:left\""
            default: return ""
            }
        }
        func align(_ i: Int) -> String { i < aligns.count ? aligns[i] : "" }
        var out = "<table>\n<thead><tr>" + header.enumerated().map { "<th\(align($0))>\(inline($1))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
        while let line = lines.first, !isBlank(line), line.contains("|") {
            lines.removeFirst()
            let row = cells(line)
            out += "<tr>" + header.indices.map { "<td\(align($0))>\($0 < row.count ? inline(row[$0]) : "")</td>" }.joined() + "</tr>\n"
        }
        return out + "</tbody>\n</table>\n"
    }

    // MARK: Inline

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Only link to places a reader would want to go; never run a script.
    private static func safe(_ url: String) -> String {
        let lower = url.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text") ? "#" : url
    }

    private static func replace(_ text: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let regex = regex(pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(m.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(text[Range(m.range(at: $0), in: text)!]) }
            result += make(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }

    static func inline(_ source: String) -> String {
        // Code spans first, kept aside so nothing inside them is formatted.
        var kept: [String] = []
        func keep(_ html: String) -> String {
            kept.append(html)
            return "\u{E000}\(kept.count - 1)\u{E001}"
        }
        var text = replace(source, #"(`+)(.+?)\1"#) { keep("<code>\(escape($0[2].trimmingCharacters(in: .whitespaces)))</code>") }
        text = replace(text, #"\\([\\`*_{}\[\]()#+\-.!|~<>])"#) { keep(escape($0[1])) }
        text = escape(text)
        text = replace(text, #"!\[([^\]]*)\]\(([^)\s]+)(?: &quot;([^&]*)&quot;)?\)"#) {
            keep("<img src=\"\(safe($0[2]))\" alt=\"\($0[1])\"\($0[3].isEmpty ? "" : " title=\"\($0[3])\"")>")
        }
        text = replace(text, #"\[([^\]]+)\]\(([^)\s]+)(?: &quot;([^&]*)&quot;)?\)"#) {
            "<a href=\"\(safe($0[2]))\"\($0[3].isEmpty ? "" : " title=\"\($0[3])\"")>\($0[1])</a>"
        }
        text = replace(text, #"&lt;((?:https?|mailto):[^&\s]+)&gt;"#) { "<a href=\"\($0[1])\">\($0[1])</a>" }
        text = replace(text, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { "<strong>\($0[2])</strong>" }
        text = replace(text, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?!\*)"#) { "<em>\($0[1])</em>" }
        text = replace(text, #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#) { "<em>\($0[1])</em>" }
        text = replace(text, #"~~(?=\S)(.+?)(?<=\S)~~"#) { "<del>\($0[1])</del>" }
        return replace(text, "\u{E000}(\\d+)\u{E001}") { kept[Int($0[1]) ?? 0] }
    }

    // MARK: Page

    /// A whole page, styled like GitHub, light or dark with the app.
    static func page(_ text: String, base: URL, fontSize: Int = 14) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><base href="\(escape(base.absoluteString))">
        <style>
        :root { color-scheme: light dark; }
        body { font: \(fontSize)px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 14px 18px 40px;
               color: #1f2328; background: #ffffff; word-wrap: break-word; }
        h1, h2 { border-bottom: 1px solid #d1d9e0; padding-bottom: .25em; }
        h1 { font-size: 1.8em; margin: .4em 0 .6em; } h2 { font-size: 1.45em; margin: 1.2em 0 .6em; }
        h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
        a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: .88em ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(129,139,152,.15);
               padding: .15em .35em; border-radius: 5px; }
        pre { background: #f6f8fa; padding: 12px 14px; border-radius: 8px; overflow: auto; }
        pre code { background: none; padding: 0; font-size: .86em; }
        blockquote { margin: 0 0 1em; padding: 0 1em; color: #59636e; border-left: .25em solid #d1d9e0; }
        table { border-collapse: collapse; margin: 0 0 1em; display: block; overflow: auto; }
        th, td { border: 1px solid #d1d9e0; padding: 5px 12px; } th { background: #f6f8fa; }
        img { max-width: 100%; border-radius: 4px; }
        hr { border: 0; border-top: 2px solid #d1d9e0; margin: 1.5em 0; }
        ul, ol { padding-left: 1.8em; } li.task { list-style: none; margin-left: -1.4em; }
        li > input { margin-right: .4em; }
        @media (prefers-color-scheme: dark) {
          body { color: #e6edf3; background: #1e1e1e; }
          h1, h2, blockquote, th, td, hr { border-color: #3d444d; }
          a { color: #4493f8; } blockquote { color: #9198a1; }
          pre, th { background: #2a2a2a; }
        }
        </style></head><body>
        \(html(text))
        </body></html>
        """
    }
}

/// Shows rendered Markdown. JavaScript is off; links open in the browser
/// (or, for local files, with their app) instead of inside the view.
///
/// The view gets no access to the disk. The page and the pictures come
/// through `LocalPictures`, which hands out only pictures from the file's
/// folder (and a couple of levels up, for `../images/x.png`).
final class MarkdownView: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private let pictures = LocalPictures()
    /// The file on screen; showing it again only swaps the text, keeping the scroll position.
    private var shown: URL?
    var fontSize = 14

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(pictures, forURLScheme: LocalPictures.scheme)
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Renders `text`; pictures and links are found relative to `file`'s folder.
    func show(_ text: String, file: URL) {
        if shown?.key == file.key, !web.isLoading, let body = try? JSONEncoder().encode(Markdown.html(text)),
           let literal = String(data: body, encoding: .utf8) {
            // The same file edited: only the text changes. (Scripts in the
            // page are off; this one comes from the app, not the file.)
            pictures.page = Markdown.page(text, base: pictures.base, fontSize: fontSize)
            web.evaluateJavaScript("document.body.innerHTML = \(literal); 0") { [weak self] _, error in
                // Should the swap ever fail, load the page whole rather than leave it stale.
                guard error != nil, let self else { return }
                self.web.load(URLRequest(url: self.pictures.pageURL))
            }
            return
        }
        shown = file
        pictures.serve(file.deletingLastPathComponent())
        pictures.page = Markdown.page(text, base: pictures.base, fontSize: fontSize)
        web.load(URLRequest(url: pictures.pageURL))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if url.scheme == LocalPictures.scheme {
            // A link to a file beside this one opens it with its app; one within the page goes nowhere.
            if url.path != pictures.pageURL.path, let file = pictures.file(for: url) { NSWorkspace.shared.open(file) }
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Serves a Markdown page and the pictures near it to a web view that
/// otherwise can't read files.
final class LocalPictures: NSObject, WKURLSchemeHandler {
    static let scheme = "foldera-md"
    private static let pageName = ".foldera-page.html"
    /// The folder that stands for "/" in the page's address.
    private var root = URL(fileURLWithPath: "/")
    private(set) var base = URL(string: "\(scheme)://files/")!
    var page = ""
    var pageURL: URL { base.appendingPathComponent(Self.pageName) }

    /// Serves `folder`, with up to two folders above it (never above the home folder or a drive).
    func serve(_ folder: URL) {
        var top = folder.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<2 where top.path != home && top.path != "/" && !isVolumeRoot(top) {
            top.deleteLastPathComponent()
        }
        root = top
        let inside = String(folder.standardizedFileURL.path.dropFirst(top.path.count)).split(separator: "/")
        base = inside.reduce(URL(string: "\(Self.scheme)://files/")!) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// The file an address in the page stands for, if it is inside what is served.
    func file(for url: URL) -> URL? {
        let file = root.appendingPathComponent(String(url.path.drop { $0 == "/" })).standardizedFileURL
        let top = root.resolvingSymlinksInPath().path
        let real = file.resolvingSymlinksInPath().path
        return real.hasPrefix(top == "/" ? "/" : top + "/") ? file : nil
    }

    /// WebKit calls this on the main thread, where `serve` and `page` are set.
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let body: Data?
        let type: String
        if url.path == pageURL.path {
            body = page.data(using: .utf8)
            type = "text/html"
        } else if let file = file(for: url), let kind = UTType(filenameExtension: file.pathExtension), kind.conforms(to: .image) {
            body = try? Data(contentsOf: file)
            type = kind.preferredMIMEType ?? "application/octet-stream"
        } else {
            body = nil
            type = ""
        }
        guard let body else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: body.count,
                                    textEncodingName: type == "text/html" ? "utf-8" : nil))
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A plain text editor for Markdown: monospaced, no smart quotes or
/// automatic replacements that would change what is written.
final class MarkdownTextView: NSScrollView {
    let text: NSTextView

    override init(frame: NSRect) {
        let scroll = NSTextView.scrollableTextView()
        text = scroll.documentView as! NSTextView
        super.init(frame: frame)
        documentView = text
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        text.isRichText = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 12)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.usesFindBar = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A Markdown editor window: the text on the left, the page on the right,
/// updated as you type. ⌘S saves; closing asks when there are changes.
final class MarkdownEditor: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var open: [MarkdownEditor] = []
    let file: URL
    private let editor = MarkdownTextView()
    private let preview = MarkdownView()
    private var pending: DispatchWorkItem?
    private var saved = ""

    static func show(_ file: URL) {
        if let existing = open.first(where: { $0.file.key == file.key }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            FileOps.report(["Foldera can't read “\(file.lastPathComponent)” as text."])
            return
        }
        let controller = MarkdownEditor(file: file, text: text)
        open.append(controller)
        controller.showWindow(nil)
    }

    private init(file: URL, text: String) {
        self.file = file
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MarkdownEditor")
        super.init(window: window)
        window.delegate = self
        window.representedURL = file
        saved = text
        editor.text.string = text
        editor.text.delegate = self
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(editor)
        split.addArrangedSubview(preview)
        window.contentView = split
        split.setPosition(550, ofDividerAt: 0)
        preview.show(text, file: file)
        updateTitle()
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var dirty: Bool { editor.text.string != saved }

    private func updateTitle() {
        window?.title = file.lastPathComponent + (dirty ? " — Edited" : "")
        window?.isDocumentEdited = dirty
    }

    func textDidChange(_ notification: Notification) {
        updateTitle()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.preview.show(self.editor.text.string, file: self.file)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// ⌘S (File › Save, found through the responder chain).
    @objc func saveDocument(_ sender: Any?) {
        do {
            try editor.text.string.write(to: file, atomically: true, encoding: .utf8)
            saved = editor.text.string
            updateTitle()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(file.lastPathComponent)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !dirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
