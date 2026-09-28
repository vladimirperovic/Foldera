import AppKit

/// The menu bar. Windows habits get Mac keys: Ctrl becomes ⌘, and the
/// function keys (F2, F5…) work too — see ExplorerTab.handleKey.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            return item
        }

        func key(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        let sep = { NSMenuItem.separator() }
        typealias W = ExplorerTab

        _ = menu("Foldera", [
            item("About Foldera", #selector(AppDelegate.showAbout(_:))),
            sep(),
            item("Open Folders in Foldera…", #selector(AppDelegate.makeDefault(_:))),
            item("Open Folders in Finder Again", #selector(AppDelegate.restoreFinder(_:))),
            sep(),
            item("Hide Foldera", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Foldera", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = menu("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Tab", #selector(ExplorerWindow.newTab(_:)), "t"),
            item("New Folder", #selector(W.newFolder(_:)), "n", [.command, .shift]),
            item("New Text Document", #selector(W.newTextDocument(_:))),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            sep(),
            item("Open", #selector(W.openSelection(_:)), key(NSDownArrowFunctionKey)),
            item("Open in New Tab", #selector(W.openInNewTab(_:)), "\r"),
            item("Open in New Window", #selector(W.openInNewWindow(_:))),
            item("Quick Look", #selector(W.quickLook(_:)), "y"),
            item("Edit Markdown", #selector(W.editMarkdown(_:))),
            sep(),
            item("Compress to ZIP", #selector(W.compress(_:))),
            item("Extract All", #selector(W.extract(_:))),
            item("Extract To…", #selector(W.extractTo(_:))),
            item("AirDrop…", #selector(W.airDrop(_:))),
            sep(),
            item("Rename", #selector(W.renameSelection(_:)), key(NSF2FunctionKey), []),
            item("Properties", #selector(W.showProperties(_:)), "i"),
            sep(),
            item("Move to Trash", #selector(W.delete(_:)), "\u{8}"),
            item("Delete Permanently…", #selector(W.deletePermanently(_:)), "\u{8}", [.command, .option]),
            sep(),
            item("Close Tab", #selector(ExplorerWindow.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])

        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Move Item Here", #selector(W.pasteMove(_:)), "v", [.command, .option]),
            item("Copy as Path", #selector(W.copyPath(_:)), "c", [.command, .shift]),
            sep(),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Select None", #selector(W.selectNone(_:))),
            item("Invert Selection", #selector(W.invertSelection(_:))),
            sep(),
            item("Search", #selector(W.focusSearch(_:)), "f"),
            item("Search Options", #selector(W.toggleFilters(_:)), "f", [.command, .option]),
        ])

        menu("View", [
            item("Details", #selector(W.setDetailsView(_:)), "1"),
            item("Large Icons", #selector(W.setIconsView(_:)), "2"),
            item("Columns", #selector(W.setColumnsView(_:)), "3"),
            item("Disk Usage", #selector(W.setUsageView(_:)), "4"),
            item("Bigger Icons", #selector(W.biggerIcons(_:)), "="),
            item("Smaller Icons", #selector(W.smallerIcons(_:)), "-"),
            item("Folder Sizes", #selector(W.toggleFolderSizes(_:))),
            item("Details Pane", #selector(W.togglePreviewPane(_:)), "p", [.command, .shift]),
            sep(),
            item("Sort by Name", #selector(W.sortBy(_:))),
            item("Sort by Date Modified", #selector(W.sortBy(_:))),
            item("Sort by Type", #selector(W.sortBy(_:))),
            item("Sort by Size", #selector(W.sortBy(_:))),
            item("Ascending", #selector(W.sortAscending(_:))),
            item("Descending", #selector(W.sortDescending(_:))),
            sep(),
            item("Show Hidden Items", #selector(W.toggleHidden(_:)), ".", [.command, .shift]),
            item("Open Pictures in Foldera's Viewer", #selector(AppDelegate.toggleImageViewer(_:))),
            item("Open Archives Like Folders", #selector(AppDelegate.toggleBrowseArchives(_:))),
            sep(),
            item("Refresh", #selector(W.refresh(_:)), "r"),
        ]).items.filter { $0.action == #selector(W.sortBy(_:)) }.enumerated().forEach { index, item in
            item.representedObject = [SortKey.name, .modified, .kind, .size][index].rawValue
        }

        _ = menu("Go", [
            item("Back", #selector(W.goBack(_:)), "["),
            item("Forward", #selector(W.goForward(_:)), "]"),
            item("Enclosing Folder", #selector(W.goUp(_:)), key(NSUpArrowFunctionKey)),
            sep(),
            item("Home", #selector(W.goToPlace(_:)), "h", [.command, .shift], tag: 0),
            item("Desktop", #selector(W.goToPlace(_:)), "d", [.command, .shift], tag: 1),
            item("Documents", #selector(W.goToPlace(_:)), "o", [.command, .shift], tag: 2),
            item("Downloads", #selector(W.goToPlace(_:)), "l", [.command, .option], tag: 3),
            item("Applications", #selector(W.goToPlace(_:)), "a", [.command, .shift], tag: 4),
            item("This Mac", #selector(W.goToPlace(_:)), "m", [.command, .shift], tag: 5),
            sep(),
            item("Go to Folder…", #selector(W.focusAddress(_:)), "g", [.command, .shift]),
            item("Connect to Server…", #selector(AppDelegate.connectToServer(_:)), "k"),
            item("Address Bar", #selector(W.focusAddress(_:)), "l"),
        ])

        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("Show Next Tab", #selector(ExplorerWindow.selectNextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(ExplorerWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            sep(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}
