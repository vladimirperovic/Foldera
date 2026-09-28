// Draws the app icon — a plain yellow folder, as Windows' has always been —
// into an .iconset folder for iconutil. Run by build.sh:
//   swift Icon/icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A closed path through `points` with every corner rounded by its radius.
func rounded(_ points: [(CGFloat, CGFloat, CGFloat)], scale s: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let p = points.map { CGPoint(x: $0.0 * s, y: $0.1 * s) }
    let last = p[p.count - 1], first = p[0]
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for i in p.indices {
        path.addArc(tangent1End: p[i], tangent2End: p[(i + 1) % p.count], radius: points[i].2 * s)
    }
    path.closeSubpath()
    return path
}

func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: [])
    ctx.restoreGState()
}

/// "F" from Cormorant Garamond SemiBold (SIL Open Font License), in font
/// units: 625 tall, from x 34 to 436. Kept as an outline so building the icon
/// doesn't need the font installed.
let letterF: [(String, [CGFloat])] = [
    ("m", [36.8, 0.0]), ("q", [34.0, 0.0, 34.0, 6.0]), ("q", [34.0, 12.0, 36.8, 12.0]), ("q", [71.8, 12.0, 89.0,
    17.0]), ("q", [106.2, 22.0, 112.0, 37.0]), ("q", [117.8, 52.0, 117.8, 81.0]), ("l", [117.8, 544.0]), ("q",
    [117.8, 573.0, 112.4, 587.5]), ("q", [107.0, 602.0, 90.9, 607.5]), ("q", [74.8, 613.0, 41.8, 613.0]), ("q",
    [39.1, 613.0, 39.1, 619.0]), ("q", [39.1, 625.0, 41.8, 625.0]), ("l", [458.1, 625.0]), ("q", [467.8, 625.0,
    467.8, 616.0]), ("l", [469.8, 486.3]), ("q", [469.8, 484.0, 464.7, 483.3]), ("q", [459.6, 482.6, 458.1,
    485.6]), ("q", [446.5, 542.7, 411.6, 570.7]), ("q", [376.6, 598.8, 319.5, 598.8]), ("l", [278.8, 598.8]),
    ("q", [242.2, 598.8, 227.5, 586.0]), ("q", [212.8, 573.3, 212.8, 543.0]), ("l", [212.8, 85.0]), ("q",
    [212.8, 55.0, 221.0, 39.5]), ("q", [229.1, 24.0, 253.2, 18.0]), ("q", [277.3, 12.0, 324.8, 12.0]), ("q",
    [327.0, 12.0, 327.0, 6.0]), ("q", [327.0, 0.0, 324.8, 0.0]), ("q", [291.3, 0.0, 252.4, 1.0]), ("q", [213.4,
    2.0, 162.9, 2.0]), ("q", [128.0, 2.0, 95.1, 1.0]), ("q", [62.2, 0.0, 36.8, 0.0]), ("z", []), ("m", [407.8,
    215.0]), ("q", [407.8, 256.4, 379.5, 278.4]), ("q", [351.1, 300.4, 293.2, 300.4]), ("l", [167.5, 300.4]),
    ("l", [167.5, 325.9]), ("l", [295.0, 325.9]), ("q", [352.1, 325.9, 379.5, 345.5]), ("q", [406.8, 365.2,
    406.8, 400.7]), ("q", [406.8, 402.7, 412.8, 402.7]), ("q", [418.8, 402.7, 418.8, 400.7]), ("q", [418.8,
    368.1, 418.3, 350.3]), ("q", [417.8, 332.5, 417.8, 313.0]), ("q", [417.8, 288.8, 418.8, 265.5]), ("q",
    [419.8, 242.2, 419.8, 215.0]), ("q", [419.8, 212.3, 413.8, 212.3]), ("q", [407.8, 212.3, 407.8, 215.0]),
    ("z", [])
]

