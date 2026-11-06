import AppKit
import ImageIO

/// Encoded bytes alone do not bound a raster's memory use. Inspect dimensions
/// without caching pixels, and divide so hostile dimensions cannot overflow.
enum ImageDecodeLimits {
    static let pixels = 32_000_000
    static let dimension = 8192
    static let frames = 500
    static let animationPixels = 100_000_000

    static func size(_ source: CGImageSource, at index: Int) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index,
            [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func fits(_ source: CGImageSource, pixelLimit: Int = pixels,
                     totalLimit: Int = animationPixels, frameLimit: Int = frames) -> Bool {
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= frameLimit else { return false }
        var widest = 0, tallest = 0
        for index in 0..<count {
            guard let size = size(source, at: index), size.width <= dimension, size.height <= dimension,
                  size.width <= pixelLimit / size.height else { return false }
            widest = max(widest, size.width)
            tallest = max(tallest, size.height)
        }
        // Delta frames can be tiny while AppKit retains a composited canvas
        // for each. Budget every frame at the largest canvas dimensions.
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            widest = max(widest, properties[kCGImagePropertyPixelWidth] as? Int ?? 0)
            tallest = max(tallest, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        return widest <= dimension && tallest <= dimension && widest <= pixelLimit / tallest &&
            count <= totalLimit / widest / tallest
    }

    static func thumbnailDimension(width: Double, height: Double, requested: Int) -> Int {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 1 }
        let longest = max(width, height)
        let scale = min(1, sqrt(Double(pixels) / width / height))
        return max(1, Int(min(Double(max(1, min(requested, dimension))), floor(longest * scale))))
    }

    /// Copy Image hands over the picture itself, so it gets a larger budget
    /// than the screen: a medium-format photo still goes at full size, but a
    /// hostile gigapixel PNG can't take gigabytes for the bitmap and its TIFF.
    static let clipboardPixels = 100_000_000
    static let clipboardDimension = 32_768

    /// The scale that keeps `width` × `height` within both limits; 1 when it fits.
    /// Doubles throughout, so absurd sizes can't overflow or trap.
    static func scale(width: Double, height: Double, pixelLimit: Int = clipboardPixels,
                      dimensionLimit: Int = clipboardDimension) -> Double {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return 0 }
        return min(1, sqrt(Double(max(pixelLimit, 1)) / width / height),
                   Double(max(dimensionLimit, 1)) / max(width, height))
    }

    /// The longest side to decode a clipboard picture at, or nil when the
    /// whole picture fits the budget and is decoded as it is.
    static func clipboardSide(width: Int, height: Int, pixelLimit: Int = clipboardPixels) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let factor = scale(width: Double(width), height: Double(height), pixelLimit: pixelLimit)
        guard factor < 1 else { return nil }
        return max(1, Int((Double(max(width, height)) * factor).rounded(.down)))
    }

    /// A vector picture (SVG) drawn into a bitmap of exactly its natural size,
    /// or smaller when that is beyond the budget. NSImage's own TIFF would be
    /// made at whatever size the file declares, and at the screen's scale.
    static func rasterized(_ image: NSImage, pixelLimit: Int = clipboardPixels) -> CGImage? {
        let size = image.size
        let factor = scale(width: Double(size.width), height: Double(size.height), pixelLimit: pixelLimit)
        guard factor > 0 else { return nil }
        let width = max(1, Int((Double(size.width) * factor).rounded(.down)))
        let height = max(1, Int((Double(size.height) * factor).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        return context.makeImage()
    }
}
