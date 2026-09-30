import AppKit
import ImageIO
import Vision

/// Vision runs locally. Decode one upright frame with a bounded memory cost.
enum ImageText {
    static func recognize(_ url: URL, request: VNRecognizeTextRequest = VNRecognizeTextRequest(),
                          cancelled: CancelFlag = CancelFlag()) throws -> String {
        if cancelled.isSet { throw CancellationError() }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw OpError("This image couldn't be read for text recognition.")
        }
        if cancelled.isSet { throw CancellationError() }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        if cancelled.isSet { throw CancellationError() }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A cancellable sheet tied to the requested image; closing it leaves the clipboard alone.
final class ImageTextCopy {
    private let request = VNRecognizeTextRequest()
    private let cancelled = CancelFlag()
    private let alert = NSAlert()
    private let pasteboard: NSPasteboard
    private weak var parent: NSWindow?
    private var result: Result<String, Error>?

    private init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    static func start(_ url: URL, in window: NSWindow, pasteboard: NSPasteboard = .general) {
        guard window.attachedSheet == nil else { return }
        let job = ImageTextCopy(pasteboard: pasteboard)
        job.run(url, in: window)
    }

    private func run(_ url: URL, in window: NSWindow) {
        parent = window
        alert.messageText = "Reading text from image…"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 220, height: 16))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .OK, !cancelled.isSet, let result, let parent, parent.isVisible else {
                cancelled.set()
                request.cancel()
                return
            }
            switch result {
            case .success(let text) where !text.isEmpty:
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            case .success:
                let empty = NSAlert()
                empty.messageText = "No text found in this image."
                empty.informativeText = "Try a clearer image with larger, readable text."
                empty.beginSheetModal(for: parent)
            case .failure(let error):
                NSAlert(error: error).beginSheetModal(for: parent)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let recognized = Result { try ImageText.recognize(url, request: request, cancelled: cancelled) }
            DispatchQueue.main.async { [self] in
                guard !cancelled.isSet, let parent, parent.attachedSheet === alert.window else { return }
                result = recognized
                parent.endSheet(alert.window, returnCode: .OK)
            }
        }
    }
}

extension ExplorerTab {
    @objc func copyTextFromImage(_ sender: Any?) {
        guard selectedItems.count == 1, let url = selectedURLs.first, ImageFiles.isImage(url), let window else { return }
        ImageTextCopy.start(url, in: window)
    }
}
