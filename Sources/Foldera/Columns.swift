import AppKit

/// One entry in the column view; folders load what is inside them when first opened.
final class ColumnNode {
    let url: URL
    let item: FileItem?
    /// Stands in for the contents of a folder that couldn't be read, so it doesn't pass for empty.
    let problem: String?
    var children: [ColumnNode]?
    /// Being read in the background (see `Columns.children(of:)`), and what waits for that.
    var loading = false
    var whenLoaded: [() -> Void] = []
    /// Stands in for the contents while they are read.
    lazy var loadingRow = ColumnNode(url: url, item: nil, problem: "Loading…")

    init(url: URL, item: FileItem?, problem: String? = nil) {
        self.url = url
        self.item = item
        self.problem = problem
    }

    var isLeaf: Bool { problem != nil || item.map { !$0.isFolder } ?? false }

    /// A folder that can't be read shows why, until F5 reads it again.
    func loadChildren(sort: SortSpec) -> [ColumnNode] {
        if let children { return children }
        let made = Self.read(url, item: item, sort: sort, showHidden: Prefs.showHidden)
        children = made
        return made
    }

    /// What is inside, in order, or why it couldn't be read. On any thread.
    static func read(_ url: URL, item: FileItem?, sort: SortSpec, showHidden: Bool) -> [ColumnNode] {
        let target = item?.isSymlink == true ? url.resolvingSymlinksInPath() : url
        do {
            return try FileItem.contents(of: target, showHidden: showHidden).sorted(by: sort).map { ColumnNode(url: $0.url, item: $0) }
        } catch {
            return [ColumnNode(url: url, item: nil, problem: "Couldn't be read: \(error.localizedDescription)")]
        }
    }
}

final class FileBrowser: NSBrowser {
    weak var host: ExplorerTab?

    /// Right-click selects what is under the pointer first, as everywhere else.
    override func menu(for event: NSEvent) -> NSMenu? {
        var row = -1
        var column = -1
        if getRow(&row, column: &column, for: convert(event.locationInWindow, from: nil)), row >= 0, column >= 0,
           selectedRowIndexes(inColumn: column)?.contains(row) != true {
            selectRow(row, inColumn: column)
        }
        host?.selectionChanged()
        return host?.contextMenu()
    }
}

/// The column view (⌘3), as in Finder: each folder you pick opens in a new
/// column beside it, so a deep path stays in sight. Not something Windows
/// has, but handy on a Mac.
final class Columns: NSObject, NSBrowserDelegate {
    let browser = FileBrowser()
    var sort = SortSpec.saved
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onDrop: (([URL], URL, _ move: Bool) -> Void)?
    private var root: ColumnNode?

    override init() {
        super.init()
        browser.delegate = self
        browser.target = self
        browser.action = #selector(clicked(_:))
        browser.doubleAction = #selector(doubleClicked(_:))
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 160
        browser.setDefaultColumnWidth(220)
        browser.rowHeight = 22
        browser.focusRingType = .none
        browser.registerForDraggedTypes([.fileURL])
        browser.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
    }

    /// Shows `folder`, whose listing (already sorted) is `items`. The folders
    /// opened inside it stay open through a refresh of the same folder.
    func show(_ folder: URL, items: [FileItem]) {
        let keep = root?.url.key == folder.key ? openPath() : []
        let node = ColumnNode(url: folder, item: nil)
        node.children = items.map { ColumnNode(url: $0.url, item: $0) }
        root = node
        browser.loadColumnZero()
        reopen(keep[...])
    }

    /// The item selected in each column, left to right.
    private func openPath() -> [String] {
        guard browser.lastColumn >= 0 else { return [] }
        var path: [String] = []
        for column in 0...browser.lastColumn {
            let row = browser.selectedRow(inColumn: column)
            guard row >= 0, let node = browser.item(atRow: row, inColumn: column) as? ColumnNode else { break }
            path.append(node.url.key)
        }
        return path
    }

    /// Selects the path again, column by column; a column still being read
    /// carries on once it is, unless something else was chosen meanwhile.
    private func reopen(_ path: ArraySlice<String>, column: Int = 0) {
        guard let key = path.first, column <= browser.lastColumn,
              let parent = browser.parentForItems(inColumn: column) as? ColumnNode else { return }
        guard let children = parent.children else {
            parent.whenLoaded.append { [weak self, weak parent] in
                guard let self, let parent, column <= self.browser.lastColumn,
                      (self.browser.parentForItems(inColumn: column) as? ColumnNode) === parent else { return }
                self.reopen(path, column: column)
            }
            return
        }
        guard let row = children.firstIndex(where: { $0.url.key == key }) else { return }
        browser.selectRow(row, inColumn: column)
        reopen(path.dropFirst(), column: column + 1)
    }