func letterPath(at origin: CGPoint, scale k: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func p(_ v: [CGFloat], _ i: Int) -> CGPoint { CGPoint(x: origin.x + v[i] * k, y: origin.y + v[i + 1] * k) }
    for (op, v) in letterF {
        switch op {
        case "m": path.move(to: p(v, 0))
        case "l": path.addLine(to: p(v, 0))
        case "q": path.addQuadCurve(to: p(v, 2), control: p(v, 0))
        case "c": path.addCurve(to: p(v, 4), control1: p(v, 0), control2: p(v, 2))
        default: path.closeSubpath()
        }
    }
    return path
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)

    // One soft shadow under the whole folder, as macOS draws under
    // free-standing icons.
    ctx.setShadow(offset: CGSize(width: 0, height: -0.012 * s), blur: 0.035 * s, color: rgb(0x000000, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // The back, with its tab on the left.
    let back = rounded([
        (0.10, 0.18, 0.05), (0.10, 0.80, 0.035), (0.39, 0.80, 0.025), (0.45, 0.73, 0.025),
        (0.90, 0.73, 0.04), (0.90, 0.18, 0.05),
    ], scale: s)
    fill(ctx, back, top: rgb(0xF2A81C), bottom: rgb(0xCC7A06), from: 0.18 * s, to: 0.80 * s)

    // Two sheets of paper inside, the one behind a little askew.
    ctx.saveGState()
    ctx.translateBy(x: 0.5 * s, y: 0.5 * s)
    ctx.rotate(by: 0.045)
    ctx.translateBy(x: -0.5 * s, y: -0.5 * s)
    ctx.setFillColor(rgb(0xE9EDF2))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0.17 * s, y: 0.36 * s, width: 0.64 * s, height: 0.34 * s),
                       cornerWidth: 0.02 * s, cornerHeight: 0.02 * s, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0.16 * s, y: 0.36 * s, width: 0.66 * s, height: 0.33 * s),
                       cornerWidth: 0.02 * s, cornerHeight: 0.02 * s, transform: nil))
    ctx.fillPath()

    // The front, which casts a faint shadow on the paper behind it.
    let front = CGPath(roundedRect: CGRect(x: 0.10 * s, y: 0.18 * s, width: 0.80 * s, height: 0.465 * s),
                       cornerWidth: 0.05 * s, cornerHeight: 0.05 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.004 * s), blur: 0.02 * s, color: rgb(0x8A5300, 0.35))
    ctx.addPath(front)
    ctx.setFillColor(rgb(0xFFC22E))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, front, top: rgb(0xFFD652), bottom: rgb(0xF7AE1E), from: 0.18 * s, to: 0.645 * s)

    // A large F pressed into the front, barely there: a lit lower edge, a
    // shaded upper one, and the letter itself the colour of the folder.
    if px >= 64 {
        let k = 0.29 * s / 625
        let origin = CGPoint(x: 0.5 * s - 235 * k, y: 0.265 * s)
        let letter = letterPath(at: origin, scale: k)
        ctx.saveGState()
        ctx.addPath(front)
        ctx.clip()
        for (dy, color) in [(-0.006, rgb(0xFFF3C4, 0.75)), (0.005, rgb(0x9C5F00, 0.22))] {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dy * s)
            ctx.addPath(letter)
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.restoreGState()
        }
        fill(ctx, letter, top: rgb(0xFFD24A), bottom: rgb(0xF8B127), from: 0.18 * s, to: 0.645 * s)
        ctx.restoreGState()
    }

    // A lit top edge on the front.
    if px >= 32 {
        ctx.saveGState()
        ctx.addPath(front)
        ctx.clip()
        ctx.setFillColor(rgb(0xFFF1B8, 0.9))
        ctx.fill(CGRect(x: 0.10 * s, y: 0.628 * s, width: 0.80 * s, height: 0.017 * s))
        ctx.restoreGState()
    }

    ctx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! draw(px).write(to: out.appendingPathComponent("\(name).png"))
}
