import Foundation
import Testing
@testable import Foldera

private final class SyncFixture {
    let root: URL
    let left: URL
    let right: URL
    private let oldLibrary = SyncLibrary.folder
    private let oldMemory = Sync.Memory.folder
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaSyncAutomation-\(UUID().uuidString)")
        left = root.appendingPathComponent("Left")
        right = root.appendingPathComponent("Right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        SyncLibrary.folder = root.appendingPathComponent("Library")
        Sync.Memory.folder = root.appendingPathComponent("Memory")
    }
    var setup: SyncWindow.Setup { .init(left: left.path, right: right.path, mode: .update) }
    func profile(name: String = "Documents backup", due: Date = .distantPast) -> SyncLibrary.Profile {
        .init(name: name, setup: setup, schedule: .init(frequency: .hourly), nextRun: due)
    }
    func file(_ side: URL, _ name: String, _ text: String = "hello") throws {
        try text.write(to: side.appendingPathComponent(name), atomically: false, encoding: .utf8)
    }
    deinit {
        SyncLibrary.folder = oldLibrary
        Sync.Memory.folder = oldMemory
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct SyncAutomation {
    @Test func twoWayConflictAfterACompletedSyncIsLoggedUntilManuallyResolved() throws {
        let p = try SyncFixture()
        try p.file(p.left, "shared.txt", "base")
        var profile = p.profile()
        profile.setup.mode = .twoWay
        profile.setup.comparison = .content
        let saved = try SyncLibrary.save(profile)
        try SyncScheduler.runDue()
        #expect(try SyncLibrary.records().first?.status == .success)

        // Both edits have the original size and timestamp: only content detects them.
        let timestamp = try #require(p.left.appendingPathComponent("shared.txt").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try p.file(p.left, "shared.txt", "left")
        try p.file(p.right, "shared.txt", "rght")
        for side in [p.left, p.right] {
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: side.appendingPathComponent("shared.txt").path)
        }
        try p.file(p.left, "independent.txt", "copy this")
        let now = Date().addingTimeInterval(7200)
        try SyncScheduler.runDue(now: now)
        let paused = try #require(SyncLibrary.profiles().first)
        #expect(paused.pausedReason != nil && paused.nextRun == nil)
        #expect(try SyncLibrary.records().first?.status == .needsReview)
        #expect(!FileManager.default.fileExists(atPath: p.right.appendingPathComponent("independent.txt").path))

        let scan = try Sync.compare(p.left, p.right, by: .content, cancelled: CancelFlag())
        var plan = Sync.plan(scan, mode: .twoWay)
        let conflict = try #require(plan.rows.firstIndex { $0.conflict != nil })
        #expect(plan.rows[conflict].name == "shared.txt" && plan.rows[conflict].choices.contains(.toRight))
        let partial = Sync.Job(scan, rows: plan.rows, permanently: true).perform()
        var partialRecord = SyncLibrary.Record(profileID: saved.id, setup: saved.setup, started: Date())
        partialRecord.conflicts = 1
        partialRecord.finish(partial)
        #expect(partialRecord.status == .needsReview && partialRecord.copied == 1)
        #expect(partialRecord.summary.contains("1 conflict") && !partialRecord.summary.contains("Already in sync"))
        try SyncLibrary.append(partialRecord)
        #expect(try String(contentsOf: p.right.appendingPathComponent("shared.txt"), encoding: .utf8) == "rght")

        plan.rows[conflict].action = .toRight
        let resolution = Sync.Job(scan, rows: [plan.rows[conflict]], permanently: true).perform()
        #expect(resolution.failures.isEmpty && resolution.copied == 1)
        #expect(try String(contentsOf: p.right.appendingPathComponent("shared.txt"), encoding: .utf8) == "left")
        try SyncLibrary.advance(paused, after: now)
        try p.file(p.right, "next-run.txt", "new on right")
        try SyncScheduler.runDue(now: now.addingTimeInterval(7200))
        #expect(try String(contentsOf: p.left.appendingPathComponent("next-run.txt"), encoding: .utf8) == "new on right")
        #expect(try SyncLibrary.records().first?.status == .success)
        #expect(try SyncLibrary.profiles().first?.pausedReason == nil)
    }

    @Test func profilesRoundTripRenameKeepSettingsAndRejectDuplicateNames() throws {
        let p = try SyncFixture()
        var profile = p.profile()
        profile.setup.towardLeft = true
        profile.setup.comparison = .content
        profile.setup.mode = .mirror
        profile.setup.permanently = true
        let saved = try SyncLibrary.save(profile)
        #expect(try SyncLibrary.profiles() == [saved])
        var renamed = saved
        renamed.name = "Photos backup"
        let again = try SyncLibrary.save(renamed)
        #expect(again.id == saved.id && again.setup == saved.setup && again.schedule == saved.schedule)
        #expect(try SyncLibrary.profiles().count == 1)
        #expect(throws: (any Error).self) { try SyncLibrary.save(p.profile(name: " PHOTOS BACKUP ")) }
        try SyncLibrary.remove(saved.id)
        #expect(try SyncLibrary.profiles().isEmpty)
    }

    @Test func dailyAndWeeklySchedulesChooseTheNextLocalTimeAndHourlyUsesAnHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Belgrade"))
        let date = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 2, hour: 10))) // Friday
        #expect(SyncLibrary.Schedule().next(after: date, calendar: calendar) == nil)
        #expect(SyncLibrary.Schedule(frequency: .hourly).next(after: date) == date.addingTimeInterval(3600))
        let daily = try #require(SyncLibrary.Schedule(frequency: .daily, hour: 9, minute: 30).next(after: date, calendar: calendar))
        #expect(calendar.component(.day, from: daily) == 3 && calendar.component(.hour, from: daily) == 9)
        #expect(calendar.component(.minute, from: daily) == 30)
        let weekly = try #require(SyncLibrary.Schedule(frequency: .weekly, hour: 9, weekday: 2).next(after: date, calendar: calendar))
        #expect(calendar.component(.day, from: weekly) == 5 && calendar.component(.weekday, from: weekly) == 2)
        let summer = try #require(calendar.date(from: .init(year: 2026, month: 10, day: 24, hour: 10)))
        let acrossDST = try #require(SyncLibrary.Schedule(frequency: .daily, hour: 9).next(after: summer, calendar: calendar))
        #expect(calendar.component(.day, from: acrossDST) == 25 && calendar.component(.hour, from: acrossDST) == 9)
    }

    @Test func scheduledUpdateRunsOnceLogsActionsAndDoesNotReplayMissedIntervals() throws {
        let p = try SyncFixture()
        try p.file(p.left, "new.txt")
        try p.file(p.right, "keep.txt", "keep")
        let saved = try SyncLibrary.save(p.profile())
        let now = Date()
        try SyncScheduler.runDue(now: now)
        #expect(try String(contentsOf: p.right.appendingPathComponent("new.txt"), encoding: .utf8) == "hello")
        #expect(FileManager.default.fileExists(atPath: p.right.appendingPathComponent("keep.txt").path))
        let records = try SyncLibrary.records()
        #expect(records.count == 1 && records[0].automatic && records[0].status == .success)
        #expect(records[0].profileID == saved.id && records[0].copied == 1)
        #expect(records[0].events.first?.path == "new.txt" && records[0].events.first?.error == nil)
        #expect(try SyncLibrary.profiles().first?.nextRun ?? .distantPast > now)
        try SyncScheduler.runDue(now: now)
        #expect(try SyncLibrary.records().count == 1)
    }

    @Test func disabledFutureOrDeletedProfilesDoNotRun() throws {
        let p = try SyncFixture()
        try p.file(p.left, "new.txt")
        var off = p.profile(name: "Off")
        off.schedule.frequency = .off
        try SyncLibrary.save(off)
        try SyncLibrary.save(p.profile(name: "Future", due: Date().addingTimeInterval(86400)))
        let deleted = try SyncLibrary.save(p.profile(name: "Deleted"))
        try SyncLibrary.remove(deleted.id)
        try SyncScheduler.runDue()
        #expect(try SyncLibrary.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: p.right.appendingPathComponent("new.txt").path))
    }

    @Test func dangerousMirrorPausesItsScheduleWithoutDeletingAndCanBeResumed() throws {
        let p = try SyncFixture()
        try p.file(p.right, "must-stay.txt")
        var profile = p.profile()
        profile.setup.mode = .mirror
        let saved = try SyncLibrary.save(profile)
        try SyncScheduler.runDue()
        #expect(FileManager.default.fileExists(atPath: p.right.appendingPathComponent("must-stay.txt").path))
        let record = try #require(SyncLibrary.records().first)
        #expect(record.status == .needsReview && !record.failures.isEmpty && record.deleted == 0)
        let paused = try #require(SyncLibrary.profiles().first)
        #expect(paused.pausedReason != nil && paused.nextRun == nil)
        try SyncScheduler.runDue()
        #expect(try SyncLibrary.records().count == 1)
        try SyncLibrary.advance(saved, after: Date())
        #expect(try SyncLibrary.profiles().first?.pausedReason == nil)
        #expect(try SyncLibrary.profiles().first?.nextRun != nil)
    }

    @Test func permanentReplacementRequiresReviewBeforeTheScheduledRun() throws {
        let p = try SyncFixture()
        try p.file(p.left, "replace.txt", "new source")
        try p.file(p.right, "replace.txt", "old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: p.right.appendingPathComponent("replace.txt").path)
        var profile = p.profile()
        profile.setup.permanently = true
        try SyncLibrary.save(profile)
        try SyncScheduler.runDue()
        let record = try #require(SyncLibrary.records().first)
        #expect(record.status == .needsReview && record.copied == 0 && record.events.isEmpty)
        #expect(try String(contentsOf: p.right.appendingPathComponent("replace.txt"), encoding: .utf8) == "old")
        #expect(try SyncLibrary.profiles().first?.pausedReason != nil)
    }

    @Test func conflictsWaitForReviewInsteadOfBeingResolvedAutomatically() throws {
        let p = try SyncFixture()
        try p.file(p.left, "same-date.txt", "left")
        try p.file(p.right, "same-date.txt", "different right")
        var profile = p.profile()
        profile.setup.mode = .twoWay
        try SyncLibrary.save(profile)
        try SyncScheduler.runDue()
        let record = try #require(SyncLibrary.records().first)
        #expect(record.status == .needsReview && record.conflicts == 1)
        #expect(try String(contentsOf: p.left.appendingPathComponent("same-date.txt"), encoding: .utf8) == "left")
        #expect(try String(contentsOf: p.right.appendingPathComponent("same-date.txt"), encoding: .utf8) == "different right")
    }

    @Test func missingFolderIsLoggedAsAFailureAndNeverCreatedAsAnEmptySource() throws {
        let p = try SyncFixture()
        try p.file(p.right, "keep.txt")
        var profile = p.profile()
        profile.setup.left = p.root.appendingPathComponent("Missing drive").path
        profile.setup.mode = .mirror
        try SyncLibrary.save(profile)
        try SyncScheduler.runDue()
        let record = try #require(SyncLibrary.records().first)
        #expect(record.status == .failed && record.deleted == 0 && !record.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: profile.setup.left))
        #expect(FileManager.default.fileExists(atPath: p.right.appendingPathComponent("keep.txt").path))
    }

    @Test func profileEditsAreNotOverwrittenByTheCompletionOfAnOlderRun() throws {
        let p = try SyncFixture()
        let old = try SyncLibrary.save(p.profile())
        var edited = old
        edited.setup.towardLeft = true
        let updated = try SyncLibrary.save(edited)
        try SyncLibrary.advance(old, after: Date(), pause: "Old run needed review")
        #expect(try SyncLibrary.profiles() == [updated])
    }

    @Test func processLockPreventsAHeadlessRunnerRacingAManualRun() throws {
        let p = try SyncFixture()
        try p.file(p.left, "new.txt")
        try SyncLibrary.save(p.profile())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("Foldera") }
            + [package.appendingPathComponent(".build/native-pane-tests/debug/Foldera"), package.appendingPathComponent(".build/debug/Foldera")]
        let binary = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        func run() throws {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--sync-scheduler", "--sync-library", SyncLibrary.folder.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        var lock = try SyncLibrary.RunLock()
        #expect(lock != nil)
        #expect(try SyncLibrary.RunLock() == nil)
        try run()
        #expect(try SyncLibrary.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: p.right.appendingPathComponent("new.txt").path))
        lock = nil
        try run()
        #expect(FileManager.default.fileExists(atPath: p.right.appendingPathComponent("new.txt").path))
        #expect(try SyncLibrary.records().first?.automatic == true)
    }

    @Test func launchAgentUsesTheInstalledExecutableAndAHeadlessMinuteTick() throws {
        let executable = URL(fileURLWithPath: "/Applications/Foldera.app/Contents/MacOS/Foldera")
        let configuration = SyncAgent.configuration(executable: executable, library: URL(fileURLWithPath: "/tmp/Sync Library"))
        #expect(configuration["ProgramArguments"] as? [String] == [executable.path, "--sync-scheduler"])
        #expect(configuration["StartInterval"] as? Int == 60)
        #expect(configuration["ProcessType"] as? String == "Background")
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        #expect(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) is [String: Any])
    }

    @Test func historyRetainsFailuresFromFilesChangedAfterComparison() throws {
        let p = try SyncFixture()
        try p.file(p.left, "changed.txt")
        let scan = try Sync.compare(p.left, p.right, by: .dateAndSize, cancelled: CancelFlag())
        let plan = Sync.plan(scan, mode: .update)
        try p.file(p.left, "changed.txt", "changed after compare")
        let outcome = Sync.Job(scan, rows: plan.rows, permanently: false).perform()
        #expect(!outcome.failures.isEmpty && outcome.events.first?.error != nil)
        var record = SyncLibrary.Record(setup: p.setup, started: Date())
        record.finish(outcome)
        try SyncLibrary.append(record)
        #expect(try SyncLibrary.records().first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: p.right.appendingPathComponent("changed.txt").path))
    }
}
