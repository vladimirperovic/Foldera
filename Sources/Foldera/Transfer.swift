import AppKit
import Darwin

/// Copies and moves the way Windows does: name clashes are asked about
/// first (Replace, Keep both, Skip, and Merge for folders), then the work
/// runs in the background with a progress window that can be cancelled.
final class Transfer {
    enum Clash { case replace, keepBoth, skip, stop, merge }

    struct Step {
        let from: URL
        let to: URL
        /// Whatever is at `to` goes to the Trash first.
        let replace: Bool
    }

    struct Plan {
        var steps: [Step] = []
        /// Source folders merged into existing ones: removed after a move if nothing was left in them.
        var emptied: [URL] = []
        var problems: [String] = []
    }

    struct Progress {
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var itemsDone = 0
        var itemsTotal = 0
        var current = ""
        var preparing = true
        /// Another app is still handing `current` over (see `TreeCopier.whileReading`).
        var waiting = false

        var fraction: Double? {
            if preparing || waiting { return nil }
            if bytesTotal > 0 { return min(Double(bytesDone) / Double(bytesTotal), 1) }
            return itemsTotal > 0 ? Double(itemsDone) / Double(itemsTotal) : nil
        }
    }

    struct Outcome {
        var made: [URL] = []
        var changes: [Change] = []
        var failures: [String] = []
        var cancelled = false
    }

    /// What to do about a name that is taken. `folders`: both sides are
    /// folders, so merging is possible. `many`: more questions may follow.
    typealias Asker = (_ name: String, _ folders: Bool, _ many: Bool) -> (Clash, remember: Bool)

    // MARK: Planning (main thread: it may ask questions)

    static func plan(_ sources: [URL], into folder: URL, move: Bool, ask: Asker) -> Plan? {
        var plan = Plan()
        var fileAnswer: Clash?
        var folderAnswer: Clash?
        let many = sources.count > 1
        // Where earlier steps of this plan will put things. Two sources with
        // one name (from different folders, or search results) must not be
        // given the same place.
        var planned = Set<String>()
        func add(_ step: Step) {
            plan.steps.append(step)
            planned.insert(step.to.key)
        }

        func visit(_ source: URL, into folder: URL, topLevel: Bool) -> Bool {
            if topLevel && source.deletingLastPathComponent().key == folder.key {
                // Already here: moving does nothing, copying makes "name - Copy".
                if !move { add(Step(from: source, to: FileOps.copyName(for: source, in: folder, taken: planned), replace: false)) }
                return true
            }
            if FileOps.isFolder(source) && FileOps.isInside(folder, source) {
                plan.problems.append("The destination folder “\(folder.lastPathComponent)” is inside “\(source.lastPathComponent)”.")
                return true
            }
            let target = folder.appendingPathComponent(source.lastPathComponent)
            if planned.contains(target.key) {
                // Another source of this very plan goes there: both are kept, without asking.
                add(Step(from: source, to: FileOps.keepBothName(for: source, in: folder, taken: planned), replace: false))
                return true
            }
            guard FileOps.exists(target) else {
                add(Step(from: source, to: target, replace: false))
                return true
            }
            let folders = FileOps.isFolder(source) && FileOps.isFolder(target)
            let choice: Clash
            if let remembered = folders ? folderAnswer : fileAnswer {
                choice = remembered
            } else {
                let answer = ask(source.lastPathComponent, folders, many || !topLevel)
                choice = answer.0
                if answer.remember {
                    if folders { folderAnswer = choice } else { fileAnswer = choice }
                }
            }
            switch choice {
            case .stop:
                return false
            case .skip:
                return true
            case .replace:
                add(Step(from: source, to: target, replace: true))
            case .keepBoth:
                add(Step(from: source, to: FileOps.keepBothName(for: source, in: folder, taken: planned), replace: false))
            case .merge:
                guard folders else {
                    add(Step(from: source, to: target, replace: true))
                    return true
                }
                let children: [URL]
                do {
                    children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                } catch {
                    plan.problems.append("“\(source.lastPathComponent)”: \(error.localizedDescription)")
                    return true
                }
                for child in children where child.lastPathComponent != ".DS_Store" {
                    if !visit(child, into: target, topLevel: false) { return false }
                }
                if move { plan.emptied.append(source) }
            }
            return true
        }

        for source in sources {
            if !visit(source, into: folder, topLevel: true) { return nil }
        }
        return plan
    }

