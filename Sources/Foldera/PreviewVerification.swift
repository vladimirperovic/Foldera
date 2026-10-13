import AppKit

/// An opt-in integration check in the app's real event loop, used by CI.
/// SwiftPM's async test host cannot reliably drive native full-screen transitions.
final class PreviewVerification {
    private let tab: ExplorerTab
    private let output: URL
    private var observations: [NSObjectProtocol] = []
    private var entered = false

    init(tab: ExplorerTab, output: URL) {
        self.tab = tab
        self.output = output
    }

    func run() {
        guard tab.previewWindow == nil, tab.previewPane.superview === tab.split else {
            return fail("The details pane must start docked")
        }
        tab.togglePreviewDetachment(nil)
        guard let window = tab.previewWindow?.window, window.contentView === tab.previewPane,
              !tab.split.arrangedSubviews.contains(tab.previewPane) else { return fail("Detaching failed") }
        capture(window, suffix: "-detached")
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                object: window, queue: .main) { [self] _ in
            guard window.styleMask.contains(.fullScreen), window.contentView === tab.previewPane else {
                return fail("The detached preview did not enter full screen")
            }
            entered = true
            capture(window, suffix: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.toggleFullScreen(nil) }
        })
        observations.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                object: window, queue: .main) { [self] _ in
            guard entered, !window.styleMask.contains(.fullScreen) else { return fail("Leaving full screen failed") }
            tab.togglePreviewDetachment(nil)
            guard tab.previewWindow == nil, tab.previewPane.superview === tab.split,
                  let main = tab.window else { return fail("Docking after full screen failed") }
            capture(main, suffix: "-docked")
            print("Preview verification passed: detach, enter full screen, leave full screen, dock.")
            exit(0)
        })
        // Retain the check until completion and bound a failed native transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [self] in fail("Full-screen transition timed out") }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let button = findFullScreenButton(tab.previewPane), let action = button.action,
                  button.sendAction(action, to: button.target) else { return fail("Full-screen button action failed") }
        }
    }

    private func findFullScreenButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == "preview.fullscreen" { return button }
        return view.subviews.lazy.compactMap { self.findFullScreenButton($0) }.first
    }

    private func capture(_ window: NSWindow, suffix: String) {
        guard let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return fail("No window image") }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return fail("No PNG data") }
        let file = output.deletingLastPathComponent()
            .appendingPathComponent(output.deletingPathExtension().lastPathComponent + suffix + ".png")
        do { try png.write(to: file) } catch { fail("Could not save snapshot: \(error)") }
    }

    private func fail(_ message: String) {
        fputs("Preview verification failed: \(message)\n", stderr)
        exit(1)
    }
}
