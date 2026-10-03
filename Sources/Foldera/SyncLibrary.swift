import AppKit
import Darwin

/// Named setups and run logs are shared by the app and its background scheduler.
enum SyncLibrary {
    static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Foldera/SyncLibrary", isDirectory: true)
    static let changed = Notification.Name("FolderaSyncLibraryChanged")

    struct Schedule: Codable, Equatable {
        enum Frequency: String, Codable, CaseIterable {
            case off, hourly, daily, weekly
            var title: String {
                switch self {
                case .off: return "Off"
                case .hourly: return "Every hour"
                case .daily: return "Daily"
                case .weekly: return "Weekly"
                }
            }
        }
        var frequency: Frequency = .off
        var hour = 9
        var minute = 0
        var weekday = 2 // Calendar uses Sunday = 1.
        func next(after date: Date, calendar: Calendar = .current) -> Date? {
            switch frequency {
            case .off: return nil
            case .hourly: return date.addingTimeInterval(3600)
            case .daily, .weekly:
                var match = DateComponents(hour: hour, minute: minute, second: 0)
                if frequency == .weekly { match.weekday = weekday }
                return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime,
                                         repeatedTimePolicy: .first, direction: .forward)
            }
        }
        var title: String {
            let time = String(format: "%02d:%02d", hour, minute)
            switch frequency {
            case .off: return "Schedule off"
            case .hourly: return "Every hour"
            case .daily: return "Daily at \(time)"
            case .weekly: return "\(Calendar.current.weekdaySymbols[min(max(weekday - 1, 0), 6)]) at \(time)"
            }
        }
    }

    struct Profile: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var setup: SyncWindow.Setup
        var schedule = Schedule()
        var nextRun: Date?
        var updated = Date()
        var pausedReason: String?
    }

    struct Event: Codable, Equatable {
        var path: String
        var action: String
        var error: String?
        init(_ row: Sync.Row, error: String? = nil) {
            path = row.name
            switch row.action {
            case .toRight: action = row.right == nil ? "Copy →" : "Replace →"
            case .toLeft: action = row.left == nil ? "← Copy" : "← Replace"
            case .deleteLeft: action = "Delete on left"
            case .deleteRight: action = "Delete on right"
            case .none: action = "Skipped"
            }
            self.error = error
        }
    }

    struct Record: Codable, Identifiable {
        enum Status: String, Codable { case success, failed, cancelled, needsReview }
        var id = UUID()
        var profileID: UUID?
        var profileName: String?
        var setup: SyncWindow.Setup
        var started: Date
        var finished = Date()
        var automatic = false
        var status: Status = .success
        var copied = 0
        var deleted = 0
        var conflicts = 0
        var failures: [String] = []
        var events: [Event] = []
        var summary: String {
            switch status {
            case .needsReview:
                let detail = conflicts > 0 ? " · \(conflicts) \(conflicts == 1 ? "conflict" : "conflicts")" : ""
                return "Needs review\(detail) · \(copied) copied · \(deleted) deleted"
            case .cancelled: return "Stopped · \(copied) copied · \(deleted) deleted"
            case .failed: return "\(failures.count) errors · \(copied) copied · \(deleted) deleted"
            case .success: return copied + deleted == 0 ? "Already in sync" : "\(copied) copied · \(deleted) deleted"
            }
        }
        mutating func finish(_ outcome: Sync.Job.Outcome) {
            finished = Date()
            copied = outcome.copied
            deleted = outcome.deleted
            failures += outcome.failures
            events = outcome.events
            status = outcome.cancelled ? .cancelled : !failures.isEmpty ? .failed : conflicts > 0 ? .needsReview : .success
        }
    }

    static func profiles() throws -> [Profile] {
        try locked { try readProfiles() }
    }

    private static func readProfiles() throws -> [Profile] {
        let url = folder.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url))
    }

    @discardableResult static func save(_ profile: Profile) throws -> Profile {
        var saved = profile
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.name.isEmpty else { throw OpError("Give the profile a name.") }
        guard !saved.setup.left.isEmpty, !saved.setup.right.isEmpty else { throw OpError("Choose both folders before saving a profile.") }
        saved.updated = Date()
        try editProfiles { profiles in
            guard !profiles.contains(where: { $0.id != saved.id && $0.name.caseInsensitiveCompare(saved.name) == .orderedSame }) else {
                throw OpError("Another profile already has that name.")
            }
            profiles.removeAll { $0.id == saved.id }
            profiles.append(saved)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return saved
    }

    static func remove(_ id: UUID) throws {
        try editProfiles { $0.removeAll { $0.id == id } }
    }

    static func advance(_ profile: Profile, after date: Date, pause: String? = nil) throws {
        try editProfiles { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == profile.id && $0.updated == profile.updated }) else { return }
            profiles[index].pausedReason = pause
            profiles[index].nextRun = pause == nil ? profiles[index].schedule.next(after: date) : nil
        }
    }

    private static func editProfiles(_ edit: (inout [Profile]) throws -> Void) throws {
        try locked {
            var profiles = try readProfiles()
            try edit(&profiles)
            try JSONEncoder().encode(profiles).write(to: folder.appendingPathComponent("profiles.json"), options: .atomic)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func append(_ record: Record) throws {
        let history = folder.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let name = String(format: "%.3f", record.started.timeIntervalSince1970) + "-" + record.id.uuidString + ".json"
        try JSONEncoder().encode(record).write(to: history.appendingPathComponent(name), options: .atomic)
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func records(limit: Int = 200) throws -> [Record] {
        let history = folder.appendingPathComponent("History", isDirectory: true)
        guard FileManager.default.fileExists(atPath: history.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return try files.prefix(limit).map { try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
    }

    /// A process-wide file lock also prevents a manual run racing a scheduled run.
    final class RunLock {
        private let fd: Int32
        init?() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let descriptor = Darwin.open(folder.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw OpError("The Sync run lock could not be opened.") }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let problem = errno
                Darwin.close(descriptor)
                if problem == EWOULDBLOCK { return nil }
                throw OpError("The Sync run lock could not be acquired.")
            }
            fd = descriptor
        }
        deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
    }

    private static func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = Darwin.open(folder.appendingPathComponent("profiles.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OpError("The Sync profiles could not be opened: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw OpError("The Sync profiles could not be locked.") }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }
}

enum SyncFilter: String, CaseIterable {
    case all, copies, replacements, deletions, conflicts, skipped
    var title: String {
        switch self {
        case .all: return "All changes"
        case .copies: return "Copy"
        case .replacements: return "Replace"
        case .deletions: return "Delete"
        case .conflicts: return "Conflicts"
        case .skipped: return "Skipped"
        }
    }
    func includes(_ row: Sync.Row) -> Bool {
        switch self {
        case .all: return true
        case .copies: return row.action == .toRight && (row.right == nil || row.isFolderOnly)
            || row.action == .toLeft && (row.left == nil || row.isFolderOnly)
        case .replacements: return row.action == .toRight && row.right != nil && !row.isFolderOnly
            || row.action == .toLeft && row.left != nil && !row.isFolderOnly
        case .deletions: return row.action == .deleteLeft || row.action == .deleteRight
        case .conflicts: return row.action == .none && row.conflict != nil
        case .skipped: return row.action == .none && row.conflict == nil
        }
    }
}
