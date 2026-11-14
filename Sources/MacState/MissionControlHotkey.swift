import AppKit
import ApplicationServices
import CoreGraphics

final class MissionControlHotkey {
    private(set) var status = "disabled" {
        didSet {
            guard status != oldValue else { return }
            let value = status
            DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
        }
    }
    var onStatusChange: ((String) -> Void)?
    var onOpenMissionControl: (() -> Void)?

    private(set) var isEnabled = false
    private let accessCheck: (Bool) -> Bool
    private let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var capturedTab = false

    init(accessCheck: @escaping (Bool) -> Bool = { requestAccess in
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: requestAccess] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }, createTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort? = { events, callback, userInfo in
        CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                          eventsOfInterest: events, callback: callback, userInfo: userInfo)
    }) {
        self.accessCheck = accessCheck
        self.createTap = createTap
    }

    deinit {
        retryTimer?.invalidate()
        stopTap()
    }

    func setEnabled(_ enabled: Bool, requestAccess: Bool) {
        isEnabled = enabled
        guard enabled else {
            retryTimer?.invalidate()
            retryTimer = nil
            stopTap()
            status = "disabled"
            return
        }
        defer { updateRetryTimer() }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            status = "active"
            return
        }
        stopTap()

        let events = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // The filtering tap is the capability we need. Do not reject an actual
        // working keyboard grant solely on a separate accessibility preflight.
        guard let eventTap = createTap(events, Self.handleEvent, Unmanaged.passUnretained(self).toOpaque()) else {
            status = accessCheck(requestAccess) ? "unavailable" : "permissionNeeded"
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            status = "unavailable"
            return
        }
        tap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        status = "active"
    }

    func refreshAccess() {
        guard isEnabled else { return }
        setEnabled(true, requestAccess: false)
    }

    private func updateRetryTimer() {
        guard isEnabled, status != "active" else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        // Permission changes do not reliably activate a nonactivating panel.
        // Poll only while waiting; an active tap adds no polling work.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAccess() }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTap() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        capturedTab = false
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MissionControlHotkey>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, keyCode == 48 {
            let flags = event.flags
            let commandOnly = flags.contains(.maskCommand)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskControl)
                && !flags.contains(.maskAlternate)
            guard commandOnly else { return Unmanaged.passUnretained(event) }
            capturedTab = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onOpenMissionControl?() }
            }
            return nil
        }
        if type == .keyUp, keyCode == 48, capturedTab {
            capturedTab = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
