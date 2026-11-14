import Testing
import AppKit
@testable import MacState

@Test func floatingPanelCentersBelowTheMenuBar() {
    let screen = NSRect(x: 0, y: 40, width: 1440, height: 836)
    let frame = PanelGeometry.frame(screen: screen, size: PanelGeometry.defaultSize)
    #expect(frame.midX == screen.midX)
    #expect(frame.maxY == screen.maxY)
    #expect(frame.size == PanelGeometry.defaultSize)
    #expect(screen.contains(frame))
}

@Test func floatingPanelCentersOnOtherScreensAndClampsInvalidSizes() {
    let secondScreen = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
    let second = PanelGeometry.frame(screen: secondScreen, size: PanelGeometry.defaultSize)
    #expect(second.midX == secondScreen.midX)
    #expect(second.maxY == secondScreen.maxY)
    let huge = PanelGeometry.frame(screen: secondScreen, size: NSSize(width: 5000, height: 5000))
    #expect(huge == secondScreen)
    let invalid = PanelGeometry.frame(screen: secondScreen, size: NSSize(width: CGFloat.nan, height: CGFloat.infinity))
    #expect(invalid.size == PanelGeometry.defaultSize)
    let tinyScreen = NSRect(x: 100, y: -200, width: 500, height: 300)
    #expect(PanelGeometry.frame(screen: tinyScreen, size: NSSize(width: 1, height: 1)) == tinyScreen)
}

@Test func floatingPanelResizesKeepingItsTopLeftAfterDragging() {
    let screen = NSRect(x: 0, y: 40, width: 1440, height: 836)
    let initial = PanelGeometry.frame(screen: screen, size: PanelGeometry.defaultSize)
    let resized = PanelGeometry.resized(frame: initial, delta: NSPoint(x: -100, y: 100), screen: screen)
    #expect(resized.size == NSSize(width: 820, height: 560))
    #expect(resized.minX == initial.minX)
    #expect(resized.maxY == initial.maxY)
    #expect(resized.maxX == initial.maxX - 100)
    #expect(resized.minY == initial.minY + 100)
    let huge = PanelGeometry.resized(frame: initial, delta: NSPoint(x: 5000, y: -5000), screen: screen)
    #expect(huge.minX == initial.minX)
    #expect(huge.maxX == screen.maxX)
    #expect(huge.maxY == initial.maxY)
    #expect(huge.minY == screen.minY)
    let small = PanelGeometry.resized(frame: initial, delta: NSPoint(x: -5000, y: 5000), screen: screen)
    #expect(small.size == PanelGeometry.minimumSize)
    #expect(screen.contains(small))
}

@Test @MainActor func floatingPanelSupportsInputAndEscapeDismissal() {
    let panel = FloatingMonitorPanel(contentRect: NSRect(origin: .zero, size: PanelGeometry.defaultSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    #expect(panel.canBecomeKey)
    #expect(!panel.styleMask.contains(.resizable))
    var dismissed = false
    panel.onDismiss = { dismissed = true }
    panel.cancelOperation(nil)
    #expect(dismissed)
}

@Test func floatingPanelRestoresMovedPositionAndClampsDisconnectedScreens() {
    let screen = NSRect(x: 0, y: 40, width: 1440, height: 836)
    let origin = NSPoint(x: 80, y: 100)
    #expect(PanelGeometry.frame(screen: screen, size: PanelGeometry.defaultSize, origin: origin).origin == origin)
    let offscreen = PanelGeometry.frame(screen: screen, size: PanelGeometry.defaultSize, origin: NSPoint(x: -4000, y: 5000))
    #expect(screen.contains(offscreen))
    #expect(offscreen.minX == screen.minX)
    #expect(offscreen.maxY == screen.maxY)
}

@Test @MainActor func floatingPanelDragUsesCapturedEventsEvenWhenTheGlobalPointerIsElsewhere() throws {
    let panel = FloatingMonitorPanel(contentRect: NSRect(x: 100, y: 100, width: 600, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let handle = PanelDragHandle(frame: NSRect(x: 0,y: 0,width: 200,height: 30))
    panel.contentView = handle
    defer { panel.contentView = nil }
    func event(_ type: CGEventType, _ point: CGPoint) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
        return try #require(NSEvent(cgEvent: cg))
    }
    let initial = panel.frame.origin
    var remembered = false
    handle.onDragEnd = { remembered = true }
    handle.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
    handle.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 160, y: 140)))
    handle.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 160, y: 140)))
    #expect(panel.frame.origin == NSPoint(x: initial.x + 60, y: initial.y - 40))
    #expect(remembered)
}
