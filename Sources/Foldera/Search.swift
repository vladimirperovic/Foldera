import Foundation
import UniformTypeIdentifiers

/// Windows' search options: what kind, how big, when last changed. With a
/// filter set, an empty search box lists everything that passes.
struct SearchFilters: Equatable {
    enum Kind: String, CaseIterable {
        case any, folders, documents, images, audio, video, archives, apps

        var title: String {
            switch self {
            case .any: return "Any kind"
            case .folders: return "Folders"
            case .documents: return "Documents"
            case .images: return "Pictures"
            case .audio: return "Music"
            case .video: return "Videos"
            case .archives: return "Archives"
            case .apps: return "Apps"
            }
        }
    }

    enum Size: String, CaseIterable {
        case any, tiny, small, medium, large, huge

        var title: String {
            switch self {
            case .any: return "Any size"
            case .tiny: return "Tiny (< 100 KB)"
            case .small: return "Small (100 KB – 10 MB)"
            case .medium: return "Medium (10 – 100 MB)"
            case .large: return "Large (100 MB – 1 GB)"
            case .huge: return "Huge (> 1 GB)"
            }
        }

        var range: ClosedRange<Int64> {
            switch self {
            case .any: return 0...Int64.max
            case .tiny: return 0...(100 * 1024 - 1)
            case .small: return (100 * 1024)...(10 * 1024 * 1024 - 1)
            case .medium: return (10 * 1024 * 1024)...(100 * 1024 * 1024 - 1)
            case .large: return (100 * 1024 * 1024)...(1024 * 1024 * 1024 - 1)
            case .huge: return (1024 * 1024 * 1024)...Int64.max
            }
        }
    }

    enum Modified: String, CaseIterable {
        case any, today, yesterday, thisWeek, thisMonth, thisYear, older

        var title: String {
            switch self {
            case .any: return "Any date"
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "This week"
            case .thisMonth: return "This month"
            case .thisYear: return "This year"
            case .older: return "Earlier than this year"
            }
        }
    }

    var kind = Kind.any
    var size = Size.any
    var modified = Modified.any

    var isActive: Bool { kind != .any || size != .any || modified != .any }

    private static let documents: [UTType] = [
        .pdf, .text, .rtf, .rtfd, .presentation, .spreadsheet, .epub,
    ] + ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
         "org.oasis-open.opendocument.text", "com.apple.iwork.pages.sffpages"].compactMap { UTType($0) }

    static func kind(of item: FileItem) -> Kind? {
        item.isFolder ? .folders : kind(ofFile: item.url)
    }

    /// The kind a file's name says it is.
    static func kind(ofFile url: URL) -> Kind? {
        if ArchiveFolders.isArchive(url) { return .archives }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .archive) { return .archives }
        if documents.contains(where: { type.conforms(to: $0) }) { return .documents }
        return nil
    }

    func matches(_ item: FileItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if kind != .any && Self.kind(of: item) != kind { return false }
        if size != .any {
            guard let bytes = item.size, size.range.contains(bytes) else { return false }
        }
        if modified != .any {
            guard let date = item.modified else { return false }
            switch modified {
            case .any: break
            case .today: if !calendar.isDateInToday(date) { return false }
            case .yesterday: if !calendar.isDateInYesterday(date) { return false }
            case .thisWeek: if !calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return false }
            case .thisMonth: if !calendar.isDate(date, equalTo: now, toGranularity: .month) { return false }
            case .thisYear: if !calendar.isDate(date, equalTo: now, toGranularity: .year) { return false }
            case .older: if calendar.isDate(date, equalTo: now, toGranularity: .year) || date > now { return false }
            }
        }
        return true
    }
}

/// A flag a background job checks to know it should give up.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Searches by name through the folder and everything under it, as the box
/// at the top right does in Windows. Results arrive in small batches, so the
/// list fills while it looks.
final class FolderSearch {
    static let limit = 20_000
    private var current: CancelFlag?

    func cancel() {
        current?.set()
        current = nil
    }

    func start(in root: URL, for query: String, filters: SearchFilters = SearchFilters(), showHidden: Bool,
               found: @escaping ([FileItem]) -> Void,
               finished: @escaping (_ truncated: Bool, _ unreadable: Int) -> Void) {
        cancel()
        let flag = CancelFlag()
        current = flag
        let matches = Self.matcher(for: query)
        DispatchQueue.global(qos: .userInitiated).async {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            // Folders that can't be searched are counted, so no results there isn't taken for none there.
            var unreadable = 0
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: FileItem.keys, options: options,
                errorHandler: { _, _ in unreadable += 1; return true })
            var batch: [FileItem] = []
            var total = 0
            var truncated = false
            var lastSent = Date()
            while let url = walker?.nextObject() as? URL {
                if flag.isSet { return }
                // The system volume shows up again under /System/Volumes; once is enough.
                if url.path == "/System/Volumes" || url.path == "/Volumes" {
                    walker?.skipDescendants()
                    continue
                }
                if matches(url.lastPathComponent) {
                    let item = FileItem(url: url)
                    guard filters.matches(item) else { continue }
                    batch.append(item)
                    total += 1
                    if total >= Self.limit {
                        truncated = true
                        break
                    }
                }
                if !batch.isEmpty && Date().timeIntervalSince(lastSent) > 0.15 {
                    let ready = batch
                    batch = []
                    lastSent = Date()
                    DispatchQueue.main.async { if !flag.isSet { found(ready) } }
                }
            }
            let rest = batch
            let missed = unreadable
            DispatchQueue.main.async {
                guard !flag.isSet else { return }
                if !rest.isEmpty { found(rest) }
                finished(truncated, missed)
            }
        }
    }

    /// Plain words match anywhere in the name, ignoring case and accents;
    /// `*` and `?` work as wildcards (`*.pdf`).
    static func matcher(for query: String) -> (String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return { _ in true } }
        if q.contains("*") || q.contains("?") {
            let predicate = NSPredicate(format: "SELF LIKE[cd] %@", q)
            return { predicate.evaluate(with: $0) }
        }
        return { $0.localizedStandardContains(q) }
    }
}
