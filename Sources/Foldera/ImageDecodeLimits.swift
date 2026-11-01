import Foundation
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
        var remaining = totalLimit
        for index in 0..<count {
            guard let size = size(source, at: index), size.width <= dimension, size.height <= dimension,
                  size.width <= min(pixelLimit, remaining) / size.height else { return false }
            remaining -= size.width * size.height
        }
        return true
    }

    static func thumbnailDimension(width: Double, height: Double, requested: Int) -> Int {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 1 }
        let longest = max(width, height)
        let scale = min(1, sqrt(Double(pixels) / width / height))
        return max(1, Int(min(Double(max(1, min(requested, dimension))), floor(longest * scale))))
    }
}
