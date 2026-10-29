import AppKit
import Testing
@testable import Foldera

@Suite @MainActor struct ResponsiveCommandBar {
    private func makeBar() -> (WrappingCommandBar, [ToolButton]) {
        let buttons = (0..<18).map { number in
            ToolButton(symbol: "folder", label: number % 4 == 0 ? "Command \(number)" : nil)
        }
        return (WrappingCommandBar(leading: Array(buttons.prefix(14)), trailing: Array(buttons.suffix(4))), buttons)
    }

    @Test(arguments: [300.0, 320, 640, 760, 800, 1100, 1440])
    func everyControlFitsWithoutOverlapping(width: Double) throws {
        let (bar, buttons) = makeBar()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        for button in buttons {
            #expect(button.frame.minX >= 0 && button.frame.maxX <= bar.bounds.width)
            #expect(button.frame.width >= 30 && button.frame.height >= 30)
        }
        for (index, button) in buttons.enumerated() {
            for other in buttons.dropFirst(index + 1) {
                #expect(!button.frame.intersects(other.frame))
            }
        }
    }

    @Test func resizingReusesControlsAndChangesRows() throws {
        let (bar, buttons) = makeBar()
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        let narrowRows = Set(buttons.map { $0.frame.minY }).count
        #expect(narrowRows > 1)
        bar.frame.size.width = 1440
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        #expect(Set(buttons.map { $0.frame.minY }).count == 1)
        #expect(buttons.allSatisfy { $0.superview === bar && !$0.isHidden })
    }
}
