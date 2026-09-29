import AppKit

/// Compress to ZIP / 7z / TAR.GZ and Extract All, as Windows 11 has them.
/// Zips are plain, without the __MACOSX folder, so they open cleanly on
/// Windows too. Extracting reads every format Unpacker does.
enum Archive {
    enum Format: String, CaseIterable {
        case zip, sevenZip = "7z", tarGz = "tar.gz"

        var title: String {
            switch self {
            case .zip: return "ZIP file"
            case .sevenZip: return "7z archive"
            case .tarGz: return "TAR.GZ archive"
            }
        }
    }

    /// The name without the archive's own extensions: "photos.tar.gz" → "photos".
    static func baseName(of archive: URL) -> String {
        var url = archive.deletingPathExtension()
        if url.pathExtension.lowercased() == "tar" { url = url.deletingPathExtension() }
        return url.lastPathComponent
    }

    /// The name a new archive gets: after the one item, or "Archive" for several.
    static func archiveURL(for urls: [URL], format: Format) -> URL {
        let parent = urls[0].deletingLastPathComponent()
        let base: String
        if urls.count == 1 {
            base = FileOps.isFolder(urls[0]) ? urls[0].lastPathComponent : urls[0].deletingPathExtension().lastPathComponent
        } else {
            base = "Archive"
        }
        return FileOps.freeURL(in: parent, base: base, ext: format.rawValue)
    }

    /// A running compression. The archive is made under a name of its own
    /// (hidden, beside where it goes) and takes its real name only once it
    /// is whole; failing or cancelled, only that one goes, never a file
    /// someone else put under the real name meanwhile.
    final class Job {
        let process = Process()
        let format: Format
        /// The name it is meant to have; it gets the next free one if that is taken by then.
        let output: URL
        let partial: URL
        private let cancelled = CancelFlag()
        private let errors = Pipe()
        static let diagnosticLimit = 64 * 1024

        fileprivate init(output: URL, format: Format) {
            self.output = output
            self.format = format
            // The suffix stays: tar picks the format from it.
            partial = output.deletingLastPathComponent()
                .appendingPathComponent(".foldera-\(UUID().uuidString.prefix(8)).\(format.rawValue)")
        }

        func cancel() {
            cancelled.set()
            if process.isRunning { process.terminate() }
        }

        /// `done` gets the archive, or nil when it failed or was cancelled.
        func run(done: @escaping (URL?, String?) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let (result, problem) = runAndWait()
                DispatchQueue.main.async { done(result, problem) }
            }
        }

        /// The same, waiting for the result on the calling thread.
        func runAndWait() -> (URL?, String?) {
            guard !cancelled.isSet else { return (nil, nil) }
            do { try FileOps.refuseInArchive([output]) } catch { return (nil, error.localizedDescription) }
            // A new archive never takes an older one's place.
            guard !FileOps.exists(partial) else { return (nil, "“\(partial.lastPathComponent)” is in the way.") }
            prepare()
            defer {
                try? errors.fileHandleForReading.close()
                try? errors.fileHandleForWriting.close()
            }
            do { try process.run() } catch { return (nil, error.localizedDescription) }
            // Close our copy of the write end so EOF arrives when the child exits.
            try? errors.fileHandleForWriting.close()
            if cancelled.isSet, process.isRunning { process.terminate() }
            // Drain while the child runs. Waiting for exit first can deadlock
            // when tar/zip fills the pipe; retaining all diagnostics can exhaust memory.
            var diagnostics = Data()
            var truncated = false
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                let remaining = max(Self.diagnosticLimit - diagnostics.count, 0)
                diagnostics.append(chunk.prefix(remaining))
                if chunk.count > remaining { truncated = true }
            }
            process.waitUntilExit()
            var message = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if truncated { message += "\n… Further diagnostics omitted." }
            return finish(message: message)
        }

        private func prepare() {
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            // Names are stored as UTF-8, whatever the language.
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"]) { $1 }
        }

        private func finish(message: String) -> (URL?, String?) {
            if cancelled.isSet {
                try? FileManager.default.removeItem(at: partial)
                return (nil, nil)
            }
            if process.terminationStatus != 0 {
                try? FileManager.default.removeItem(at: partial)
                return (nil, !message.isEmpty ? message : "The archive tool stopped with code \(process.terminationStatus).")
            }
            // Into place without ever replacing anything: a name taken since makes it "name (2)".
            let folder = output.deletingLastPathComponent()
            let base = output.lastPathComponent.dropLast(format.rawValue.count + 1)
            var target = output
            for attempt in 2...1000 {
                if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 { return (target, nil) }
                guard errno == EEXIST else { break }
                target = FileOps.freeURL(in: folder, base: String(base), ext: format.rawValue, from: attempt)
            }
            let problem = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: partial)
            return (nil, "The archive couldn't be named “\(output.lastPathComponent)”: \(problem)")
        }
    }

    /// Packs `urls` (all from one folder) next to them.
    static func compress(_ urls: [URL], as format: Format = .zip) -> Job {
        let job = Job(output: archiveURL(for: urls, format: format), format: format)
        let parent = urls[0].deletingLastPathComponent()
        // "./" keeps a name that starts with a dash from being read as an option.
        let names = urls.map { $0.lastPathComponent.hasPrefix("-") ? "./" + $0.lastPathComponent : $0.lastPathComponent }
        job.process.currentDirectoryURL = parent
        switch format {
        case .zip:
            job.process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            job.process.arguments = ["-r", "-y", "-X", "-q", job.partial.path] + names + ["-x", "*.DS_Store"]
        case .sevenZip, .tarGz:
            // bsdtar picks the format from the suffix.
            job.process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            job.process.arguments = ["-a", "-c", "-f", job.partial.path, "--exclude", ".DS_Store", "-C", parent.path] + names
        }
        return job
    }

    /// Extract All, start to finish, on the calling thread: into a folder
    /// named after the archive, beside it (or in `parent`). An archive
    /// holding a single folder does not end up as "name/name".
    static func extractAll(_ archive: URL, into parent: URL? = nil, using unpacker: Unpacker? = nil,
                           password: String? = nil, progress: ((Double) -> Void)? = nil) throws -> (URL, [String]) {
        let unpacker = unpacker ?? Unpacker(archive)
        let parent = parent ?? archive.deletingLastPathComponent()
        try FileOps.refuseInArchive([parent])
        let staging = parent.appendingPathComponent(".explorer-extract-\(UUID().uuidString)", isDirectory: true)
        do {
            let skipped = try unpacker.unpack(into: staging, password: password, progress: progress)
            let target = FileOps.freeURL(in: parent, base: baseName(of: archive), ext: "")
            return (try settle(staging, as: target), skipped)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Moves what was unpacked into place and returns where it ended up.
    static func settle(_ staging: URL, as target: URL) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        let contents = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        if contents.count == 1, FileOps.isFolder(contents[0]) {
            let single = FileOps.freeURL(in: target.deletingLastPathComponent(), base: contents[0].lastPathComponent, ext: "")
            try fm.moveItem(at: contents[0], to: single)
            return single
        }
        try fm.moveItem(at: staging, to: target)
        return target
    }
}