    /// The Windows questions, as alerts.
    static func askWithAlert(_ name: String, folders: Bool, many: Bool) -> (Clash, remember: Bool) {
        let alert = NSAlert()
        if folders {
            alert.messageText = "The destination already has a folder named “\(name)”."
            alert.informativeText = "Merge puts the contents of both into one folder. If files inside have the same names, you'll be asked about each of them."
            alert.addButton(withTitle: "Merge")
        } else {
            alert.messageText = "The destination already has an item named “\(name)”."
            alert.informativeText = "Replacing moves the existing one to the Trash."
            alert.addButton(withTitle: "Replace")
        }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        if many {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = folders ? "Do this for all folders" : "Do this for all remaining items"
        }
        let choice: Clash
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = folders ? .merge : .replace
        case .alertSecondButtonReturn: choice = .keepBoth
        case .alertThirdButtonReturn: choice = .skip
        default: return (.stop, false)
        }
        return (choice, alert.suppressionButton?.state == .on)
    }

    // MARK: Doing it (background)

    let plan: Plan
    let move: Bool
    private let cancelled = CancelFlag()
    /// Set once the counting below isn't wanted any more: cancelled, or all done.
    private let countingDone = CancelFlag()
    private let totals = Totals()
    private let copier: TreeCopier
    // Touched only from the worker thread (copyfile calls back on it).
    private var progress = Progress()
    private var stepBase: Int64 = 0
    private var lastPublished = Date.distantPast
    private var report: ((Progress) -> Void)?

    init(plan: Plan, move: Bool) {
        self.plan = plan
        self.move = move
        copier = TreeCopier(cancelled: cancelled)
        copier.copied = { [unowned self] bytes in
            self.progress.bytesDone = self.stepBase + bytes
            self.publish(force: false)
        }
        copier.waiting = { [unowned self] waiting in
            self.progress.waiting = waiting
            self.publish(force: true)
        }
    }

    func cancel() {
        cancelled.set()
        countingDone.set()
    }

    /// The size of each step, counted on another thread while the copying
    /// already runs: a folder of a hundred thousand small files takes a while
    /// to count, and the copy needn't wait for that.
    private final class Totals {
        private let lock = NSLock()
        private var sizes: [Int64]?

        var counted: [Int64]? {
            lock.lock()
            defer { lock.unlock() }
            return sizes
        }

        func set(_ value: [Int64]) {
            lock.lock()
            sizes = value
            lock.unlock()
        }
    }

    func run(progress report: @escaping (Progress) -> Void, done: @escaping (Outcome) -> Void) {
        self.report = report
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = self.perform()
            DispatchQueue.main.async { done(outcome) }
        }
    }

    private func sameVolume(_ step: Step) -> Bool {
        DragOps.sameVolume(step.from, step.to.deletingLastPathComponent())
    }

    /// Does the whole transfer on the calling thread (`run` calls it in the background).
    func perform() -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        do {
            try FileOps.refuseInArchive(plan.steps.map(\.to) + plan.emptied)
            if move { try FileOps.refuseInArchive(plan.steps.map(\.from)) }
        } catch {
            outcome.failures = [error.localizedDescription]
            return outcome
        }

        // How much there is to copy, counted beside the copying (see `Totals`);
        // the bar moves once that is known. A move on one drive is a rename:
        // nothing to count.
        let steps = plan.steps
        let counts = steps.map { !(move && sameVolume($0)) }
        let (totals, stop) = (self.totals, countingDone)
        DispatchQueue.global(qos: .utility).async {
            let sizes = zip(steps, counts).map { step, wanted -> Int64 in
                wanted && !stop.isSet ? Self.size(of: step.from, cancelled: stop) : 0
            }
            if !stop.isSet { totals.set(sizes) }
        }
        defer { countingDone.set() }
        progress.itemsTotal = plan.steps.count
        publish(force: true)
        /// Bytes in the steps before each one, once counted.
        var before: [Int64]?
        func counted(upTo index: Int) -> Int64? {
            if before == nil, let sizes = totals.counted { before = sizes.reduce(into: [Int64(0)]) { $0.append($0[$0.count - 1] + $1) } }
            return before?[index]
        }

        for (index, step) in plan.steps.enumerated() {
            if cancelled.isSet { outcome.cancelled = true; break }
            progress.itemsDone = index
            progress.current = step.from.lastPathComponent
            stepBase = counted(upTo: index) ?? progress.bytesDone
            progress.bytesDone = stepBase
            publish(force: true)
            do {
                if step.replace && FileOps.exists(step.to) {
                    var trashed: NSURL?
                    try fm.trashItem(at: step.to, resultingItemURL: &trashed)
                    if let trashed { outcome.changes.append(.moved(from: step.to, to: trashed as URL)) }
                }
                if move && sameVolume(step) {
                    // A placeholder renamed is still a placeholder: its app fills it in first.
                    try copier.whileReading(step.from) { try fm.moveItem(at: $0, to: step.to) }
                    outcome.changes.append(.moved(from: step.from, to: step.to))
                } else {
                    try copier.copy(step.from, to: step.to)
                    outcome.failures += copier.errors
                    if move {
                        // The original goes only once every byte arrived.
                        if copier.errors.isEmpty {
                            try fm.removeItem(at: step.from)
                            outcome.changes.append(.moved(from: step.from, to: step.to))
                        } else {
                            outcome.changes.append(.created(step.to))
                            outcome.failures.append("“\(step.from.lastPathComponent)” was copied but not removed, because part of it couldn't be copied.")
                        }
                    } else {
                        outcome.changes.append(.created(step.to))
                    }
                }
                outcome.made.append(step.to)
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failures.append("“\(step.from.lastPathComponent)”: \(error.localizedDescription)")
            }
            if let done = counted(upTo: index + 1) { progress.bytesDone = done }
        }

        if move && !outcome.cancelled {
            // Deepest first (the plan lists a folder after the ones inside it),
            // so a parent is looked at once its emptied children are gone.
            // Undo puts each one back, even if no file inside would bring it.
            for folder in plan.emptied where Self.isEffectivelyEmpty(folder) {
                // rmdir refuses if another app added a file since the check.
                let metadata = folder.appendingPathComponent(".DS_Store")
                if FileOps.exists(metadata) { _ = unlink(metadata.path) }
                if rmdir(folder.path) == 0 { outcome.changes.append(.removedFolder(folder)) }
            }
        }
        progress.itemsDone = plan.steps.count
        publish(force: true)
        return outcome
    }

    private func publish(force: Bool) {
        if progress.preparing, let sizes = totals.counted {
            progress.bytesTotal = sizes.reduce(0, +)
            progress.preparing = false
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) > 0.1 else { return }
        lastPublished = now
        let snapshot = progress
        let report = report
        DispatchQueue.main.async { report?(snapshot) }
    }

    /// Adds up a file or folder; stops early (with a partial sum) once Cancel is pressed.
    static func size(of url: URL, cancelled: CancelFlag? = nil) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true && values?.isSymbolicLink != true else { return Int64(values?.fileSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let child = walker?.nextObject() as? URL {
            if cancelled?.isSet == true { break }
            total += Int64((try? child.resourceValues(forKeys: keys))?.fileSize ?? 0)
        }
        return total
    }

    /// Empty but for Finder's .DS_Store.
    static func isEffectivelyEmpty(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
        return names.allSatisfy { $0 == ".DS_Store" }
    }
}

