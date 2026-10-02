import AppKit

/// Checksums as `shasum -a 256` and `sha256sum` write them, so they check
/// out on any system: the SHA-256 in hex, two spaces, the file's name.
enum Checksum {
    static func hex(_ digest: Data) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func line(_ digest: Data, name: String) -> String { "\(hex(digest))  \(name)" }

    static func isChecksumFile(_ url: URL) -> Bool {
        ["sha256", "sha256sum", "sha256sums"].contains(url.pathExtension.lowercased())
    }

    /// The hash and the name each line of a checksum file is for: `hash  name`,
    /// `hash *name` (binary mode) and BSD's `SHA256 (name) = hash`.
    static func entries(in text: String) -> [(hash: String, name: String)] {
        var found: [(hash: String, name: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ", options: .backwards) {
                let name = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                let hash = String(line[close.upperBound...]).lowercased()
                if hash.count == 64 && hash.allSatisfy(\.isHexDigit) { found.append((hash, name)) }
                continue
            }
            let hash = String(line.prefix(64))
            guard line.count > 65, hash.allSatisfy(\.isHexDigit) else { continue }
            var rest = line.dropFirst(64)
            guard rest.first == " " else { continue }
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "*" { rest = rest.dropFirst() }
            if !rest.isEmpty { found.append((hash.lowercased(), String(rest))) }
        }
        return found
    }
}

/// Two files byte by byte, as Total Commander's Compare by Content says it.
enum FileCompare {
    enum Result: Equatable {
        case same
        /// Counted from 0.
        case differ(at: Int64)
    }

    /// Nil when either can't be read, or when it was cancelled.
    static func compare(_ a: URL, _ b: URL, cancelled: CancelFlag, read: (Int64) -> Void = { _ in }) -> Result? {
        guard let x = FileHandle(forReadingAtPath: a.path), let y = FileHandle(forReadingAtPath: b.path) else { return nil }
        defer {
            try? x.close()
            try? y.close()
        }
        var offset: Int64 = 0
        do {
            while !cancelled.isSet {
                let p = try x.read(upToCount: 1 << 20) ?? Data()
                let q = try y.read(upToCount: 1 << 20) ?? Data()
                if p != q {
                    let common = zip(p, q).prefix(while: { $0.0 == $0.1 }).count
                    return .differ(at: offset + Int64(common))
                }
                if p.isEmpty { return .same }
                offset += Int64(p.count)
                read(offset)
            }
        } catch {}
        return nil
    }
}

/// Checksums and comparing files, from the right-click menu and File menu.
extension ExplorerTab {
    /// The files among the selection; folders and packages have no single content to hash.
    var selectedFiles: [URL] {
        selectedItems.filter { !$0.isDirectory && $0.volume == nil }.map(\.url)
    }

    /// Copy SHA-256: the hash alone for one file, `hash  name` lines for several.
    @objc func copyChecksum(_ sender: Any?) {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        readChecksums(files, title: "Calculating SHA-256 of") { [weak self] results in
            let failed = results.filter { $0.digest == nil }.map { "“\($0.url.lastPathComponent)” couldn't be read." }
            let lines = results.compactMap { result in result.digest.map { Checksum.line($0, name: result.url.lastPathComponent) } }
            if files.count == 1, let digest = results.first?.digest {
                Self.copyText(Checksum.hex(digest))
            } else if !lines.isEmpty {
                Self.copyText(lines.joined(separator: "\n"))
            }
            if !failed.isEmpty { FileOps.report(failed) } else { self?.busyNote("SHA-256 copied") }
        }
    }

