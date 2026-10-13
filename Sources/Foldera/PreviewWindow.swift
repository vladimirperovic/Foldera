import AppKit

/// Hosts the tab's actual details view, so detaching doesn't reload a page,
/// lose its scroll position, or save a Markdown draft as a side effect.
final class PreviewWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(pane: PreviewPane) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 300)
        window.title = "Details"
        super.init(window: window)
        window.delegate = self
        window.contentView = pane
        window.center()
        window.setFrameAutosaveName("DetachedDetails")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// File > Close Tab uses this selector for Command-W throughout Foldera.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }

    func show(_ selection: [FileItem], in location: Location) {
        let name = selection.count == 1 ? selection[0].name : location.title
        window?.title = "\(name) — Details"
        window?.representedURL = selection.count == 1 ? selection[0].url : location.url
    }

    func windowWillClose(_ notification: Notification) {
        // Release the content before the owner puts it back in its split view.
        window?.contentView = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
