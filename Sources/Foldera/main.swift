import AppKit

if CommandLine.arguments.contains("--sync-scheduler") {
    if let index = CommandLine.arguments.firstIndex(of: "--sync-library"), CommandLine.arguments.indices.contains(index + 1) {
        SyncLibrary.folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        Sync.Memory.folder = SyncLibrary.folder.appendingPathComponent("Memory")
    }
    exit(SyncScheduler.commandLine())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
