import AppKit

/// Checksums as `shasum -a 256` and `sha256sum` write them, so they check
/// out on any system: the SHA-256 in hex, two spaces, the file's name.
enum Checksum {
    static func hex(_ digest: Data) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func line(_ digest: Data, name: String) -> String {
        var escaped = "", needsEscaping = false
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 92: escaped += "\\\\"; needsEscaping = true
            case 10: escaped += "\\n"; needsEscaping = true
            case 13: escaped += "\\r"; needsEscaping = true
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return (needsEscaping ? "\\" : "") + "\(hex(digest))  \(escaped)"
    }

    static func isChecksumFile(_ url: URL) -> Bool {
        ["sha256", "sha256sum", "sha256sums"].contains(url.pathExtension.lowercased())
    }

    /// The hash and the name each line of a checksum file is for: `hash  name`,
    /// `hash *name` (binary mode) and BSD's `SHA256 (name) = hash`.
    static func entries(in text: String) -> [(hash: String, name: String)] {
        var found: [(hash: String, name: String)] = []
        // Spaces at either end of the filename are significant. Only remove
        // the CR in a Windows line ending, never trim the whole record.
        for raw in text.components(separatedBy: "\n") {
            var bytes = Array(raw.utf8)
            if bytes.last == 13 { bytes.removeLast() }
            if bytes.isEmpty { continue }
            let escaped = bytes.first == 92
            if escaped { bytes.removeFirst() }
            // The separators are ASCII bytes, not graphemes: a filename may
            // begin with a combining mark which joins the preceding space.
            if bytes.starts(with: Array("SHA256 (".utf8)), bytes.count >= 12,
               let close = stride(from: bytes.count - 4, through: 8, by: -1).first(where: {
                   bytes[$0..<($0 + 4)].elementsEqual([41, 32, 61, 32])
               }) {
                let name = String(decoding: bytes[8..<close], as: UTF8.self)
                let hash = String(decoding: bytes[(close + 4)...], as: UTF8.self).lowercased()
                if validHash(hash), let decoded = decode(name, escaped: escaped) { found.append((hash, decoded)) }
                continue
            }
            guard bytes.count > 66, bytes[64] == 32, bytes[65] == 32 || bytes[65] == 42 else { continue }
            let hash = String(decoding: bytes.prefix(64), as: UTF8.self)
            guard validHash(hash) else { continue }
            if let name = decode(String(decoding: bytes.dropFirst(66), as: UTF8.self), escaped: escaped) {
                found.append((hash.lowercased(), name))
            }
        }
        return found
    }

    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func decode(_ name: String, escaped: Bool) -> String? {
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        guard escaped else { return name }
        var result = "", scalars = name.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else { result.unicodeScalars.append(scalar); continue }
            switch scalars.next() {
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "r": result.append("\r")
            default: return nil
            }
        }
        return result
    }

    struct Verification {
        var present: [(url: URL, hash: String)] = []
        var problems: [String] = []
    }

    /// Run off the main thread: a checksum list can live on a disconnected
    /// share and can itself name thousands of files. Check each path once.
    static func verification(_ lists: [URL], cancelled: CancelFlag) -> Verification {
        var plan = Verification()
        for list in lists {
            if cancelled.isSet { return plan }
            guard let reader = StableFileReader(list),
                  let bytes = try? reader.handle.readToEnd(), reader.isCurrent,
                  let text = String(data: bytes, encoding: .utf8) else {
                plan.problems.append("“\(list.lastPathComponent)” couldn't be read.")
                continue
            }
            let entries = entries(in: text)
            if entries.isEmpty { plan.problems.append("“\(list.lastPathComponent)” holds no SHA-256 checksums.") }
            for entry in entries {
                if cancelled.isSet { return plan }
                let url = URL(fileURLWithPath: entry.name, relativeTo: list.deletingLastPathComponent()).standardizedFileURL
                if FileOps.exists(url) { plan.present.append((url, entry.hash)) }
                else { plan.problems.append("“\(url.lastPathComponent)” is missing.") }
            }
        }
        return plan
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
        guard !cancelled.isSet, let x = StableFileReader(a), let y = StableFileReader(b) else { return nil }
        var offset: Int64 = 0
        do {
            while !cancelled.isSet {
                let p = try x.handle.read(upToCount: 1 << 20) ?? Data()
                let q = try y.handle.read(upToCount: 1 << 20) ?? Data()
                if p != q {
                    guard !cancelled.isSet, x.isCurrent, y.isCurrent else { return nil }
                    let common = zip(p, q).prefix(while: { $0.0 == $0.1 }).count
                    return .differ(at: offset + Int64(common))
                }
                if p.isEmpty {
                    guard !cancelled.isSet, offset == x.size, offset == y.size, x.isCurrent, y.isCurrent else { return nil }
                    return .same
                }
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
        let clipboardGeneration = NSPasteboard.general.changeCount
        readChecksums(files, title: "Calculating SHA-256 of") { [weak self] results in
            let failed = results.filter { $0.digest == nil }.map { "“\($0.url.lastPathComponent)” couldn't be read." }
            let lines = results.compactMap { result in result.digest.map { Checksum.line($0, name: result.url.lastPathComponent) } }
            guard NSPasteboard.general.changeCount == clipboardGeneration else {
                self?.busyNote("The clipboard changed while calculating SHA-256")
                FileOps.report(failed)
                return
            }
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
                try FileOps.createFile(Data((lines.joined(separator: "\n") + "\n").utf8), at: target)
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
        let cancelled = CancelFlag()
        let progress = ProgressWindow(title: "Reading checksum files")
        progress.onCancel = { cancelled.set() }
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = Checksum.verification(lists, cancelled: cancelled)
            DispatchQueue.main.async {
                progress.finish()
                guard !cancelled.isSet, let self else { return }
                self.verifyChecksumPlan(plan)
            }
        }
    }

    private func verifyChecksumPlan(_ plan: Checksum.Verification) {
        let present = plan.present, problems = plan.problems
        guard !present.isEmpty else {
            return tell(problems.isEmpty ? "There is nothing to check." : "The files couldn't be checked.", problems.prefix(10).joined(separator: "\n"))
        }
        readChecksums(present.map(\.url), title: "Verifying") { [weak self] results in
            var bad = problems
            for (result, entry) in zip(results, present) {
                guard let digest = result.digest else {
                    bad.append("“\(entry.url.lastPathComponent)” couldn't be read or changed during reading.")
                    continue
                }
                if Checksum.hex(digest) != entry.hash { bad.append("“\(entry.url.lastPathComponent)” doesn't match.") }
            }
            if bad.isEmpty {
                self?.tell(present.count == 1 ? "The file matches its checksum." : "All \(Format.count(Int64(present.count))) files match their checksums.", "")
            } else {
                self?.tell("The checksum verification found \(Format.count(Int64(bad.count))) problems.",
                           bad.prefix(10).joined(separator: "\n") + (bad.count > 10 ? "\n…" : ""))
            }
        }
    }

    /// Reads the files in the background, with a progress window that can be
    /// cancelled; `done` gets each file's SHA-256, nil where it couldn't be read.
    private func readChecksums(_ files: [URL], title: String, done: @escaping ([(url: URL, digest: Data?)]) -> Void) {
        let cancelled = CancelFlag()
        let progress = ProgressWindow(title: "\(title) \(Format.items(files.count))")
        progress.onCancel = { cancelled.set() }
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async {
            var sizes: [Int64] = []
            for file in files {
                if cancelled.isSet { break }
                sizes.append(Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            }
            let total = sizes.reduce(0, +)
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
        let names = "“\(a.lastPathComponent)” and “\(b.lastPathComponent)”"
        let cancelled = CancelFlag()
        let progress = ProgressWindow(title: "Comparing \(names)")
        progress.onCancel = { cancelled.set() }
        progress.showSoon()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sizes = [a, b].map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            if !cancelled.isSet, let x = StableFileReader(a), let y = StableFileReader(b),
               x.size != y.size, x.isCurrent, y.isCurrent {
                let message = "\(names) aren't the same size: \(Format.bytes(x.size)) and \(Format.bytes(y.size))."
                DispatchQueue.main.async {
                    progress.finish()
                    if !cancelled.isSet { self?.tell("The files are different.", message) }
                }
                return
            }
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
                    self.tell("The files are identical.", "\(names) have the same contents, byte for byte.")
                case .differ(let offset)?:
                    self.tell("The files are different.", "\(names) first differ at byte \(Format.count(offset + 1)).")
                case nil:
                    self.tell("The files couldn't be compared.", "One of \(names) couldn't be read or changed during reading.")
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
