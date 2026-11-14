import AppKit
import WebKit
import Testing
@testable import MacState

private final class GlassMessageCapture: NSObject, WKScriptMessageHandler {
    var layout: GlassLayout?
    var failures: [String] = []
    var savedSettings: [Settings] = []
    var permissionRequests = 0
    var menuPreviewVisibility: [Bool] = []
    var fileActions: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "menuPreview", let visible = body["visible"] as? Bool { menuPreviewVisibility.append(visible) }
        if body["action"] as? String == "addDiskOpenApplication" { fileActions.append("add") }
        if body["action"] as? String == "enableDesktopLens" { permissionRequests += 1 }
        if body["action"] as? String == "saveSettings", let value = body["settings"],
           let data = try? JSONSerialization.data(withJSONObject: value),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) { savedSettings.append(settings) }
        if body["action"] as? String == "glassError" { failures.append(body["message"] as? String ?? "Unknown JavaScript error") }
        guard body["action"] as? String == "glassLayout", let value = body["layout"], let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        do { layout = try JSONDecoder().decode(GlassLayout.self, from: data) }
        catch { failures.append(String(describing: error)) }
    }
}

@Test @MainActor func nativeGlassTracksWebControlsAndTransparencyEndpoints() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let capture = GlassMessageCapture()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(capture, name: "macstate")
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: configuration)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "macstate"); window.contentView = nil }
    view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState === 'complete' && typeof window.setComponentGlassEnabled === 'function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded)
    _ = try await view.evaluateJavaScript("window.addEventListener('error',event=>window.webkit.messageHandlers.macstate.postMessage({action:'glassError',message:event.message}));window.setComponentGlassEnabled(true); window.openSettings();selectSettingsCategory('appearance')")
    for _ in 0..<100 {
        if capture.layout?.components.contains(where: { $0.id == "#theme" }) == true { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let layout = try #require(capture.layout, "Geometry bridge: \(capture.failures)")
    #expect(layout.components.count > 10)
    #expect(layout.dragRegion != nil)
    #expect(layout.components.allSatisfy { $0.rectangles(in: view.bounds) != nil })
    window.setContentSize(NSSize(width: 920, height: 420))
    view.frame.size = NSSize(width: 920, height: 420)
    _ = try await view.evaluateJavaScript("document.getElementById('theme').scrollIntoView({block:'start'})")
    for _ in 0..<100 {
        if capture.layout?.components.contains(where: { $0.id == "#theme" }) == true, capture.layout?.dragRegion == nil { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let scrolled = try #require(capture.layout)
    #expect(scrolled.components.contains { $0.id == "#theme" })
    #expect(scrolled.dragRegion == nil, "An offscreen header must not intercept controls at the top of a scrolled page")
    window.setContentSize(NSSize(width: 920, height: 660))
    view.frame.size = NSSize(width: 920, height: 660)
    let initial = try #require(try await view.evaluateJavaScript("({off:!document.getElementById('native-glass-enabled').checked,transparency:document.getElementById('glass-opacity').value,noGrant:document.getElementById('enable-desktop-lens')===null})") as? [String:Any])
    #expect(initial["off"] as? Bool == true)
    #expect(initial["transparency"] as? String == "0")
    #expect(initial["noGrant"] as? Bool == true)
    _ = try await view.evaluateJavaScript("document.getElementById('native-glass-enabled').click();window.receiveLensStatus('native')")
    for _ in 0..<100 {
        if capture.savedSettings.last?.nativeGlassEnabled == true { break }
        try await Task.sleep(nanoseconds:20_000_000)
    }
    #expect(capture.savedSettings.last?.nativeGlassEnabled == true)
    #expect(capture.permissionRequests == 0)
    #expect(try await view.evaluateJavaScript("document.getElementById('lens-status').textContent.includes('原生玻璃增强已开启')") as? Bool == true)
    _ = try await view.evaluateJavaScript("document.getElementById('native-glass-enabled').click();window.receiveLensStatus('native')")
    for _ in 0..<100 {
        if capture.savedSettings.last?.nativeGlassEnabled == false { break }
        try await Task.sleep(nanoseconds:20_000_000)
    }
    #expect(capture.savedSettings.last?.nativeGlassEnabled == false)
    #expect(capture.permissionRequests == 0, "Neither native glass mode requests screen recording")
    #expect(try await view.evaluateJavaScript("document.getElementById('lens-status').textContent.includes('低开销模式')") as? Bool == true)
    // Endpoints exercise the actual input event, saved density and text label.
    for (transparency, opacity) in [(0, 1.0), (100, 0.0)] {
        let result = try #require(try await view.evaluateJavaScript("(()=>{const s=document.getElementById('glass-opacity');s.value=\(transparency);s.dispatchEvent(new Event('input',{bubbles:true}));return {label:document.getElementById('glass-opacity-value').textContent,opacity:settings.glassOpacity}})()") as? [String: Any])
        #expect(result["label"] as? String == "\(transparency)%")
        #expect(result["opacity"] as? Double == opacity)
    }
    let initialIDs = Set(layout.components.map(\.id))
    _ = try await view.evaluateJavaScript("window.openOverview()")
    for _ in 0..<100 {
        if capture.layout?.components.contains(where: { $0.id == "#theme" }) == false { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let overview = try #require(capture.layout)
    #expect(Set(overview.components.map(\.id)) != initialIDs)
    #expect(!overview.components.contains { $0.id == "#theme" })
    _ = try await view.evaluateJavaScript("window.setComponentGlassEnabled(false)")
    for _ in 0..<100 {
        if capture.layout?.components.isEmpty == true, capture.layout?.dragRegion != nil { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(capture.layout?.components.isEmpty == true, "Economical mode sends no per-card material geometry")
    #expect(capture.layout?.dragRegion != nil, "Window dragging remains available without component effects")
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('[data-native-glass]').length===0 && document.body.classList.contains('economical-glass')") as? Bool == true)
    _ = try await view.evaluateJavaScript("""
    window.openSettings();
    document.getElementById('interval').value='5';document.getElementById('interval').dispatchEvent(new Event('change',{bubbles:true}));
    document.getElementById('history').value='300';document.getElementById('history').dispatchEvent(new Event('change',{bubbles:true}));
    selectSettingsCategory('appearance');
    document.getElementById('theme').value='light';document.getElementById('theme').dispatchEvent(new Event('change',{bubbles:true}));
    document.getElementById('compact').click();
    selectSettingsCategory('menu');
    document.getElementById('menu-column-spacing').value='10';document.getElementById('menu-column-spacing').dispatchEvent(new Event('input',{bubbles:true}));
    const size=document.querySelector('#name-style [data-style-field=size]');size.value='13';size.dispatchEvent(new Event('input',{bubbles:true}));
    """)
    for _ in 0..<100 {
        if capture.savedSettings.last?.menuNameStyle.size == 13, capture.menuPreviewVisibility.last == true { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let categorizedSettings = try #require(capture.savedSettings.last)
    #expect(categorizedSettings.interval == 5)
    #expect(categorizedSettings.historySeconds == 300)
    #expect(categorizedSettings.theme == "light")
    #expect(categorizedSettings.compact)
    #expect(categorizedSettings.menuColumnSpacing == 10)
    #expect(categorizedSettings.menuNameStyle.size == 13)
    #expect(capture.menuPreviewVisibility.last == true)
    _ = try await view.evaluateJavaScript("selectSettingsCategory('files');document.getElementById('file-add-application').click()")
    for _ in 0..<100 {
        if capture.fileActions.last == "add", capture.menuPreviewVisibility.last == false { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(capture.fileActions == ["add"])
    #expect(capture.menuPreviewVisibility.last == false, "Hidden status-bar settings do not request preview rendering")
    #expect(capture.permissionRequests == 0)
}