/// copyfile for one item with its whole folder tree: data, permissions,
/// dates, extended attributes. On APFS a copy is a clone and takes no space.
/// Copying and Sync both use it; it reports as the bytes arrive.
final class TreeCopier {
    /// Bytes of the current item that have arrived so far (on the copying thread).
    var copied: ((Int64) -> Void)?
    /// Names inside a folder being copied that are left out.
    var skips: ((String) -> Bool)?
    /// Parts of the last item that couldn't be copied and were skipped.
    private(set) var errors: [String] = []
    /// Told (on the copying thread) when another app is taking a moment to
    /// hand an item over, and again once it has.
    var waiting: ((Bool) -> Void)?
    /// How long an app gets to start handing over a placeholder it has just made.
    var patience: TimeInterval = 10
    private let cancelled: CancelFlag
    private let coordinator = NSFileCoordinator()
    // Touched only from the copying thread (copyfile calls back on it).
    private var finished: Int64 = 0
    private var fileCopied: Int64 = 0

    init(cancelled: CancelFlag) {
        self.cancelled = cancelled
    }

    /// Nothing half-copied is left behind when it fails or is cancelled.
    func copy(_ from: URL, to: URL) throws {
        errors = []
        guard !FileOps.exists(to) else {
            throw OpError("There is already an item named “\(to.lastPathComponent)”.")
        }
        try whileReading(from) { try copyNow($0, to: to) }
    }

