import AppKit
import Quartz

private enum PanelPointer {
    static func location(for event: NSEvent, in window: NSWindow) -> NSPoint {
        // Use the event's captured position, not the current global pointer:
        // queued/coalesced drag events can arrive after the pointer has moved.
        if let point = event.cgEvent?.location { return NSPoint(x: point.x, y: -point.y) }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

enum PanelGeometry {
    static let minimumSize = NSSize(width: 600, height: 420)
    static let defaultSize = NSSize(width: 920, height: 660)

    static func frame(screen: NSRect, size: NSSize, origin: NSPoint? = nil) -> NSRect {
        let width = min(screen.width, max(minimumSize.width, size.width.isFinite ? size.width : defaultSize.width))
        let height = min(screen.height, max(minimumSize.height, size.height.isFinite ? size.height : defaultSize.height))
        let requested = origin ?? NSPoint(x: screen.midX - width / 2, y: screen.maxY - height)
        let x = requested.x.isFinite ? min(screen.maxX - width, max(screen.minX, requested.x)) : screen.midX - width / 2
        let y = requested.y.isFinite ? min(screen.maxY - height, max(screen.minY, requested.y)) : screen.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func resized(frame: NSRect, delta: NSPoint, screen: NSRect) -> NSRect {
        let horizontal = delta.x.isFinite ? delta.x : 0
        let vertical = delta.y.isFinite ? delta.y : 0
        let size = NSSize(width: min(screen.maxX - frame.minX, frame.width + horizontal), height: min(frame.maxY - screen.minY, frame.height - vertical))
        let bounded = Self.frame(screen: screen, size: size)
        return Self.frame(screen: screen, size: bounded.size, origin: NSPoint(x: frame.minX, y: frame.maxY - bounded.height))
    }
}

/// Only the header's non-control area initiates a move, leaving web controls,
/// text selection and scrolling untouched.
final class PanelDragHandle: NSView {
    var onDragEnd: (() -> Void)?
    private var initialOrigin = NSPoint.zero
    private var initialPoint = NSPoint.zero
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialOrigin = window.frame.origin
        initialPoint = PanelPointer.location(for: event, in: window)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, (window as? FloatingMonitorPanel)?.isExpanded != true else { return }
        let point = PanelPointer.location(for: event, in: window)
        window.setFrameOrigin(NSPoint(x: initialOrigin.x + point.x - initialPoint.x, y: initialOrigin.y + point.y - initialPoint.y))
    }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}

final class FloatingMonitorPanel: NSPanel {
    weak var filePreviewController: DiskFileInteractionController?
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { filePreviewController != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = filePreviewController; panel.delegate = filePreviewController }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    var onDismiss: (() -> Void)?
    var onFullscreenChange: ((Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private(set) var isExpanded = false
    private var savedFrame: NSRect?
    override func cancelOperation(_ sender: Any?) {
        if isExpanded { toggleFullScreen(sender) } else { onDismiss?() }
    }
    override func toggleFullScreen(_ sender: Any?) {
        if isExpanded {
            level = .normal
            if let screen { maxSize = screen.visibleFrame.size }
            if let savedFrame { setFrame(savedFrame, display: true) }
            savedFrame = nil
            isExpanded = false
        } else {
            guard let screen = screen ?? NSScreen.main else { return }
            savedFrame = frame
            isExpanded = true
            level = .normal
            maxSize = screen.visibleFrame.size
            setFrame(screen.visibleFrame, display: true)
        }
        onFullscreenChange?(isExpanded)
    }
}

final class PanelResizeHandle: NSView {
    var onResizeEnd: (() -> Void)?
    private var initialFrame = NSRect.zero
    private var initialPoint = NSPoint.zero
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.2
        for offset in [5.0, 9, 13] {
            path.move(to: NSPoint(x: bounds.width - offset, y: 4))
            path.line(to: NSPoint(x: bounds.width - 4, y: offset))
        }
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, (window as? FloatingMonitorPanel)?.isExpanded != true else { return }
        initialFrame = window.frame; initialPoint = PanelPointer.location(for: event, in: window)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen, (window as? FloatingMonitorPanel)?.isExpanded != true else { return }
        let point = PanelPointer.location(for: event, in: window)
        let delta = NSPoint(x: point.x - initialPoint.x, y: point.y - initialPoint.y)
        window.setFrame(PanelGeometry.resized(frame: initialFrame, delta: delta, screen: screen.visibleFrame), display: true)
    }
    override func mouseUp(with event: NSEvent) { onResizeEnd?() }
}