    /// A folder's contents, for the browser. The first time they are read in
    /// the background, so a slow network drive doesn't stop the window; the
    /// column says "Loading…" until then.
    private func children(of node: ColumnNode) -> [ColumnNode] {
        if let children = node.children { return children }
        if !node.loading {
            node.loading = true
            let (url, item, order, hidden) = (node.url, node.item, self.sort, Prefs.showHidden)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let made = ColumnNode.read(url, item: item, sort: order, showHidden: hidden)
                DispatchQueue.main.async {
                    node.loading = false
                    node.children = made
                    self?.loaded(node)
                    let waiting = node.whenLoaded
                    node.whenLoaded = []
                    waiting.forEach { $0() }
                }
            }
        }
        return [node.loadingRow]
    }

    /// Puts what was read in place of "Loading…", if that folder is still on screen.
    private func loaded(_ node: ColumnNode) {
        guard browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn where (browser.parentForItems(inColumn: column) as? ColumnNode) === node {
            let selectedHere = browser.selectedColumn == column
            browser.reloadColumn(column)
            if selectedHere { onSelect?() }
            return
        }
    }

    /// Selects items in the first column (after coming back out of a folder, say).
    func select(keys: Set<String>) {
        guard !keys.isEmpty, let children = root?.children else { return }
        let rows = IndexSet(children.indices.filter { keys.contains(children[$0].url.key) })
        guard !rows.isEmpty else { return }
        browser.selectRowIndexes(rows, inColumn: 0)
    }

    var selectedItems: [FileItem] {
        let column = browser.selectedColumn
        guard column >= 0, let rows = browser.selectedRowIndexes(inColumn: column) else { return [] }
        return rows.compactMap { (browser.item(atRow: $0, inColumn: column) as? ColumnNode)?.item }
    }

    /// The folder you are looking at: the selected folder when it is the
    /// last column shown, otherwise the one the selection is in.
    var folder: URL? {
        let selection = selectedItems
        if selection.count == 1, selection[0].isFolder { return selection[0].url }
        let column = max(browser.selectedColumn, 0)
        // The first listing may still be loading when this layout is selected.
        guard column <= browser.lastColumn else { return root?.url }
        return (browser.parentForItems(inColumn: column) as? ColumnNode)?.url ?? root?.url
    }

    @objc private func clicked(_ sender: Any?) { onSelect?() }

    @objc private func doubleClicked(_ sender: Any?) {
        guard browser.clickedRow >= 0 else { return }
        onOpen?()
    }

    // MARK: NSBrowserDelegate

    private func node(_ item: Any?) -> ColumnNode? { item as? ColumnNode ?? (item == nil ? root : nil) }

    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).map { children(of: $0).count } ?? 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        // Only rows numberOfChildrenOfItem counted are asked for, from the same kept listing.
        guard let children = node(item).map(self.children(of:)), children.indices.contains(index) else {
            return ColumnNode(url: root?.url ?? URL(fileURLWithPath: "/"), item: nil, problem: "")
        }
        return children[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        node(item)?.isLeaf ?? true
    }

    /// The browser's cells are plain text cells on current macOS (it ignores
    /// setCellClass), so the icon travels inside the title.
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        if let problem = node(item)?.problem {
            return NSAttributedString(string: problem, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        guard let file = node(item)?.item else { return "" }
        let icon = NSTextAttachment()
        icon.image = menuIcon(file.icon)
        icon.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let title = NSMutableAttributedString(attachment: icon)
        title.append(NSAttributedString(string: "  " + file.name, attributes: [
            .foregroundColor: file.isHidden ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        return title
    }

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
        !rowIndexes.contains { (browser.item(atRow: $0, inColumn: column) as? ColumnNode)?.problem != nil }
    }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        let urls = rowIndexes.compactMap { (browser.item(atRow: $0, inColumn: column) as? ColumnNode)?.url }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }

    private func dropTarget(row: Int, column: Int, operation: NSBrowser.DropOperation) -> URL? {
        if operation == .on, row >= 0, let node = browser.item(atRow: row, inColumn: column) as? ColumnNode, !node.isLeaf {
            return node.url
        }
        return (browser.parentForItems(inColumn: column) as? ColumnNode)?.url
    }

    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>,
                 column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
        guard let target = dropTarget(row: row.pointee, column: column.pointee, operation: dropOperation.pointee) else { return [] }
        if dropOperation.pointee != .on || (browser.item(atRow: row.pointee, inColumn: column.pointee) as? ColumnNode)?.isLeaf == true {
            row.pointee = -1
            dropOperation.pointee = .on
        }
        return DragOps.operation(for: info, into: target)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int,
                 dropOperation: NSBrowser.DropOperation) -> Bool {
        guard let target = dropTarget(row: row, column: column, operation: dropOperation) else { return false }
        let operation = DragOps.operation(for: info, into: target)
        guard !operation.isEmpty else { return false }
        onDrop?(DragOps.urls(from: info), target, operation == .move)
        return true
    }
}
