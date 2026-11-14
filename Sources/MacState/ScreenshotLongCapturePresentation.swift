import AppKit
import CoreGraphics

/// WindowServer's on-screen list is front-to-back and uses coordinates whose
/// origin is the upper-left of the primary display. Our selection uses AppKit
/// screen coordinates (lower-left). Exclude all of MacState's own windows.
struct ScreenshotLongWindowCandidate {
    let pid: pid_t
    let frame: CGRect
    let layer: Int
}

enum ScreenshotLongTargetLocator {
    static func targetPID(under selection: CGRect, primaryScreenTop: CGFloat,
                          ownPID: pid_t, windows: [ScreenshotLongWindowCandidate]) -> pid_t? {
        guard selection.width > 0, selection.height > 0 else { return nil }
        let windowServerSelection = CGRect(x: selection.minX,
                                           y: primaryScreenTop - selection.maxY,
                                           width: selection.width, height: selection.height)
        let area = selection.width * selection.height
        // The first substantial non-MacState window is the user's target.
        // Ignore tiny overlapping popovers and desktop/status-bar windows.
        for window in windows where window.pid != ownPID && window.pid > 0 && window.layer == 0 {
            let intersection = window.frame.intersection(windowServerSelection)
            if !intersection.isNull && intersection.width * intersection.height >= area * 0.35 {
                return window.pid
            }
        }
        return nil
    }

    static func application(under selection: CGRect) -> NSRunningApplication? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates: [ScreenshotLongWindowCandidate] = raw.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let frameInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let x = frameInfo["X"] as? NSNumber,
                  let y = frameInfo["Y"] as? NSNumber,
                  let width = frameInfo["Width"] as? NSNumber,
                  let height = frameInfo["Height"] as? NSNumber else { return nil }
            return ScreenshotLongWindowCandidate(
                pid: pid_t(pid),
                frame: CGRect(x: x.doubleValue, y: y.doubleValue,
                              width: width.doubleValue, height: height.doubleValue),
                layer: layer)
        }
        // Screen 0 is the primary display. Using maxY across all displays
        // would give incorrect Quartz coordinates for displays above it.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        guard let pid = targetPID(under: selection, primaryScreenTop: primaryTop,
                                  ownPID: ProcessInfo.processInfo.processIdentifier, windows: candidates) else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)
    }
}

/// Only the MacState monitor panel is temporarily removed. Other applications
/// are untouched, and the panel is returned only if it was visible at start.
final class ScreenshotLongCapturePresentation {
    private let isPanelVisible: () -> Bool
    private let hidePanel: () -> Void
    private let restorePanelWindow: () -> Void
    private let targetApplication: (CGRect) -> NSRunningApplication?
    private let activateTarget: (NSRunningApplication) -> Void
    private(set) var isCapturing = false
    private var shouldRestorePanel = false

    /// Production path captures the single MacState panel weakly. This avoids
    /// retaining windows or manipulating an unrelated application's windows.
    convenience init(window: NSWindow) {
        self.init(
            isPanelVisible: { [weak window] in window?.isVisible == true },
            hidePanel: { [weak window] in window?.orderOut(nil) },
            restorePanelWindow: { [weak window] in
                guard let window else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            })
    }

    /// Effect-injected state transition, allowing regression tests without
    /// creating desktop windows or activating another application.
    init(isPanelVisible: @escaping () -> Bool,
         hidePanel: @escaping () -> Void,
         restorePanelWindow: @escaping () -> Void,
         targetApplication: @escaping (CGRect) -> NSRunningApplication? = ScreenshotLongTargetLocator.application,
         activateTarget: @escaping (NSRunningApplication) -> Void = { app in
             _ = app.activate(options: .activateIgnoringOtherApps)
         }) {
        self.isPanelVisible = isPanelVisible
        self.hidePanel = hidePanel
        self.restorePanelWindow = restorePanelWindow
        self.targetApplication = targetApplication
        self.activateTarget = activateTarget
    }

    func begin(selection: CGRect) {
        guard !isCapturing else { return }
        isCapturing = true
        shouldRestorePanel = isPanelVisible()
        // Determine the target while the original window ordering is intact.
        let target = targetApplication(selection)
        if shouldRestorePanel { hidePanel() }
        if let target { activateTarget(target) }
    }

    func end() {
        guard isCapturing else { return }
        isCapturing = false
        if shouldRestorePanel { restorePanelWindow() }
        shouldRestorePanel = false
    }
}
