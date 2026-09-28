// Draws the background of the disk image window: an arrow from Foldera to
// Applications and one line saying what to do. Run by build.sh dmg:
//   swift Icon/dmg-background.swift <folder>   (writes background.tiff there)
// The window is 660 × 400 points; the icons sit at x 165 and 495, y 185.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let width: CGFloat = 660, height: CGFloat = 400

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Finder's own coordinates run from the top; these run from the bottom.
    func y(_ fromTop: CGFloat) -> CGFloat { height - fromTop }

    NSGradient(starting: NSColor(white: 0.985, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The arrow, a gentle arc between the two icons.
    let ink = NSColor(white: 0.62, alpha: 1)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: y(185)))
    arrow.curve(to: NSPoint(x: 398, y: y(185)), controlPoint1: NSPoint(x: 300, y: y(160)), controlPoint2: NSPoint(x: 356, y: y(160)))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    ink.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: y(172)))
    head.line(to: NSPoint(x: 400, y: y(186)))
    head.line(to: NSPoint(x: 380, y: y(192)))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let line = NSAttributedString(string: "Drag Foldera to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.40, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    line.draw(in: NSRect(x: 0, y: y(318), width: width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// One TIFF with both sizes, so the window is sharp on Retina screens too.
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [draw(scale: 1), draw(scale: 2)], using: .lzw, factor: 0)!
try! tiff.write(to: out.appendingPathComponent("background.tiff"))
