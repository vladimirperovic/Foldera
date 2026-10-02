import AppKit

/// Two panes side by side, as in Total Commander: what is selected in one
/// is copied or moved to the folder in the other, and the two folders can
/// be compared and synced. The window keeps the second pane (see
/// `ExplorerWindow.showTwoPanes`); these are the commands a pane is given.
extension ExplorerTab {
    @objc func setOnePane(_ sender: Any?) { host?.showTwoPanes(false) }
    @objc func setTwoPanes(_ sender: Any?) { host?.showTwoPanes(true) }

    /// ⌥F5 (F5 refreshes, as in Windows).
    @objc func copyToOtherPane(_ sender: Any?) { sendToOtherPane(move: false) }
    /// F6, as in Total Commander.
    @objc func moveToOtherPane(_ sender: Any?) { sendToOtherPane(move: true) }

    private func sendToOtherPane(move: Bool) {
        guard let other = host?.otherPane(of: self), let folder = other.currentFolder, folder.key != currentFolder?.key else { return }
        let urls = selectedItems.filter { $0.volume == nil }.map(\.url)
        guard !urls.isEmpty, !(move && isInArchive) else { return }
        transfer(urls, into: folder, move: move) { [weak self, weak other] in
            other?.reload()
            if move { self?.reload() }
        }
    }

    /// The other pane goes where this one is.
    @objc func sameFolderInOtherPane(_ sender: Any?) {
        guard let other = host?.otherPane(of: self), other.location != location else { return }
        other.navigate(to: location)
    }

    /// Ctrl+U in Total Commander: the two panes trade places.
    @objc func swapPanes(_ sender: Any?) {
        guard let other = host?.otherPane(of: self) else { return }
        let (here, there) = (location, other.location)
        navigate(to: there)
        other.navigate(to: here)
        focusList()
    }

    /// Total Commander's Compare Directories: in each pane, whatever the other
    /// lacks, or holds an older copy of (by date modified, to two seconds), is selected.
    @objc func comparePanes(_ sender: Any?) {
        guard let other = host?.otherPane(of: self) else { return }
        let (mine, theirs) = Self.newerOrMissing(items, other.items)
        other.select(keys: theirs)
        other.selectionChanged()
        select(keys: mine)
        selectionChanged()
        focusList()
        busyNote(mine.isEmpty && theirs.isEmpty
                 ? "Both folders hold the same"
                 : "Newer or missing on the other side: \(Format.items(mine.count)) here, \(Format.items(theirs.count)) there")
    }

    /// The keys of the items on each side that the other side lacks or has
    /// an older copy of. Names are matched ignoring case; a folder counts
    /// only when the other side has nothing of that name.
    static func newerOrMissing(_ a: [FileItem], _ b: [FileItem]) -> (Set<String>, Set<String>) {
        func byName(_ list: [FileItem]) -> [String: FileItem] {
            Dictionary(list.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
        let (left, right) = (byName(a), byName(b))
        func pick(_ side: [String: FileItem], against other: [String: FileItem]) -> Set<String> {
            Set(side.compactMap { name, item -> String? in
                guard let match = other[name] else { return item.key }
                guard !item.isFolder, !match.isFolder, let mine = item.modified, let theirs = match.modified else { return nil }
                return mine.timeIntervalSince(theirs) > Sync.tolerance ? item.key : nil
            })
        }
        return (pick(left, against: right), pick(right, against: left))
    }

    /// The two folders in the Sync window, the left pane on the left.
    @objc func syncPanes(_ sender: Any?) {
        guard let other = host?.otherPane(of: self), let mine = location.url, let theirs = other.location.url else { return }
        let firstIsMine = host?.partner !== self
        SyncWindow.show(firstIsMine ? [mine, theirs] : [theirs, mine])
    }
}
