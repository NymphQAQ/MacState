import AppKit
import Carbon

struct ScreenshotShortcut: Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    var enabled = true
}
final class ScreenshotHotkeys {
    static let modes = ["region", "window", "screen"]
    static var defaults: [String: ScreenshotShortcut] {
        ["region": .init(keyCode:18,modifiers:6144,label:"⌃⌥1"), "window": .init(keyCode:19,modifiers:6144,label:"⌃⌥2"), "screen": .init(keyCode:20,modifiers:6144,label:"⌃⌥3")]
    }
    var onCapture: ((String) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4D535343, (1...3).contains(id.id) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ScreenshotHotkeys>.fromOpaque(context).takeUnretainedValue()
            owner.onCapture?(ScreenshotHotkeys.modes[Int(id.id)-1]); return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func stop() { for ref in refs { UnregisterEventHotKey(ref) }; refs.removeAll() }
    func install(_ shortcuts: [String: ScreenshotShortcut]) -> String {
        stop()
        var used = Set<String>(), errors: [String] = []
        for (index,mode) in Self.modes.enumerated() {
            guard let shortcut = shortcuts[mode], shortcut.enabled else { continue }
            let modifiers = shortcut.modifiers & UInt32(cmdKey | shiftKey | optionKey | controlKey)
            guard shortcut.keyCode <= 126, modifiers & UInt32(cmdKey | optionKey | controlKey) != 0,
                  used.insert("\(shortcut.keyCode):\(modifiers)").inserted else { errors.append("\(shortcut.label)：无效或重复"); continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, modifiers, EventHotKeyID(signature:0x4D535343,id:UInt32(index+1)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { errors.append("\(shortcut.label)：被系统或其他应用占用（\(status)）") }
        }
        return errors.joined(separator:"；")
    }
    deinit { stop(); if let handler { RemoveEventHandler(handler) } }
}
