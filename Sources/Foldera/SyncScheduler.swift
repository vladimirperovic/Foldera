import AppKit
import Darwin

/// launchd invokes this same executable without creating an application or windows.
enum SyncScheduler {
    static func runDue(now: Date = Date(), cancelled: CancelFlag = CancelFlag()) throws {
        guard let lock = try SyncLibrary.RunLock() else { return } // Retry on the next tick.
        defer { withExtendedLifetime(lock) {} }
        let profiles = try SyncLibrary.profiles().filter {
            $0.schedule.frequency != .off && ($0.nextRun ?? .distantFuture) <= now
        }
        for profile in profiles {
            if cancelled.isSet { break }
            guard let current = try SyncLibrary.profiles().first(where: { $0.id == profile.id }),
                  current.updated == profile.updated, current.schedule.frequency != .off,
                  (current.nextRun ?? .distantFuture) <= now else { continue }
            var record = SyncLibrary.Record(profileID: profile.id, profileName: profile.name,
                                            setup: profile.setup, started: Date(), automatic: true)
            do {
                let (left, right) = try folders(profile.setup)
                let scan = try Sync.compare(left, right, by: profile.setup.comparison,
                                            excluding: Sync.Exclusion(profile.setup.excludes), cancelled: cancelled)
                let plan = Sync.plan(scan, mode: profile.setup.mode, towardLeft: profile.setup.towardLeft ?? false)
                record.conflicts = plan.rows.filter { $0.action == .none && $0.conflict != nil }.count
                var reasons = scan.problems + plan.worries(scan)
                if record.conflicts > 0 {
                    reasons.append(record.conflicts == 1 ? "1 conflict needs a manual decision." : "\(record.conflicts) conflicts need a manual decision.")
                }
                if profile.setup.permanently && plan.removesAnything {
                    reasons.append("Permanent replacements or deletions need manual confirmation.")
                }
                if !reasons.isEmpty {
                    record.status = .needsReview
                    record.failures = reasons
                } else {
                    if cancelled.isSet { throw CancellationError() }
                    guard let latest = try SyncLibrary.profiles().first(where: { $0.id == profile.id }),
                          latest.updated == profile.updated, latest.schedule.frequency != .off else { continue }
                    let job = Sync.Job(scan, rows: plan.rows, permanently: profile.setup.permanently)
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                    timer.setEventHandler { if cancelled.isSet { job.cancel() } }
                    timer.resume()
                    if cancelled.isSet { job.cancel() }
                    record.finish(job.perform())
                    timer.cancel()
                }
            } catch is CancellationError {
                record.status = .cancelled
                record.finished = Date()
            } catch {
                record.status = .failed
                record.failures = [error.localizedDescription]
                record.finished = Date()
            }
            record.finished = Date()
            try SyncLibrary.append(record)
            // Resume once after wake/login; missed intervals never cause a backlog.
            try SyncLibrary.advance(profile, after: max(now, Date()),
                                    pause: record.status == .needsReview ? record.failures.joined(separator: "\n") : nil)
        }
    }

    static func folders(_ setup: SyncWindow.Setup) throws -> (URL, URL) {
        guard !setup.left.isEmpty && !setup.right.isEmpty else { throw OpError("Choose both folders.") }
        let left = URL(fileURLWithPath: setup.left)
        let right = URL(fileURLWithPath: setup.right)
        for folder in [left, right] {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                throw OpError("The folder could not be opened: \(folder.path)")
            }
            guard !ArchiveFolders.isInside(folder) else { throw OpError("Extract the archive before syncing it.") }
        }
        guard !FileOps.isInside(left, right) && !FileOps.isInside(right, left) else {
            throw OpError("The folders cannot be the same, or one inside the other.")
        }
        return (left, right)
    }

    static func commandLine() -> Int32 {
        let cancelled = CancelFlag()
        // A removed/updated LaunchAgent cancels cleanly, including a partial copy.
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { cancelled.set() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do { try runDue(cancelled: cancelled); return 0 }
        catch {
            fputs("Foldera Sync scheduler: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

enum SyncAgent {
    static let label = "com.vladimirperovic.foldera.sync"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static func configuration(executable: URL, library: URL) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable.path, "--sync-scheduler"],
         "StartInterval": 60, "ProcessType": "Background",
         "AssociatedBundleIdentifiers": ["com.vladimirperovic.foldera"],
         "StandardErrorPath": library.appendingPathComponent("scheduler.log").path]
    }

    static func refresh() throws {
        guard Bundle.main.bundleIdentifier == "com.vladimirperovic.foldera",
              !CommandLine.arguments.contains("--snapshot"), let executable = Bundle.main.executableURL else {
            throw OpError("Configure schedules in the installed Foldera application.")
        }
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        let active = try SyncLibrary.profiles().contains { $0.schedule.frequency != .off }
        let loaded = launchctl(["print", service]).0 == 0
        if !active {
            if loaded {
                let result = launchctl(["bootout", service])
                guard result.0 == 0 else { throw OpError("The background schedule could not be stopped. \(result.1)") }
            }
            if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: configuration(executable: executable, library: SyncLibrary.folder),
                                                       format: .xml, options: 0)
        let previous = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        let changed = previous.map { !NSDictionary(dictionary: $0).isEqual(to: configuration(executable: executable, library: SyncLibrary.folder)) } ?? true
        if changed {
            if loaded {
                let result = launchctl(["bootout", service])
                guard result.0 == 0 else { throw OpError("The background schedule could not be updated. \(result.1)") }
            }
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        }
        if !loaded || changed {
            let result = launchctl(["bootstrap", domain, plistURL.path])
            guard result.0 == 0 else { throw OpError("The background schedule could not start. \(result.1)") }
        }
    }

    private static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do {
            try process.run()
            let error = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: error, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
}
