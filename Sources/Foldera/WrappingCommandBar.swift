import AppKit

/// A command bar whose controls stay on screen when the window or a pane
/// becomes narrow. Controls keep their normal hit area and wrap to another
/// row; the final group stays right-aligned when there is room for it.
final class WrappingCommandBar: NSView {
    private let leading: [NSView]
    private let trailing: [NSView]
    private var barHeight: NSLayoutConstraint!
    private let rowHeight: CGFloat = 40
    private let inset: CGFloat = 10

    override var isFlipped: Bool { true }

    init(leading: [NSView], trailing: [NSView]) {
        self.leading = leading
        self.trailing = trailing
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("command-bar")
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        barHeight = heightAnchor.constraint(equalToConstant: rowHeight)
        barHeight.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private struct Item {
        let view: NSView
        let trailing: Bool
        let width: CGFloat
        let height: CGFloat
        var separator: Bool { view is NSBox }
    }

    private func gap(_ previous: Item, _ next: Item) -> CGFloat {
        previous.separator || next.separator ? 6 : 2
    }

    override func layout() {
        super.layout()
        guard bounds.width > inset * 2 else { return }
        let available = bounds.width - inset * 2
        let items = (leading.map { ($0, false) } + trailing.map { ($0, true) })
            .filter { !$0.0.isHidden }
            .map { view, trailing -> Item in
                let size = view.intrinsicContentSize
                return Item(view: view, trailing: trailing,
                            width: view is NSBox ? 1 : max(30, ceil(size.width)),
                            height: view is NSBox ? 20 : max(1, ceil(size.height)))
            }
        // Separators are decoration, so don't leave one alone at a row edge.
        for item in items where item.separator { item.view.alphaValue = 0 }
        var rows: [[Item]] = []
        var row: [Item] = []
        var width: CGFloat = 0
        func finishRow() {
            while row.last?.separator == true { row.removeLast() }
            if !row.isEmpty { rows.append(row) }
            row = []
            width = 0
        }
        for item in items {
            if item.separator && row.isEmpty { continue }
            let spacing = row.last.map { gap($0, item) } ?? 0
            if !row.isEmpty && width + spacing + item.width > available {
                finishRow()
                if item.separator { continue }
            }
            width += (row.last.map { gap($0, item) } ?? 0) + item.width
            row.append(item)
        }
        finishRow()
        let height = CGFloat(max(1, rows.count)) * rowHeight
        if barHeight.constant != height { barHeight.constant = height }
        for (index, row) in rows.enumerated() {
            let used = row.enumerated().reduce(CGFloat(0)) { total, entry in
                total + entry.element.width + (entry.offset == 0 ? 0 : gap(row[entry.offset - 1], entry.element))
            }
            let firstTrailing = row.firstIndex { $0.trailing }
            var x = inset
            for (column, item) in row.enumerated() {
                if column > 0 { x += gap(row[column - 1], item) }
                if column == firstTrailing { x += max(0, available - used) }
                item.view.frame = NSRect(x: x, y: CGFloat(index) * rowHeight + (rowHeight - item.height) / 2,
                                         width: item.width, height: item.height)
                if item.separator { item.view.alphaValue = 1 }
                x += item.width
            }
        }
    }
}