    /// Writes `name.sha256` beside one file, or `checksums.sha256` for several.
    @objc func createChecksumFile(_ sender: Any?) {
        let files = selectedFiles
        guard !files.isEmpty, !isInArchive, let folder = files.first?.deletingLastPathComponent(),
              Set(files.map { $0.deletingLastPathComponent().key }).count == 1 else { return }
        readChecksums(files, title: "Calculating SHA-256 of") { [weak self] results in
            let failed = results.filter { $0.digest == nil }.map { "“\($0.url.lastPathComponent)” couldn't be read." }
            let lines = results.compactMap { result in result.digest.map { Checksum.line($0, name: result.url.lastPathComponent) } }
            FileOps.report(failed)
            guard !lines.isEmpty, let self else { return }
            let target = FileOps.freeURL(in: folder, base: files.count == 1 ? files[0].lastPathComponent : "checksums", ext: "sha256")
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
                FileUndo.record([.created(target)], name: "Create Checksum File")
                if folder.key == self.location.url?.key {
                    self.pendingSelection = [target.key]
                    self.scrollToSelection = true
                    self.reload()
                }
            } catch {
                self.show(error)
            }
        }
    }

    /// Checks the files a selected `.sha256` file lists against it.
    @objc func verifyChecksums(_ sender: Any?) {
        let lists = selectedFiles.filter(Checksum.isChecksumFile)
        guard !lists.isEmpty else { return }
        var wanted: [(url: URL, hash: String)] = []
        var problems: [String] = []
        for list in lists {
            guard let text = try? String(contentsOf: list, encoding: .utf8) else {
                problems.append("“\(list.lastPathComponent)” couldn't be read.")
                continue
            }
            let entries = Checksum.entries(in: text)
            if entries.isEmpty { problems.append("“\(list.lastPathComponent)” holds no SHA-256 checksums.") }
            for entry in entries {
                wanted.append((URL(fileURLWithPath: entry.name, relativeTo: list.deletingLastPathComponent()).standardizedFileURL, entry.hash))
            }
        }
        let missing = wanted.filter { !FileOps.exists($0.url) }
        problems += missing.map { "“\($0.url.lastPathComponent)” is missing." }
        let present = wanted.filter { FileOps.exists($0.url) }
        guard !present.isEmpty else {
            return tell(problems.isEmpty ? "There is nothing to check." : "The files couldn't be checked.", problems.prefix(10).joined(separator: "\n"))
        }
        readChecksums(present.map(\.url), title: "Verifying") { [weak self] results in
            var bad = problems
            for (result, entry) in zip(results, present) {
                guard let digest = result.digest else {
                    bad.append("“\(entry.url.lastPathComponent)” couldn't be read.")
                    continue
                }
                if Checksum.hex(digest) != entry.hash { bad.append("“\(entry.url.lastPathComponent)” doesn't match.") }
            }
            if bad.isEmpty {
                self?.tell(present.count == 1 ? "The file matches its checksum." : "All \(Format.count(Int64(present.count))) files match their checksums.", "")
            } else {
                self?.tell("\(Format.count(Int64(bad.count))) of \(Format.count(Int64(wanted.count))) files didn't check out.",
                           bad.prefix(10).joined(separator: "\n") + (bad.count > 10 ? "\n…" : ""))
            }
        }
    }

    /// Reads the files in the background, with a progress window that can be
    /// cancelled; `done` gets each file's SHA-256, nil where it couldn't be read.
    private func readChecksums(_ files: [URL], title: String, done: @escaping ([(url: URL, digest: Data?)]) -> Void) {
        let sizes = files.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let total = sizes.reduce(0, +)
        let cancelled = CancelFlag()
        let progress = ProgressWindow(title: "\(title) \(Format.items(files.count))")
        progress.onCancel = { cancelled.set() }
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(url: URL, digest: Data?)] = []
            var before: Int64 = 0
            var last = Date.distantPast
            for (file, size) in zip(files, sizes) {
                if cancelled.isSet { break }
                let digest = Sync.digest(file, cancelled: cancelled) { read in
                    guard Date().timeIntervalSince(last) > 0.1 else { return }
                    last = Date()
                    let fraction = total > 0 ? min(Double(before + read) / Double(total), 1) : 0
                    DispatchQueue.main.async { progress.update(fraction: fraction, text: file.lastPathComponent) }
                }
                results.append((file, digest))
                before += size
            }
            DispatchQueue.main.async {
                progress.finish()
                if !cancelled.isSet { done(results) }
            }
        }
    }

    /// The two files Compare Files works on: two selected here, or one here
    /// and one in the other pane.
    var filesToCompare: (URL, URL)? {
        let here = selectedFiles
        if here.count == 2 && selectedItems.count == 2 { return (here[0], here[1]) }
        if here.count == 1, selectedItems.count == 1, let other = host?.otherPane(of: self) {
            let there = other.selectedFiles
            if there.count == 1 && other.selectedItems.count == 1 && there[0].key != here[0].key { return (here[0], there[0]) }
        }
        return nil
    }

    /// Byte by byte, in the background; says whether they are the same, and
    /// if not, where they first differ.
    @objc func compareFiles(_ sender: Any?) {
        guard let (a, b) = filesToCompare else { return }
        let sizes = [a, b].map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let names = "“\(a.lastPathComponent)” and “\(b.lastPathComponent)”"
        if sizes[0] != sizes[1] {
            return tell("The files are different.", "\(names) aren't the same size: \(Format.bytes(sizes[0])) and \(Format.bytes(sizes[1])).")
        }
        let cancelled = CancelFlag()
        let progress = ProgressWindow(title: "Comparing \(names)")
        progress.onCancel = { cancelled.set() }
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var last = Date.distantPast
            let result = FileCompare.compare(a, b, cancelled: cancelled) { read in
                guard Date().timeIntervalSince(last) > 0.1, sizes[0] > 0 else { return }
                last = Date()
                let fraction = min(Double(read) / Double(sizes[0]), 1)
                DispatchQueue.main.async { progress.update(fraction: fraction, text: a.lastPathComponent) }
            }
            DispatchQueue.main.async {
                progress.finish()
                guard !cancelled.isSet, let self else { return }
                switch result {
                case .same?:
                    self.tell("The files are identical.", "\(names) hold the same \(Format.bytes(sizes[0])), byte for byte.")
                case .differ(let offset)?:
                    self.tell("The files are different.", "\(names) first differ at byte \(Format.count(offset + 1)) of \(Format.count(sizes[0])).")
                case nil:
                    self.tell("The files couldn't be compared.", "One of \(names) couldn't be read.")
                }
            }
        }
    }

    /// A message about what was done, as a sheet on this window.
    func tell(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A short note in the status bar, gone again after a moment.
    func busyNote(_ text: String) {
        busyText = text
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.busyText == text else { return }
            self.busyText = nil
            self.updateStatus()
        }
    }

    static func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
