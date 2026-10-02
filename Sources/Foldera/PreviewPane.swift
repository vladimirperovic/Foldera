import AppKit
import CoreServices
import ImageIO
import Quartz

/// A view whose origin is at the top, for content that grows downwards.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The pane on the right (⇧⌘P, or ⌥P as Alt+P in Windows): a live preview
/// of the selected file by Quick Look, and what Windows' details pane says
/// about it. With nothing selected, it describes the folder.
final class PreviewPane: NSView {
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let stage = NSView()
    /// Quick Look and the Markdown page are heavy (a web view each); they
    /// are made the first time a file needs them, not with every tab.
    private var quickLook: QLPreviewView?
    private let picture = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var previewed: String?

    // Markdown files: the rendered page, or the text to edit, over the whole pane.
    private let markdownBox = NSView()
    private let markdownName = NSTextField(labelWithString: "")
    private lazy var markdownView = MarkdownView()
    private lazy var markdownEditor = MarkdownTextView()
    private var markdownBuilt = false
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private var markdownFile: URL?
    private var markdownSaved = ""
    /// The file's date when it was read or last saved here, to notice another app's changes.
    private var markdownVersion: Date?
    private var editing = false
    private var editorButton: NSButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildMarkdown() {
        guard !markdownBuilt else { return }
        markdownBuilt = true
        markdownName.font = .boldSystemFont(ofSize: 12)
        markdownName.lineBreakMode = .byTruncatingMiddle
        markdownName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editButton.bezelStyle = .push
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(toggleEditing(_:))
        let window = NSButton(image: NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Open in editor")!,
                              target: self, action: #selector(openEditor(_:)))
        window.bezelStyle = .push
        window.controlSize = .small
        window.toolTip = "Open in the Markdown editor, with the text and the page side by side"
        editorButton = window
        let header = NSStackView(views: [markdownName, NSView(), editButton, window])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        let line = NSBox()
        line.boxType = .separator
        markdownView.fontSize = 13
        markdownEditor.isHidden = true
        for v in [header, line, markdownView, markdownEditor] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            markdownBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: markdownBox.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: markdownBox.trailingAnchor),
            header.topAnchor.constraint(equalTo: markdownBox.topAnchor),
            line.leadingAnchor.constraint(equalTo: markdownBox.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: markdownBox.trailingAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        for body in [markdownView, markdownEditor] as [NSView] {
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: markdownBox.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: markdownBox.trailingAnchor),
                body.topAnchor.constraint(equalTo: line.bottomAnchor),
                body.bottomAnchor.constraint(equalTo: markdownBox.bottomAnchor),
            ])
        }
        markdownBox.isHidden = true
        pin(markdownBox, in: self)
    }

    private func build() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        pin(scroll, in: self)

        picture.imageScaling = .scaleProportionallyUpOrDown
        pin(picture, in: stage, inset: 24)

        title.font = .boldSystemFont(ofSize: 14)
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byTruncatingMiddle
        info.isSelectable = true
        for v in [stage, title, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        let height = stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 0.85)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stage.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            height,
            stage.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            title.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            info.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: info.bottomAnchor, constant: 16),
        ])
    }

    private func pin(_ view: NSView, in container: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: Showing

    /// Waits a moment, so holding an arrow key through a list doesn't preview every file on the way.
    func show(_ selection: [FileItem], in location: Location, count: Int) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render(selection, location, count) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Stops a playing preview when the pane is put away, and keeps any Markdown edits.
    func clear() {
        pending?.cancel()
        finishEditing(movingOn: true)
        quickLook?.previewItem = nil
        previewed = nil
    }

    private func render(_ selection: [FileItem], _ location: Location, _ count: Int) {
        generation += 1
        let generation = generation
        var rows: [(String, String)] = []
        var slow: (() -> [(String, String)])?

        if selection.count == 1, let item = selection.first, !item.isFolder, Markdown.isMarkdown(item.url) {
            showMarkdown(item.url)
            return
        }
        hideMarkdown()

        if selection.count == 1, let item = selection.first, !item.isFolder {
            showPreview(item.url)
            title.stringValue = item.name
            rows.append(("Type", item.kind))
            if let size = item.size { rows.append(("Size", "\(Format.bytes(size))  (\(Format.count(size)) bytes)")) }
            rows += dates(item) + extras(item)
            if item.url.deletingLastPathComponent().key != location.url?.key {
                rows.append(("Location", Format.path(item.url.deletingLastPathComponent())))
            }
            let url = item.url
            let unread = item.knownTags == nil ? item : nil
            slow = { Self.tagRows(unread) + Self.contentDetails(url) }
        } else if selection.count == 1, let item = selection.first {
            showPicture(item.icon)
            title.stringValue = item.name
            rows.append(("Type", item.kind))
            if let size = item.folderSize { rows.append(("Size on disk", "\(Format.bytes(size))  (\(Format.count(size)) bytes)")) }
            if let volume = item.volume {
                rows.append(("Free space", "\(Format.bytes(volume.free)) of \(Format.bytes(volume.total))"))
            }
            rows += dates(item) + extras(item)
            let url = folderTarget(item)
            let hidden = Prefs.showHidden
            let unread = item.knownTags == nil ? item : nil
            slow = { Self.tagRows(unread) + [("Contains", Self.countDescription(url, hidden: hidden))] }
        } else if !selection.isEmpty {
            showPicture(NSWorkspace.shared.icon(forFiles: selection.map(\.url.path)) ?? selection[0].icon)
            title.stringValue = "\(Format.items(selection.count)) selected"
            let sizes = selection.compactMap(\.size)
            if !sizes.isEmpty { rows.append(("Size of files", Format.bytes(sizes.reduce(0, +)))) }
            let folders = selection.filter(\.isFolder).count
            if folders > 0 { rows.append(("Folders", Format.count(Int64(folders)))) }
            let kinds = Array(Set(selection.map(\.kind))).sorted()
            rows.append(("Types", kinds.count <= 3 ? kinds.joined(separator: ", ") : "\(kinds.count) kinds"))
        } else {
            showPicture(location.icon)
            title.stringValue = location.title
            rows.append(("Contains", Format.items(count)))
            if let url = location.url {
                rows.append(("Location", Format.path(url)))
                if let tags = Tags.names(of: url).nilIfEmpty { rows.append(("Tags", tags.joined(separator: ", "))) }
            }
        }
        setRows(rows)

        guard let slow else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let more = slow()
            DispatchQueue.main.async {
                guard let self, self.generation == generation, !more.isEmpty else { return }
                self.setRows(rows + more)
            }
        }
    }

    // MARK: Markdown

    private func showMarkdown(_ url: URL) {
        buildMarkdown()
        if previewed != nil {
            quickLook?.previewItem = nil
            previewed = nil
        }
        if markdownFile?.key != url.key {
            finishEditing(movingOn: true)
            markdownFile = url
            markdownName.stringValue = url.lastPathComponent
            if !loadMarkdown(url) {
                markdownSaved = ""
                markdownVersion = nil
                markdownView.show("Foldera couldn't read this file.", file: url)
            }
        } else if !editing, TextFile.version(of: url) != markdownVersion {
            // Changed by another app since it was shown.
            loadMarkdown(url)
        }
        // What is inside an opened archive is shown, not edited: the archive itself wouldn't change.
        let readOnly = ArchiveFolders.isInside(url)
        editButton.isEnabled = !readOnly
        editorButton?.isEnabled = !readOnly
        scroll.isHidden = true
        markdownBox.isHidden = false
    }

    @discardableResult private func loadMarkdown(_ url: URL) -> Bool {
        guard let text = TextFile.read(url) else { return false }
        markdownVersion = TextFile.version(of: url)
        markdownSaved = text
        markdownView.show(markdownSaved, file: url)
        return true
    }

    private func hideMarkdown() {
        guard markdownFile != nil else { return }
        finishEditing(movingOn: true)
        markdownFile = nil
        markdownBox.isHidden = true
        scroll.isHidden = false
    }

    private func setEditing(_ on: Bool) {
        editing = on
        editButton.title = on ? "Done" : "Edit"
        markdownEditor.isHidden = !on
        markdownView.isHidden = on
    }

    @objc private func toggleEditing(_ sender: Any?) {
        if editing {
            finishEditing(movingOn: false)
        } else {
            guard let url = markdownFile, !ArchiveFolders.isInside(url) else { return }
            guard loadMarkdown(url) else {
                FileOps.report(["Foldera can't read “\(url.lastPathComponent)” as text."])
                return
            }
            markdownEditor.text.string = markdownSaved
            setEditing(true)
            window?.makeFirstResponder(markdownEditor.text)
        }
    }

    /// Saves what was typed and shows the page again. Done keeps the editor
    /// open when saving fails, to try again; moving on to another file hands
    /// the text to an editor window instead, so it is never lost.
    private func finishEditing(movingOn: Bool) {
        guard editing, let url = markdownFile else { return }
        if !save() {
            guard movingOn else { return }
            MarkdownEditor.show(url, unsaved: markdownEditor.text.string, previouslySaved: markdownSaved)
        }
        setEditing(false)
        markdownView.show(markdownSaved, file: url)
    }

    /// ⌘S while editing in the pane.
    @objc func saveDocument(_ sender: Any?) { save() }

    /// True once what is in the editor is on disk, or was set aside on purpose.
    @discardableResult private func save() -> Bool {
        guard editing, let url = markdownFile, markdownEditor.text.string != markdownSaved else { return true }
        switch TextFile.checkBeforeSaving(url, saved: markdownSaved) {
        case .cancel:
            return false
        case .reload:
            guard loadMarkdown(url) else { return false }
            markdownEditor.text.string = markdownSaved
            return true
        case .overwrite:
            break
        }
        do {
            try TextFile.write(markdownEditor.text.string, to: url)
            markdownSaved = markdownEditor.text.string
            markdownVersion = TextFile.version(of: url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc private func openEditor(_ sender: Any?) {
        guard let url = markdownFile, !ArchiveFolders.isInside(url) else { return }
        finishEditing(movingOn: true)
        MarkdownEditor.show(url)
    }

    private func folderTarget(_ item: FileItem) -> URL {
        item.isSymlink ? item.url.resolvingSymlinksInPath() : item.url
    }

    private func dates(_ item: FileItem) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let modified = item.modified { rows.append(("Modified", Format.date.string(from: modified))) }
        if let created = item.created { rows.append(("Created", Format.date.string(from: created))) }
        return rows
    }

    /// Tags already read; the others are read with the slow details, off the main thread.
    private func extras(_ item: FileItem) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let tags = item.knownTags, !tags.isEmpty { rows.append(("Tags", tags.joined(separator: ", "))) }
        if let cloud = item.cloud { rows.append(("iCloud", cloud.description)) }
        return rows
    }

    static func tagRows(_ item: FileItem?) -> [(String, String)] {
        guard let tags = item?.tags, !tags.isEmpty else { return [] }
        return [("Tags", tags.joined(separator: ", "))]
    }

    private func showPreview(_ url: URL) {
        let preview = quickLook ?? makeQuickLook()
        picture.isHidden = true
        preview.isHidden = false
        if previewed != url.key {
            previewed = url.key
            preview.previewItem = url as NSURL
        }
    }

    private func makeQuickLook() -> QLPreviewView {
        let preview: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
        preview.shouldCloseWithWindow = true
        preview.autostarts = false
        pin(preview, in: stage)
        quickLook = preview
        return preview
    }

    private func showPicture(_ image: NSImage) {
        if previewed != nil {
            quickLook?.previewItem = nil
            previewed = nil
        }
        quickLook?.isHidden = true
        picture.isHidden = false
        picture.image = image
    }

    private func setRows(_ rows: [(String, String)]) {
        let text = NSMutableAttributedString()
        for (i, row) in rows.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 4)])) }
            text.append(NSAttributedString(string: row.0 + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            text.append(NSAttributedString(string: row.1, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            ]))
        }
        info.attributedStringValue = text
    }

    // MARK: Details that take a moment (background)

    static func countDescription(_ folder: URL, hidden: Bool) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Format.items(hidden ? names.count : names.filter { !$0.hasPrefix(".") }.count)
    }

    /// Picture size and camera, page count, running time, where a download came from.
    static func contentDetails(_ url: URL) -> [(String, String)] {
        var rows: [(String, String)] = []
        if ImageFiles.isImage(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                rows.append(("Dimensions", "\(w) × \(h) px"))
            }
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if !camera.isEmpty { rows.append(("Camera", camera)) }
            if let taken = (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String {
                rows.append(("Taken", taken))
            }
        }
        if url.pathExtension.lowercased() == "pdf", let document = CGPDFDocument(url as CFURL) {
            rows.append(("Pages", Format.count(Int64(document.numberOfPages))))
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            if let seconds = (MDItemCopyAttribute(item, kMDItemDurationSeconds) as? NSNumber)?.doubleValue, seconds > 0 {
                let s = Int(seconds.rounded())
                rows.append(("Length", s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                                  : String(format: "%d:%02d", s / 60, s % 60)))
            }
            if let authors = MDItemCopyAttribute(item, kMDItemAuthors) as? [String], !authors.isEmpty {
                rows.append(("Authors", authors.joined(separator: ", ")))
            }
            if let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], let first = sources.first {
                rows.append(("Downloaded from", URL(string: first)?.host ?? first))
            }
        }
        return rows
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
