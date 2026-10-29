import Foundation
import ImageIO

/// One file descriptor for EXIF inspection and ImageIO decoding. Random reads
/// avoid loading a whole photo into Data, and pread keeps callback positions
/// independent. The provider owns the file for as long as ImageIO needs it.
final class ThumbnailSource {
    private final class File {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }

        func read(into buffer: UnsafeMutableRawPointer, at offset: off_t, count: Int) -> Int {
            guard offset >= 0, count > 0 else { return 0 }
            var total = 0
            while total < count {
                let n = pread(descriptor, buffer.advanced(by: total), count - total, offset + off_t(total))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                total += n
            }
            return total
        }
    }

    let image: CGImageSource
    private let file: File

    init?(_ url: URL, openFile: (String) -> Int32 = { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }) {
        let descriptor = openFile(url.path)
        guard descriptor >= 0 else { return nil }
        let file = File(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return nil }
        let retained = Unmanaged.passRetained(file)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { context, buffer, position, count in
                guard let context else { return 0 }
                return Unmanaged<File>.fromOpaque(context).takeUnretainedValue().read(into: buffer, at: position, count: count)
            }, releaseInfo: { context in
                if let context { Unmanaged<File>.fromOpaque(context).release() }
            })
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: info.st_size, callbacks: &callbacks) else {
            retained.release()
            return nil
        }
        guard let image = CGImageSourceCreateWithDataProvider(provider, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0 else { return nil }
        self.file = file
        self.image = image
    }

    var hasJPEGThumbnail: Bool {
        var head = Data(count: 128 * 1024)
        let count = head.withUnsafeMutableBytes { bytes in file.read(into: bytes.baseAddress!, at: 0, count: bytes.count) }
        head.count = count
        return ImageFiles.jpegKeepsThumbnail(head)
    }
}
