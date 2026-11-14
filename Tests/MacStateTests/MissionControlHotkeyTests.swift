import AppKit
import WebKit
import Testing
@testable import MacState

private final class HotkeySettingsCapture: NSObject, WKScriptMessageHandler {
    var saved: Settings?
    var readyCount = 0
    var openedAccessSettings = 0

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" { readyCount += 1; return }
        if body["action"] as? String == "openMissionControlAccessSettings" { openedAccessSettings += 1; return }
        guard body["action"] as? String == "saveSettings",
              let value = body["settings"], let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        saved = try? JSONDecoder().decode(Settings.self, from: data).validated()
    }
}

@Test @MainActor func missionControlPreferenceRestoresInMiscAndRoundTrips() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let capture = HotkeySettingsCapture()
    let config = WKWebViewConfiguration()
    config.userContentController.add(capture, name: "macstate")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: config)
    defer { config.userContentController.removeScriptMessageHandler(forName: "macstate") }
    var saved = Settings()
    saved.commandTabOpensMissionControl = true
    let data = try JSONEncoder().encode(saved.validated())
    let restored = try JSONDecoder().decode(Settings.self, from: data).validated()
    #expect(restored.commandTabOpensMissionControl)
    let json = try #require(String(data: data, encoding: .utf8))

    for launch in 0..<2 {
        let previousReady = capture.readyCount
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        var loaded = false
        for _ in 0..<200 {
            loaded = (try? await web.evaluateJavaScript("document.readyState==='complete' && typeof window.receiveSettings==='function'")) as? Bool == true
            if loaded && capture.readyCount > previousReady { break }
            loaded = false
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(loaded)
        _ = try await web.evaluateJavaScript("window.receiveSettings(\(json)); window.receiveHotkeyStatus('permissionNeeded'); navigate('misc');")
        #expect(try await web.evaluateJavaScript("document.getElementById('command-tab-mission-control').checked") as? Bool == true, "Launch \(launch) must restore the saved selection without visiting Settings")
        #expect(try await web.evaluateJavaScript("settings.commandTabOpensMissionControl") as? Bool == true, "Missing permission must not clear the saved preference")
        #expect(try await web.evaluateJavaScript("document.getElementById('command-tab-access-settings').nextElementSibling.id==='retry-command-tab'") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.getElementById('command-tab-access-settings').click();")
        for _ in 0..<50 {
            if capture.openedAccessSettings > launch { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(capture.openedAccessSettings == launch + 1)
        _ = try await web.evaluateJavaScript("window.receiveHotkeyStatus('active')")
        #expect(try await web.evaluateJavaScript("!$('command-tab-status').getClientRects().length && !$('command-tab-permission-actions').getClientRects().length && $('command-tab-mission-control').checked") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.receiveHotkeyStatus('unavailable')")
        #expect(try await web.evaluateJavaScript("$('command-tab-status').getClientRects().length>0 && $('retry-command-tab').getClientRects().length>0 && !$('command-tab-access-settings').getClientRects().length") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.receiveHotkeyStatus('permissionNeeded')")
        #expect(try await web.evaluateJavaScript("$('command-tab-status').getClientRects().length>0 && $('command-tab-access-settings').getClientRects().length>0") as? Bool == true)

        _ = try await web.evaluateJavaScript("window.receiveSettings({...settings,commandTabOpensMissionControl:false});")
        #expect(try await web.evaluateJavaScript("document.getElementById('command-tab-mission-control').checked") as? Bool == false, "Native settings must update the Misc switch too")
        _ = try await web.evaluateJavaScript("document.getElementById('command-tab-mission-control').click();")
        for _ in 0..<5 {
            if capture.saved?.commandTabOpensMissionControl == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(capture.saved?.commandTabOpensMissionControl == true)
        capture.saved = nil
    }
}

@Test @MainActor func missionControlRetriesPermissionWithoutClearingPreferenceOrPromptingAgain() async throws {
    var requests: [Bool] = []
    var attempts = 0
    let hotkey = MissionControlHotkey(accessCheck: { request in requests.append(request); return false }, createTap: { _, _, _ in attempts += 1; return nil })
    defer { hotkey.setEnabled(false, requestAccess: false) }
    hotkey.setEnabled(true, requestAccess: true)
    #expect(hotkey.isEnabled)
    #expect(hotkey.status == "permissionNeeded")
    #expect(requests == [true])
    hotkey.refreshAccess()
    #expect(requests == [true, false])
    try await Task.sleep(nanoseconds: 2_300_000_000)
    #expect(requests.count >= 3, "A permission retry must run even without an application activation notification")
    #expect(requests.dropFirst().allSatisfy { !$0 }, "Automatic retries must not prompt repeatedly")
    #expect(attempts == requests.count, "Try the real keyboard capability before relying on accessibility preflight")
    #expect(hotkey.isEnabled)
    hotkey.setEnabled(false, requestAccess: false)
    let count = requests.count
    hotkey.refreshAccess()
    #expect(hotkey.status == "disabled")
    #expect(!hotkey.isEnabled)
    #expect(requests.count == count, "A disabled shortcut must not restart on a later activation")
}
