import AppKit

/// A folder or file in a disk-usage scan, sized by what it takes on disk.
final class UsageNode {
    let url: URL
    let name: String
    let isFolder: Bool
    let isPackage: Bool
    let kind: SearchFilters.Kind?
    var size: Int64 = 0
    var files = 0
    /// Items in this folder's tree that couldn't be read, so its size is a
    /// lower bound. Kept on every folder, for when one is opened from the cache.
    var unreadable = 0
    /// Files too small to keep one by one, summed per folder…
    var smallFiles: Int64 = 0
    var smallCount = 0
    /// …and by kind, for the legend (indexed as `UsageNode.kinds`).
    var smallByKind: [Int64]?
    static let kinds: [SearchFilters.Kind?] = [nil, .images, .video, .audio, .documents, .archives, .apps]

    func addSmall(_ size: Int64, kind: SearchFilters.Kind?) {
        smallFiles += size
        smallCount += 1
        if smallByKind == nil { smallByKind = Array(repeating: 0, count: Self.kinds.count) }
        smallByKind![Self.kinds.firstIndex(of: kind) ?? 0] += size
    }
    var children: [UsageNode] = []
    weak var parent: UsageNode?
    /// Stands for the small files of `parent` in the treemap.
    let isRest: Bool
    /// What takes most of the room in a folder, worked out once, for its tint.
    private var dominant: SearchFilters.Kind??

    var dominantKind: SearchFilters.Kind? {
        if let dominant { return dominant }
        let kind = TreemapView.legend(of: self).first?.kind
        dominant = .some(kind)
        return kind
    }

    init(url: URL, name: String, isFolder: Bool, isPackage: Bool = false, kind: SearchFilters.Kind?, isRest: Bool = false) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.isPackage = isPackage
        self.kind = kind
        self.isRest = isRest
    }

    /// Adds up the sizes from the bottom, and puts the biggest first.
    @discardableResult
    func total() -> Int64 {
        var bytes = smallFiles
        var count = smallCount
        var missing = unreadable
        for child in children {
            if child.isFolder { child.total() }
            bytes += child.size
            count += child.isFolder ? child.files : 1
            missing += child.isFolder ? child.unreadable : 0
        }
        size = bytes
        files = count
        unreadable = missing
        children.sort { $0.size > $1.size }
        return bytes
    }

    /// The node for `url` somewhere below (or at) this one.
    func find(_ url: URL) -> UsageNode? {
        let path = url.standardizedFileURL.path
        let mine = self.url.standardizedFileURL.path
        if path == mine { return self }
        guard path.hasPrefix(mine == "/" ? "/" : mine + "/") else { return nil }
        let rest = path.dropFirst(mine == "/" ? 1 : mine.count + 1).split(separator: "/")
        var node = self
        for name in rest {
            guard let next = node.children.first(where: { $0.name == name }) else { return nil }
            node = next
        }
        return node
    }

    /// Gone (to the Trash): out of the tree, its size out of every folder above.
    func remove() {
        var ancestor = parent
        while let node = ancestor {
            node.size -= size
            node.files -= isFolder ? files : 1
            node.unreadable -= isFolder ? unreadable : 0
            ancestor = node.parent
        }
        parent?.children.removeAll { $0 === self }
    }

    /// Children as the treemap shows them: the folder's small files as one more block.
    var blocks: [UsageNode] {
        var list = children.filter { $0.size > 0 }
        if smallFiles > 0 {
            let rest = UsageNode(url: url, name: smallCount == 1 ? "1 small file" : "\(smallCount) small files",
                                 isFolder: false, kind: nil, isRest: true)
            rest.size = smallFiles
            rest.files = smallCount
            rest.parent = self
            list.append(rest)
            list.sort { $0.size > $1.size }
        }
        return list
    }
}

/// Walks a folder tree adding up what everything takes on disk. Other
/// disks mounted inside it are left out, as is the second view of the
/// system volume under /System/Volumes.
final class UsageScanner {
    /// Files at least this big get a block of their own; the rest are summed per folder.
    static let ownBlockFrom: Int64 = 512 * 1024
    private let cancelled = CancelFlag()

    func cancel() { cancelled.set() }

