import AppKit

/// Feeding the details and icons views, and dropping files onto them.
extension ExplorerTab: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier, row < items.count else { return nil }
        let item = items[row]
        if column == .nameColumn {
            let cell = tableView.makeView(withIdentifier: .nameCell, owner: self) as? NameCell ?? NameCell()
            cell.configure(item, dimmed: FileClipboard.shared.isCut(item.key))
            return cell
        }
        if column == .statusColumn {
            let cell = tableView.makeView(withIdentifier: StatusCell.id, owner: self) as? StatusCell ?? StatusCell()
            cell.configure(item.cloud)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: .textCell, owner: self) as? TextCell ?? TextCell()
        cell.textField?.stringValue = text(for: item, in: column)
        cell.textField?.alignment = column == .sizeColumn || column == .freeColumn ? .right : .left
        cell.textField?.lineBreakMode = column == .locationColumn ? .byTruncatingMiddle : .byTruncatingTail
        return cell
    }

    private func text(for item: FileItem, in column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case .locationColumn: return Format.path(item.url.deletingLastPathComponent())
        case .modifiedColumn: return item.modified.map(Format.date.string(from:)) ?? ""
        case .kindColumn: return item.kind
        case .sizeColumn:
            if let volume = item.volume { return Format.bytes(volume.total) }
            return (item.size ?? item.folderSize).map(Format.kilobytes) ?? ""
        case .freeColumn: return item.volume.map { Format.bytes($0.free) } ?? ""
        default: return ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        listSelectionDidChange()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let raw = descriptor.key,
              let key = SortKey(rawValue: raw) else { return }
        let spec = SortSpec(key: key, ascending: descriptor.ascending)
        guard spec != sort else { return }
        sort = spec
        spec.save()
        resort()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        tableColumn?.identifier == .nameColumn && row < items.count ? items[row].name : nil
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count, items[row].volume == nil else { return nil }
        return items[row].url as NSURL
    }

    /// The folder files dropped on empty space go to: the one on screen,
    /// unless it is a list of search results or drives.
    private var dropFolder: URL? { currentFolder }

    private func folderItem(at index: Int) -> URL? {
        guard index >= 0, index < items.count else { return nil }
        return folderTarget(of: items[index])
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, let folder = folderItem(at: row) {
            return DragOps.operation(for: info, into: folder)
        }
        guard let folder = dropFolder else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return DragOps.operation(for: info, into: folder)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = (dropOperation == .on ? folderItem(at: row) : nil) ?? dropFolder
        guard let target else { return false }
        let operation = DragOps.operation(for: info, into: target)
        guard !operation.isEmpty else { return false }
        transfer(DragOps.urls(from: info), into: target, move: operation == .move)
        return true
    }
}

extension ExplorerTab: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: .iconItem, for: indexPath)
        if let tile = tile as? IconItem, indexPath.item < items.count {
            let item = items[indexPath.item]
            tile.side = Prefs.iconSize
            tile.configure(item, dimmed: FileClipboard.shared.isCut(item.key))
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        listSelectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        listSelectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < items.count, items[indexPath.item].volume == nil else { return nil }
        return items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let index = (proposedIndexPath.pointee as IndexPath).item
        if dropOperation.pointee == .on, let folder = folderItem(at: index) {
            return DragOps.operation(for: info, into: folder)
        }
        guard let folder = dropFolder else { return [] }
        return DragOps.operation(for: info, into: folder)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let target = (dropOperation == .on ? folderItem(at: indexPath.item) : nil) ?? dropFolder
        guard let target else { return false }
        let operation = DragOps.operation(for: info, into: target)
        guard !operation.isEmpty else { return false }
        transfer(DragOps.urls(from: info), into: target, move: operation == .move)
        return true
    }
}

/// The inline rename box, and the search field's arrow key.
extension ExplorerTab: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === searchField {
            // ↓ from the search box goes into the results, as in Windows.
            guard selector == #selector(NSResponder.moveDown(_:)), !items.isEmpty else { return false }
            focusList()
            if selectedItems.isEmpty {
                select(keys: [items[0].key])
                selectionChanged()
            }
            return true
        }
        guard renamingKey != nil else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename = true
            focusList()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            focusList()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== searchField, let key = renamingKey else { return }
        renamingKey = nil
        let cancelled = cancelRename
        cancelRename = false
        let proposed = field.stringValue
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        let deferred = reloadDeferred
        reloadDeferred = false
        guard let item = items.first(where: { $0.key == key }) else {
            load()
            return
        }
        field.stringValue = item.name
        if !cancelled && proposed != item.name {
            commitRename(item, to: proposed)
        } else if deferred {
            reload()
        }
    }
}