    /// Runs `body` on this thread as a coordinated reader of `url`, the way
    /// Finder copies: an app presenting the item (not what is inside a
    /// folder) gets to save it first. Windows App puts a file copied in a
    /// remote session on the clipboard as an empty placeholder of the right
    /// size and fetches its contents only for such a reader; read plainly,
    /// every byte is zero.
    func whileReading(_ url: URL, _ body: (URL) throws -> Void) throws {
        // `say` may be called from the thread watching the wait; `lock` keeps it apart from this one.
        let lock = NSLock()
        var said = false
        func say() {
            guard !said else { return }
            said = true
            waiting?(true)
        }
        defer {
            lock.lock()
            if said { waiting?(false) }
            lock.unlock()
        }
        let started = Date()
        // A fresh placeholder nobody filled in (its app busy, or gone with the
        // session) is asked for again for a while, and is never copied as zeros.
        while try !coordinated(url, lock: lock, waiting: say, { url -> Bool in
            guard Self.isPlaceholder(url.path, bornWithin: 60) else {
                try body(url)
                return true
            }
            guard Date().timeIntervalSince(started) < patience else {
                throw OpError("It is still empty: the app it comes from didn't hand it over. Try again.")
            }
            return false
        }) {
            lock.lock()
            say()
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.25)
            if cancelled.isSet { throw CancellationError() }
        }
    }

    /// One coordinated read, with `body` run on this thread while the item is
    /// handed over. Meanwhile another thread watches: when the app takes a
    /// while, it says so, and lets Cancel end the wait.
    private func coordinated<T>(_ url: URL, lock: NSLock, waiting say: @escaping () -> Void,
                                _ body: (URL) throws -> T) throws -> T {
        var granted = false
        DispatchQueue.global(qos: .userInitiated).async { [cancelled, coordinator] in
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                defer { lock.unlock() }
                if granted { return }
                if cancelled.isSet { coordinator.cancel() }
                say()
            }
        }
        func stopWatching() {
            lock.lock()
            granted = true
            lock.unlock()
        }
        var refused: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &refused) { url in
            stopWatching()
            result = Result { try body(url) }
        }
        stopWatching()
        if let result { return try result.get() }
        if cancelled.isSet { throw CancellationError() }
        throw refused ?? CocoaError(.fileReadUnknown)
    }

    /// A size but nothing on disk: how an app that fills a file in on demand
    /// leaves it until asked. `bornWithin`: made at most that many seconds ago.
    static func isPlaceholder(_ path: String, bornWithin age: Int? = nil) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_blocks == 0 else { return false }
        return age.map { time(nil) - info.st_birthtimespec.tv_sec <= $0 } ?? true
    }

    private func copyNow(_ from: URL, to: URL) throws {
        finished = 0
        fileCopied = 0
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = copierStatus
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE)
        let result = copyfile(from.path, to.path, state, flags)
        let code = errno
        if cancelled.isSet {
            try? FileManager.default.removeItem(at: to)
            throw CancellationError()
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: to)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    fileprivate func status(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?) -> Int32 {
        if cancelled.isSet { return COPYFILE_QUIT }
        if stage == COPYFILE_START, what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR,
           let skips, let source, skips((String(cString: source) as NSString).lastPathComponent) {
            return COPYFILE_SKIP
        }
        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            fileCopied = 0
            // Reading a folder doesn't ask the apps presenting what is inside
            // it, so a file that looks like a placeholder is asked for itself.
            // Asking for every file would cost a round trip each.
            if let source, case let path = String(cString: source), Self.isPlaceholder(path) {
                do {
                    try whileReading(URL(fileURLWithPath: path)) { _ in }
                } catch is CancellationError {
                    return COPYFILE_QUIT
                } catch {
                    errors.append("“\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
                    return COPYFILE_SKIP
                }
            }
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            var info = stat()
            if let source, lstat(source, &info) == 0 { finished += Int64(info.st_size) }
            fileCopied = 0
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var bytes: off_t = 0
            if let state { copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) }
            fileCopied = Int64(bytes)
        case (_, COPYFILE_ERR), (COPYFILE_RECURSE_ERROR, _):
            let name = source.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "an item"
            errors.append("“\(name)”: \(String(cString: strerror(errno)))")
            return COPYFILE_SKIP
        default:
            break
        }
        copied?(finished + fileCopied)
        return COPYFILE_CONTINUE
    }
}

