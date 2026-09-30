import AppKit

/// A short burst of typing selects a name; a pause starts a new prefix.
struct TypeSelection {
    private var prefix = ""
    private var lastTyped: TimeInterval = 0

    mutating func reset() {
        prefix = ""
        lastTyped = 0
    }

    mutating func match(_ text: String, at time: TimeInterval, names: [String], selected: Int?) -> Int? {
        if time - lastTyped > 1 || time < lastTyped { reset() }
        // Repeating one letter walks through names beginning with that letter.
        let cycling = prefix.count == 1 && prefix.caseInsensitiveCompare(text) == .orderedSame
        let continuing = !prefix.isEmpty && !cycling
        prefix = continuing ? prefix + text : text
        lastTyped = time
        guard !names.isEmpty else { return nil }
        let current = selected.flatMap { names.indices.contains($0) ? $0 : nil }
        let start = current.map { continuing ? $0 : ($0 + 1) % names.count } ?? 0
        for offset in names.indices {
            let index = (start + offset) % names.count
            if names[index].range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: .current) != nil {
                return index
            }
        }
        return nil
    }
}

extension ExplorerTab {
    /// Consistent type-to-select for the list, icons and the current browser column.
    /// Space keeps its Quick Look shortcut; text fields are handled by their editor.
    func handleTypeSelection(_ event: NSEvent) -> Bool {
        guard shownMode != .usage,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
              }), text != " " else { return false }

        if shownMode == .columns {
            let browser = columns.browser
            let column = max(browser.selectedColumn, 0)
            guard column <= browser.lastColumn,
                  let parent = browser.parentForItems(inColumn: column) as? ColumnNode else { return true }
            let children = parent.loadChildren(sort: columns.sort)
            if let row = typeSelection.match(text, at: event.timestamp,
                                             names: children.map { $0.item?.name ?? "" },
                                             selected: browser.selectedRow(inColumn: column)) {
                browser.selectRow(row, inColumn: column)
                browser.scrollRowToVisible(row, inColumn: column)
                selectionChanged()
            }
        } else if let index = typeSelection.match(text, at: event.timestamp,
                                                  names: items.map(\.name), selected: firstSelectedIndex) {
            selectQuietly([items[index].key])
            scroll(to: index)
            listSelectionDidChange()
        }
        // An unmatched prefix leaves the selection alone, without AppKit's own type selection.
        return true
    }
}
