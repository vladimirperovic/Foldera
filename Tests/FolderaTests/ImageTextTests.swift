import AppKit
import Testing
@testable import Foldera

@Suite(.serialized) @MainActor struct ImageTextRecognition {
    private func picture(text: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaOCR-\(UUID().uuidString).png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 600,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 600).fill()
        if text {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]
            ("Foldera OCR 12345" as NSString).draw(at: NSPoint(x: 80, y: 380), withAttributes: attributes)
            ("Invoice number 67890" as NSString).draw(at: NSPoint(x: 80, y: 230), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func recognizesActualImageTextInReadingOrder() throws {
        let image = try picture(text: true)
        defer { try? FileManager.default.removeItem(at: image) }
        let text = try ImageText.recognize(image)
        #expect(text.contains("Foldera"))
        let first = try #require(text.range(of: "12345"))
        let second = try #require(text.range(of: "67890"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func blankImagesReturnNoTextAndInvalidImagesReportAnError() throws {
        let image = try picture(text: false)
        defer { try? FileManager.default.removeItem(at: image) }
        #expect(try ImageText.recognize(image).isEmpty)
        try "not an image".write(to: image, atomically: true, encoding: .utf8)
        #expect(throws: OpError.self) { try ImageText.recognize(image) }
    }

    @Test func cancellationStopsBeforeOpeningTheImage() {
        let cancelled = CancelFlag()
        cancelled.set()
        #expect(throws: CancellationError.self) {
            try ImageText.recognize(URL(fileURLWithPath: "/does-not-exist.png"), cancelled: cancelled)
        }
    }

    @Test(arguments: [false, true]) func copySheetWritesTextUnlessCancelled(_ cancel: Bool) async throws {
        _ = NSApplication.shared
        let image = try picture(text: true)
        defer { try? FileManager.default.removeItem(at: image) }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("keep this", forType: .string)
        defer { pasteboard.releaseGlobally() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        ImageTextCopy.start(image, in: window, pasteboard: pasteboard)
        if cancel { window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn) }
        for _ in 0..<400 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.attachedSheet == nil)
        let copied = pasteboard.string(forType: .string) ?? ""
        #expect(cancel ? copied == "keep this" : copied.contains("12345"))
    }
}