/// copyfile's C callback; the context is the TreeCopier doing the copying.
private func copierStatus(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                          destination: UnsafePointer<CChar>?, context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return COPYFILE_CONTINUE }
    return Unmanaged<TreeCopier>.fromOpaque(context).takeUnretainedValue()
        .status(what: what, stage: stage, state: state, source: source)
}

/// The small window Windows shows while copying: what, how far, and a way to stop.
final class ProgressWindow: NSWindowController {
    var onCancel: (() -> Void)?
    private let heading = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let detail = NSTextField(labelWithString: "")
    private var finished = false
    private static var open: [ProgressWindow] = []

    init(title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = title.components(separatedBy: " ").first ?? title
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        heading.stringValue = title
        heading.font = .boldSystemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.stringValue = "Preparing…"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [heading, bar, detail, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.setCustomSpacing(12, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
                detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
                cancel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown only if the work is still going after a moment; quick ones never flash a window.
    func showSoon() {
        Self.open.append(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.finished else { return }
            self.window?.center()
            self.showWindow(nil)
        }
    }

    func update(_ progress: Transfer.Progress) {
        if progress.waiting {
            // Nothing arrives to be counted until the other app hands it over.
            if !bar.isIndeterminate {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            }
            detail.stringValue = "Waiting for “\(progress.current)” to arrive…"
            return
        }
        guard let fraction = progress.fraction else {
            // The copying has begun while what there is to copy is still being counted.
            if !progress.preparing || progress.current.isEmpty { return }
            detail.stringValue = "\(min(progress.itemsDone + 1, progress.itemsTotal)) of \(progress.itemsTotal)  ·  \(progress.current)"
            return
        }
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        bar.doubleValue = fraction
        var parts = ["\(Int(fraction * 100))%"]
        if progress.bytesTotal > 0 { parts.append("\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))") }
        parts.append("\(min(progress.itemsDone + 1, progress.itemsTotal)) of \(progress.itemsTotal)")
        if !progress.current.isEmpty { parts.append(progress.current) }
        detail.stringValue = parts.joined(separator: "  ·  ")
    }

    /// For work without a measurable size (zipping): just a moving bar and a line of text.
    func update(text: String) {
        detail.stringValue = text
    }

    /// For unpacking: how far through the archive, and its name.
    func update(fraction: Double, text: String) {
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        bar.doubleValue = fraction
        detail.stringValue = "\(Int(fraction * 100))%  ·  \(text)"
    }

    func finish() {
        finished = true
        close()
        Self.open.removeAll { $0 === self }
    }

    /// Work on files still going (copying, syncing, packing, unpacking), for Quit.
    static var anyRunning: Bool { !open.isEmpty }

    /// Quit: stops all of it. Each job cleans up after itself and then finishes.
    static func cancelAll() {
        open.forEach { $0.cancelPressed(nil) }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        detail.stringValue = "Cancelling…"
        onCancel?()
    }
}
