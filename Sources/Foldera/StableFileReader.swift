import Foundation
import Darwin

/// A bounded read of a regular file. Checksums and comparisons must not
/// report success for a mixture of revisions, or wait for a named pipe.
final class StableFileReader {
    let handle: FileHandle
    let size: Int64
    private let url: URL
    private let original: FileOps.Revision

    init?(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        self.url = url
        size = info.st_size
        original = Self.revision(info)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Check both the opened inode and the current path. A rename over the
    /// path leaves the old descriptor readable but no longer names that file.
    var isCurrent: Bool {
        var opened = stat(), named = stat()
        return fstat(handle.fileDescriptor, &opened) == 0
            && stat(url.path, &named) == 0
            && Self.revision(opened) == original && Self.revision(named) == original
    }

    private static func revision(_ info: stat) -> FileOps.Revision {
        FileOps.Revision(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                         modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                         changed: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }

    deinit { try? handle.close() }
}
