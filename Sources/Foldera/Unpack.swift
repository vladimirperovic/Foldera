import AppKit
import CArchive

/// Unpacks anything the system's libarchive reads: zip, RAR (4 and 5), 7z,
/// tar with gzip, bzip2 or xz, cab and lzh. Entries whose names would land
/// outside the destination (`../`, absolute paths) are left out.
final class Unpacker {
    struct Failure: LocalizedError {
        let errorDescription: String?
        /// A zip that wants a (different) password; the only kind libarchive can decrypt.
        let needsPassword: Bool
    }

    /// libarchive converts names through the C locale; make that UTF-8 once.
    private static let utf8Names: Void = { setlocale(LC_CTYPE, "UTF-8") }()

    let archive: URL
    private let cancelled = CancelFlag()

    init(_ archive: URL) {
        self.archive = archive
        _ = Self.utf8Names
    }

    func cancel() { cancelled.set() }

    /// Unpacks everything into `destination` (created if needed). Returns
    /// the names that were left out for pointing outside it.
    @discardableResult
    func unpack(into destination: URL, password: String? = nil, progress: ((Double) -> Void)? = nil) throws -> [String] {
        let total = Double(max((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1, 1))
        guard let reader = archive_read_new() else { throw Failure(errorDescription: "Foldera couldn't start reading the archive.", needsPassword: false) }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        if let password { archive_read_add_passphrase(reader, password) }
        guard archive_read_open_filename(reader, archive.path, 1 << 16) == ARCHIVE_OK else { throw failure(reader) }
        guard let writer = archive_write_disk_new() else { throw Failure(errorDescription: "Foldera couldn't start writing files.", needsPassword: false) }
        defer { archive_write_free(writer) }
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM
            | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)
        archive_write_disk_set_standard_lookup(writer)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // The real path: libarchive refuses to write through any symbolic link,
        // and /var, /tmp and /etc are links to /private on macOS.
        let destination = realpath(destination.path, nil).map { pointer -> URL in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        } ?? destination

        var skipped: [String] = []
        var entry: OpaquePointer?
        var reported = Date.distantPast
        while true {
            if cancelled.isSet { throw CancellationError() }
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw failure(reader) }
            let name = archive_entry_pathname_utf8(entry).map { String(cString: $0) } ?? ""
            guard let target = Self.place(name, in: destination) else {
                skipped.append(name)
                archive_read_data_skip(reader)
                continue
            }
            if archive_entry_is_encrypted(entry) != 0 && password == nil {
                throw encrypted()
            }
            archive_entry_set_pathname_utf8(entry, target.path)
            if let link = archive_entry_hardlink_utf8(entry) {
                guard let linked = Self.place(String(cString: link), in: destination) else {
                    skipped.append(name)
                    archive_read_data_skip(reader)
                    continue
                }
                archive_entry_set_hardlink_utf8(entry, linked.path)
            }
            guard archive_write_header(writer, entry) >= ARCHIVE_WARN else { throw failure(writer) }
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while true {
                let read = archive_read_data_block(reader, &buffer, &size, &offset)
                if read == ARCHIVE_EOF { break }
                guard read >= ARCHIVE_WARN else { throw failure(reader) }
                guard archive_write_data_block(writer, buffer, size, offset) >= Int(ARCHIVE_WARN) else { throw failure(writer) }
                if cancelled.isSet { throw CancellationError() }
            }
            guard archive_write_finish_entry(writer) >= ARCHIVE_WARN else { throw failure(writer) }
            if let progress, Date().timeIntervalSince(reported) > 0.1 {
                reported = Date()
                progress(min(Double(archive_filter_bytes(reader, -1)) / total, 1))
            }
        }
        guard archive_write_close(writer) >= ARCHIVE_WARN else { throw failure(writer) }
        progress?(1)
        return skipped
    }

    /// Where an entry goes, or nil for a name that tries to climb out of the folder.
    static func place(_ name: String, in folder: URL) -> URL? {
        let parts = name.split(separator: "/").filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    private var isZip: Bool { archive.pathExtension.lowercased() == "zip" }

    private func encrypted() -> Failure {
        isZip
            ? Failure(errorDescription: "“\(archive.lastPathComponent)” is protected by a password.", needsPassword: true)
            : Failure(errorDescription: "“\(archive.lastPathComponent)” is encrypted. macOS can open password-protected zip files, but not encrypted RAR or 7z archives.", needsPassword: false)
    }

    private func failure(_ handle: OpaquePointer) -> Failure {
        let message = archive_error_string(handle).map { String(cString: $0) }
            ?? "The archive is damaged, or in a format Foldera can't read."
        if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("encrypt") {
            return isZip ? Failure(errorDescription: message, needsPassword: true) : encrypted()
        }
        return Failure(errorDescription: "“\(archive.lastPathComponent)”: \(message)", needsPassword: false)
    }
}

