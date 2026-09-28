import AppKit

/// Finder tags, the coloured dots. The list and colours are Finder's own,
/// so a tag set here looks the same there.
enum Tags {
    /// The seven colour tags and Finder's label numbers for them.
    static let standard: [(name: String, label: Int)] = [
        ("Red", 6), ("Orange", 7), ("Yellow", 5), ("Green", 2), ("Blue", 4), ("Purple", 3), ("Gray", 1),
    ]

    /// Finder's favourite tags, in its order.
    static var favourites: [String] {
        let names = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames")?.filter { !$0.isEmpty } ?? []
        return names.isEmpty ? standard.map(\.name) : names
    }

    /// nil for a tag without a colour.
    static func color(of tag: String) -> NSColor? {
        guard let label = standard.first(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame })?.label else { return nil }
        switch label {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        default: return .systemOrange
        }
    }

    static func names(of url: URL) -> [String] { FileItem.tagNames(of: url) }

    static func set(_ tags: [String], on url: URL) throws {
        try FileOps.refuseInArchive([url])
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// Adds `tag` to every item, or takes it off if every item has it already.
    static func toggle(_ tag: String, on urls: [URL]) -> [String] {
        let everyone = urls.allSatisfy { names(of: $0).contains(tag) }
        var failures: [String] = []
        for url in urls {
            var tags = names(of: url)
            if everyone {
                tags.removeAll { $0 == tag }
            } else if !tags.contains(tag) {
                tags.append(tag)
            }
            do { try set(tags, on: url) } catch { failures.append(error.localizedDescription) }
        }
        return failures
    }

    /// A dot for menus: filled with the tag's colour, or an outline for a tag without one.
    static func dot(for tag: String, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color = color(of: tag) {
                color.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
    }
}

/// Up to three overlapping dots after a name, as Finder draws them.
final class TagDots: NSView {
    var tags: [String] = [] {
        didSet {
            guard tags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var shown: [String] { Array(tags.prefix(3)) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: shown.isEmpty ? 0 : 10 + CGFloat(shown.count - 1) * 6, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, tag) in shown.enumerated().reversed() {
            let rect = NSRect(x: CGFloat(i) * 6, y: (bounds.height - 10) / 2, width: 10, height: 10)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            (Tags.color(of: tag) ?? .tertiaryLabelColor).setFill()
            circle.fill()
            NSColor.controlBackgroundColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
    }
}
