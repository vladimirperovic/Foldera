import Foundation

/// The tests run with no window of theirs in front, and macOS lets the
/// timers of an app in the background slip by seconds (App Nap): on CI a
/// click waiting out the double-click time, or the rest between two reads
/// of a folder, came after the test had given up. Held from the first wait
/// to the end of the run.
enum Awake {
    private static let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "Foldera's tests wait on timers")

    static func hold() { _ = activity }
}
