import AppKit
import NetFS

/// Go › Connect to Server (⌘K): smb://, afp://, nfs:// and WebDAV shares,
/// mounted by macOS with its own sign-in window, then opened here.
enum Servers {
    private static let key = "recentServers"

    static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: key) }
    }

    /// The address box. A bare name or IP address means SMB, as with a Windows share.
    static func ask() -> URL? {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Type a server address, for example smb://nas.local/Photos or 192.168.1.10."
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.addItems(withObjectValues: recent)
        field.stringValue = recent.first ?? "smb://"
        field.completes = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return address(field.stringValue)
    }

    static func address(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "smb://" else { return nil }
        // \\server\share, the Windows way of writing it.
        if text.hasPrefix("\\\\") { text = "smb://" + text.dropFirst(2).replacingOccurrences(of: "\\", with: "/") }
        if !text.contains("://") { text = "smb://" + text }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// Mounts the share; `done` gets where it appeared (under /Volumes).
    static func mount(_ url: URL, done: @escaping (Result<URL, Error>) -> Void) {
        recent = [url.absoluteString] + recent.filter { $0 != url.absoluteString }
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "AllowUI" // kNAUIOptionKey: kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &request, .main) { status, _, mountpoints in
            if status == 0, let path = (mountpoints as? [String])?.first {
                done(.success(URL(fileURLWithPath: path, isDirectory: true)))
            } else if status == EEXIST, let mounted = alreadyMounted(url) {
                done(.success(mounted))
            } else if status == ECANCELED || status == -128 {
                done(.failure(CancellationError()))
            } else {
                done(.failure(OpError("Foldera couldn't connect to “\(url.host ?? url.absoluteString)” (error \(status)).")))
            }
        }
        if status != 0 {
            done(.failure(OpError("Foldera couldn't connect to “\(url.host ?? url.absoluteString)” (error \(status)).")))
        }
    }

    /// The mounted volume for a share that was already connected.
    private static func alreadyMounted(_ url: URL) -> URL? {
        let share = url.lastPathComponent
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        return volumes.first {
            let remote = try? $0.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting
            return remote?.host == url.host && (share.isEmpty || remote?.lastPathComponent == share)
        }
    }
}