    func scan(_ root: URL, progress: ((Int, Int64) -> Void)? = nil) -> UsageNode? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isVolumeKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let rootPath = root.standardizedFileURL.path
        let top = UsageNode(url: root, name: FileManager.default.displayName(atPath: rootPath), isFolder: true, kind: .folders)
        var folders: [String: UsageNode] = [rootPath: top]
        // The walk may report paths through /private when the root is under /var or /tmp.
        if let real = realpath(rootPath, nil) {
            folders[String(cString: real)] = top
            free(real)
        }
        // Folders that can't be read are counted where they are, so a partial
        // measure doesn't pass for a whole one, here or in any folder above.
        var failed: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true), includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, _ in failed.append(url); return true }) else {
            top.unreadable = 1
            return top
        }
        var count = 0
        var bytes: Int64 = 0
        var reported = Date()
        var kindByExtension: [String: SearchFilters.Kind?] = [:]
        let keySet = Set(keys)
        while let url = walker.nextObject() as? URL {
            if cancelled.isSet { return nil }
            let path = url.path
            guard let parent = folders[(path as NSString).deletingLastPathComponent] else { continue }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                parent.unreadable += 1
                walker.skipDescendants()
                continue
            }
            if values.isDirectory == true && values.isSymbolicLink != true {
                if values.isVolume == true || path == "/System/Volumes" {
                    walker.skipDescendants()
                    continue
                }
                let package = values.isPackage == true
                let node = UsageNode(url: url, name: url.lastPathComponent, isFolder: true, isPackage: package,
                                     kind: package ? SearchFilters.kind(ofFile: url) ?? .apps : .folders)
                node.parent = parent
                parent.children.append(node)
                folders[path] = node
            } else {
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                count += 1
                bytes += size
                if size >= Self.ownBlockFrom {
                    let node = UsageNode(url: url, name: url.lastPathComponent, isFolder: false, kind: SearchFilters.kind(ofFile: url))
                    node.size = size
                    node.files = 1
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    let ext = url.pathExtension.lowercased()
                    let kind: SearchFilters.Kind?
                    if let known = kindByExtension[ext] { kind = known } else {
                        kind = SearchFilters.kind(ofFile: url)
                        kindByExtension[ext] = kind
                    }
                    parent.addSmall(size, kind: kind)
                }
                if let progress, count % 500 == 0, Date().timeIntervalSince(reported) > 0.2 {
                    reported = Date()
                    progress(count, bytes)
                }
            }
        }
        for url in failed {
            // As the walk spells paths (standardizing would drop a /private the walk kept).
            let path = url.path
            let node = folders[path] ?? folders[(path as NSString).deletingLastPathComponent] ?? top
            node.unreadable += 1
        }
        top.total()
        return top
    }
}

/// Scans kept for the session, so walking into a folder already measured
/// is instant. F5 measures again.
enum UsageCache {
    private static var trees: [UsageNode] = []

    static func node(for url: URL) -> UsageNode? {
        for tree in trees { if let node = tree.find(url) { return node } }
        return nil
    }

    static func store(_ tree: UsageNode) {
        trees.removeAll { tree.find($0.url) != nil || $0.find(tree.url) != nil }
        trees.insert(tree, at: 0)
        if trees.count > 3 { trees.removeLast() }
    }

    /// Drops every measure that `url` is part of, and every measure made inside it.
    static func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        trees.removeAll {
            let root = $0.url.standardizedFileURL.path
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/") || root.hasPrefix(path == "/" ? "/" : path + "/")
        }
    }

    /// Something was added to or taken from `folder`: its size, and its parents', are no longer known.
    static func changed(_ folder: URL) { forget(folder) }
}

/// The squarified treemap layout (Bruls, Huizing and van Wijk): rectangles
/// as close to square as can be, in the order given, largest first.
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start + 1
            var sum = areas[start]
            var worst = worstRatio(areas[start..<end], sum: sum, side: side)
            while end < areas.count {
                let candidate = worstRatio(areas[start...end], sum: sum + areas[end], side: side)
                if candidate > worst { break }
                sum += areas[end]
                worst = candidate
                end += 1
            }
            let thickness = CGFloat(sum / side)
            let alongHeight = remaining.width >= remaining.height
            var offset: CGFloat = 0
            for k in start..<end {
                let length = thickness > 0 ? CGFloat(areas[k]) / thickness : 0
                result[k] = alongHeight
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            remaining = alongHeight
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY, width: max(remaining.width - thickness, 0), height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: max(remaining.height - thickness, 0))
            start = end
        }
        return result
    }

    private static func worstRatio(_ row: ArraySlice<Double>, sum: Double, side: Double) -> Double {
        guard let largest = row.max(), let smallest = row.min(), smallest > 0, sum > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * largest / s2, s2 / (w2 * smallest))
    }
}