/// Archives opened like folders, the way Windows opens a zip: unpacked once
/// into a cache, then shown read-only. Copying and dragging out of them
/// works like any folder. The cache is emptied when Foldera starts and quits.
enum ArchiveFolders {
    static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Foldera/Archives", isDirectory: true)

    /// Cache folder → the archive it came from, for the address bar and ↑.
    private static var sources: [String: URL] = [:]

    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["gz", "bz2", "xz"].contains(ext) { return url.deletingPathExtension().pathExtension.lowercased() == "tar" }
        return ["zip", "rar", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "cab", "lzh", "lha"].contains(ext)
    }

    static func isInside(_ url: URL) -> Bool { url.key.hasPrefix(root.key + "/") }

    /// The archive a cache folder belongs to, and the folder standing for the archive itself.
    static func context(of url: URL) -> (archive: URL, root: URL)? {
        guard isInside(url) else { return nil }
        let top = url.key.dropFirst(root.key.count + 1).split(separator: "/").first.map(String.init) ?? ""
        let folder = root.appendingPathComponent(top, isDirectory: true)
        guard let archive = sources[folder.key] else { return nil }
        return (archive, folder)
    }

    /// One cache folder per archive version: path, size and date name it.
    static func folder(for archive: URL) -> URL {
        var fresh = archive
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let id = "\(archive.key)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return root.appendingPathComponent(String(format: "%016llx", hash), isDirectory: true)
    }

    /// Unpacks the archive (once) and hands back the folder to show.
    static func open(_ archive: URL, done: @escaping (URL?) -> Void) {
        let folder = folder(for: archive)
        if FileOps.exists(folder) {
            sources[folder.key] = archive
            return done(folder)
        }
        ArchiveUI.run("Opening", archive: archive, work: { unpacker, password, progress in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
            do {
                let skipped = try unpacker.unpack(into: staging, password: password, progress: progress)
                if FileOps.exists(folder) { try? FileManager.default.removeItem(at: staging) } else {
                    try FileManager.default.moveItem(at: staging, to: folder)
                }
                return (folder, skipped)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }, done: { opened in
            if opened != nil { sources[folder.key] = archive }
            done(opened)
        })
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The window side of unpacking: a progress window with Cancel, the password
/// question for protected zips, and the error when something goes wrong.
enum ArchiveUI {
    typealias Work = (_ unpacker: Unpacker, _ password: String?, _ progress: @escaping (Double) -> Void) throws -> (URL, [String])

    static func run(_ verb: String, archive: URL, password: String? = nil, work: @escaping Work, done: @escaping (URL?) -> Void) {
        let unpacker = Unpacker(archive)
        let window = ProgressWindow(title: "\(verb) “\(archive.lastPathComponent)”")
        window.update(text: archive.lastPathComponent)
        window.onCancel = { unpacker.cancel() }
        window.showSoon()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try work(unpacker, password) { fraction in
                    DispatchQueue.main.async { window.update(fraction: fraction, text: archive.lastPathComponent) }
                }
            }
            DispatchQueue.main.async {
                window.finish()
                switch result {
                case .success(let (made, skipped)):
                    if !skipped.isEmpty {
                        FileOps.report(["\(skipped.count) of the entries were left out, because their names point outside the folder they are unpacked into: "
                            + skipped.prefix(3).joined(separator: ", ")])
                    }
                    done(made)
                case .failure(let failure as Unpacker.Failure) where failure.needsPassword:
                    guard let entered = askPassword(for: archive, again: password != nil) else { return done(nil) }
                    run(verb, archive: archive, password: entered, work: work, done: done)
                case .failure(is CancellationError):
                    done(nil)
                case .failure(let error):
                    FileOps.report([error.localizedDescription])
                    done(nil)
                }
            }
        }
    }

    static func askPassword(for archive: URL, again: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = again ? "That password didn't open “\(archive.lastPathComponent)”." : "“\(archive.lastPathComponent)” is protected by a password."
        alert.informativeText = "Enter the password to unpack it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unpack")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Extract All: into a folder named after the archive, beside it (or in `parent`).
    static func extractAll(_ archive: URL, into parent: URL? = nil, done: @escaping (URL?) -> Void) {
        run("Extracting", archive: archive, work: { unpacker, password, progress in
            try Archive.extractAll(archive, into: parent, using: unpacker, password: password, progress: progress)
        }, done: done)
    }
}