/// Disk usage (⌘4), after disktree: every folder a tile sized by what it
/// takes on disk, the folders inside it drawn within it, files coloured by
/// kind. A summary and a legend sit on top. Click to select, double-click
/// to go in (its folders are measured already), right-click for the usual menu.
final class TreemapView: NSView {
    weak var host: ExplorerTab?
    var root: UsageNode? {
        didSet {
            selected = nil
            hovered = nil
            laidOut = .zero
            legend = root.map(Self.legend(of:)) ?? []
            needsDisplay = true
        }
    }
    var message: String? { didSet { needsDisplay = true } }
    private(set) var selected: UsageNode?
    private var hovered: UsageNode?

    private struct Block {
        let rect: CGRect
        let node: UsageNode
        /// A folder drawn as a frame with its name on top and its contents inside.
        let framed: Bool
    }
    private var blocks: [Block] = []
    private var laidOut = CGSize.zero
    private var legend: [(kind: SearchFilters.Kind?, size: Int64)] = []
    private static let headerHeight: CGFloat = 54

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    func relayout() {
        laidOut = .zero
        if let root { legend = Self.legend(of: root) }
        needsDisplay = true
    }

    func select(_ node: UsageNode?) {
        selected = node?.isRest == true ? node?.parent : node
        needsDisplay = true
        host?.selectionChanged()
    }

    // MARK: What is in it, by kind

    /// Sizes by kind of file, biggest first; small files count as "other".
    static func legend(of root: UsageNode) -> [(kind: SearchFilters.Kind?, size: Int64)] {
        var totals: [SearchFilters.Kind?: Int64] = [:]
        func walk(_ node: UsageNode) {
            if let small = node.smallByKind {
                for (index, size) in small.enumerated() where size > 0 { totals[UsageNode.kinds[index], default: 0] += size }
            }
            for child in node.children {
                if child.isFolder && !child.isPackage { walk(child) } else { totals[child.kind, default: 0] += child.size }
            }
        }
        walk(root)
        return totals.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.size > $1.size }
    }

    private static func title(of kind: SearchFilters.Kind?) -> String {
        guard let kind, kind != .any, kind != .folders else { return "Other" }
        return kind.title
    }

    // MARK: Layout

    private var mapArea: CGRect {
        CGRect(x: 12, y: Self.headerHeight, width: bounds.width - 24, height: bounds.height - Self.headerHeight - 12)
    }

    private func layoutBlocks() {
        blocks = []
        laidOut = bounds.size
        guard let root, mapArea.width > 10, mapArea.height > 10 else { return }
        place(root, in: mapArea, depth: 0)
    }

    private func place(_ folder: UsageNode, in rect: CGRect, depth: Int) {
        let children = folder.blocks
        let rects = Treemap.layout(children.map { Double($0.size) }, in: rect)
        for (child, frame) in zip(children, rects) where frame.width >= 3 && frame.height >= 3 {
            // Three levels at most: deeper, a double-click shows it (already measured, so at once).
            let roomy = child.isFolder && !child.isPackage && frame.width > 70 && frame.height > 52 && depth < 2 && !child.blocks.isEmpty
            blocks.append(Block(rect: frame, node: child, framed: roomy))
            if roomy {
                place(child, in: CGRect(x: frame.minX + 4, y: frame.minY + 22, width: frame.width - 8, height: frame.height - 26),
                      depth: depth + 1)
            }
        }
    }

    // MARK: Drawing

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Soft colours by kind; the same hue a little deeper in dark mode.
    private func color(_ kind: SearchFilters.Kind?) -> NSColor {
        let hue: CGFloat
        switch kind {
        case .images: hue = 0.58
        case .video: hue = 0.74
        case .audio: hue = 0.93
        case .documents: hue = 0.08
        case .archives: hue = 0.13
        case .apps: hue = 0.37
        default: return dark ? NSColor(white: 0.34, alpha: 1) : NSColor(white: 0.84, alpha: 1)
        }
        return dark ? NSColor(hue: hue, saturation: 0.42, brightness: 0.52, alpha: 1)
                    : NSColor(hue: hue, saturation: 0.30, brightness: 0.95, alpha: 1)
    }

    /// A file in its kind's colour; a folder tinted by what fills it most.
    private func color(for node: UsageNode) -> NSColor {
        guard node.isFolder && !node.isPackage else { return color(node.isRest ? node.parent?.dominantKind : node.kind) }
        let kind = node.dominantKind
        return kind == nil ? color(nil) : color(kind).blended(withFraction: 0.45, of: color(nil)) ?? color(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let root else {
            if let message { drawCentered(message) }
            return
        }
        if laidOut != bounds.size { layoutBlocks() }
        if dirtyRect.minY < Self.headerHeight { drawHeader(root) }
        let ink = dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        let frameFill = dark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
        for block in blocks where block.rect.intersects(dirtyRect) {
            let tile = block.rect.insetBy(dx: 1, dy: 1)
            guard tile.width > 0, tile.height > 0 else { continue }
            let radius = min(5, tile.width / 4, tile.height / 4)
            let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
            if block.framed {
                frameFill.setFill()
                shape.fill()
                label(block.node, in: CGRect(x: tile.minX + 7, y: tile.minY + 4, width: tile.width - 14, height: 16), ink: ink, framed: true)
            } else {
                color(for: block.node).setFill()
                shape.fill()
                if block.node === hovered {
                    NSColor(white: 1, alpha: dark ? 0.10 : 0.35).setFill()
                    shape.fill()
                }
                if tile.width > 46 && tile.height > 20 {
                    label(block.node, in: CGRect(x: tile.minX + 6, y: tile.minY + 4, width: tile.width - 12, height: tile.height - 8),
                          ink: ink, framed: false)
                }
            }
        }
        if let selected, let block = blocks.first(where: { $0.node === selected }) {
            let tile = block.rect.insetBy(dx: 1, dy: 1)
            let outline = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            outline.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
    }

    /// The folder's name, how much it holds, and what kinds of things take the room.
    private func drawHeader(_ root: UsageNode) {
        let title = NSAttributedString(string: root.name, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        title.draw(at: NSPoint(x: 14, y: 8))
        let folders = root.children.filter { $0.isFolder && !$0.isPackage }.count
        var facts = "\(Format.bytes(root.size))  ·  \(Format.count(Int64(root.files))) files"
        if folders > 0 { facts += "  ·  \(Format.count(Int64(folders))) folders" }
        if root.unreadable > 0 { facts += "  ·  \(Format.count(Int64(root.unreadable))) couldn't be read" }
        if let volume = try? root.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            facts += "  ·  \(Format.bytes(volume)) free on the disk"
        }
        NSAttributedString(string: facts, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: 14, y: 30))

        // The legend, right-aligned: a dot, the kind, its size.
        var x = bounds.width - 14
        for entry in legend.prefix(5).reversed() {
            let text = NSAttributedString(string: "\(Self.title(of: entry.kind))  \(Format.bytes(entry.size))", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let width = text.size().width
            x -= width
            guard x > title.size().width + 40 else { break }
            text.draw(at: NSPoint(x: x, y: 12))
            x -= 14
            color(entry.kind).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 16, width: 9, height: 9)).fill()
            x -= 14
        }
    }

    private func label(_ node: UsageNode, in rect: CGRect, ink: NSColor, framed: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let share = root.map { $0.size > 0 ? Double(node.size) / Double($0.size) * 100 : 0 } ?? 0
        let amount = "\(Format.bytes(node.size))  ·  \(share < 1 ? "<1" : String(Int(share.rounded())))%"
        let name = NSAttributedString(string: node.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style,
        ])
        let detail = NSAttributedString(string: amount, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.6),
            .paragraphStyle: style,
        ])
        if framed || rect.height < 30 {
            // One line: the name, then the size beside it.
            let line = NSMutableAttributedString(attributedString: name)
            line.append(NSAttributedString(string: "   "))
            line.append(detail)
            line.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            name.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            detail.draw(with: CGRect(x: rect.minX, y: rect.minY + 15, width: rect.width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawCentered(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2 - size.height), withAttributes: attributes)
    }

    // MARK: Mouse

    private func node(at event: NSEvent) -> UsageNode? {
        let point = convert(event.locationInWindow, from: nil)
        return blocks.last { $0.rect.contains(point) }?.node
    }

    override func mouseMoved(with event: NSEvent) {
        let node = node(at: event)
        guard node !== hovered else { return }
        setHovered(node)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// Only the tile left and the tile entered are drawn again.
    private func setHovered(_ node: UsageNode?) {
        for old in [hovered, node] {
            if let old, let block = blocks.first(where: { $0.node === old }) { setNeedsDisplay(block.rect) }
        }
        hovered = node
        host?.usageHovered(node)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let node = node(at: event)
        select(node)
        if event.clickCount == 2, let node { host?.openUsageNode(node.isRest ? node.parent ?? node : node) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        select(node(at: event))
        return host?.contextMenu()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}
