import AppKit
import WebKit
import Testing
@testable import MacState

private final class UsageTestBridge: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

@Test @MainActor func offlineUsagePageRendersHistoryAndSendsScopedActions() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let bridge = UsageTestBridge(), config = WKWebViewConfiguration()
    config.userContentController.add(bridge, name: "macstate")
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: config)
    view.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil; config.userContentController.removeScriptMessageHandler(forName: "macstate") }
    view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState === 'complete' && typeof window.receiveUsage === 'function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded)
    let recorder = UsageRecorder()
    let mainRow = ProcessRow(pid: 100, parent: 1, name: "测试 <b>主进程</b>", path: "/Apps/Test.app/Contents/Main", user: "test", threads: 1,
        cpu: 0, memory: 0, resident: 0, readRate: 0, writeRate: 0, wakeups: 0, power: 2, startIdentity: 1000, status: "fixture")
    let helperRow = ProcessRow(pid: 101, parent: 100, name: "Helper & GPU", path: "/Apps/Test.app/Contents/Helper", user: "test", threads: 1,
        cpu: 0, memory: 0, resident: 0, readRate: 0, writeRate: 0, wakeups: 0, power: 3, startIdentity: 2000, status: "fixture")
    for i in 0...30 {
        recorder.record(UsageReading(timestamp: 1_700_000_000 + Double(i * 10), uptime: Double(i * 10 + 100),
                                     battery: 100 - Double(i) / 10, mode: .battery, power: 10, temperature: 42,
                                     application: UsageApplication(id: "fixture-app", name: "测试 <b>应用</b>"),
                                     applicationPowers: [UsageApplicationPower(application: UsageApplication(id: "fixture-app", name: "测试 <b>应用</b>"), power: 5, processCount: 2,
                                         measuredProcessCount: 2, processes: [UsageProcessPower(mainRow, mainPID: 100), UsageProcessPower(helperRow, mainPID: 100)])]))
    }
    let firstID = recorder.archive.activeSessionID!
    recorder.closeCurrent()
    recorder.record(UsageReading(timestamp: 1_700_000_310, uptime: 410, battery: 97, mode: .charging,
                                 power: nil, temperature: nil, application: nil))
    let payload = recorder.payload(selectedID: firstID)
    let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    _ = try await view.evaluateJavaScript("document.querySelector('[data-view=usage]').click();window.receiveUsage(\(json))")
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('#usage-chart .usage-line').length") as? Int == 1)
    #expect(try await view.evaluateJavaScript("document.getElementById('usage-runtime').textContent") as? String == "2h46m")
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-app-name').textContent") as? String == "测试 <b>应用</b>")
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-app-name b').length") as? Int == 0)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-app-time').textContent.includes('5m00s')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-total-power').textContent.includes('5.00W')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-gpu-power,.usage-cpu-power').length") as? Int == 0)
    #expect(try await view.evaluateJavaScript("document.getElementById('usage-app-count').textContent.includes('CPU 能量 + GPU 归属')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-coverage').textContent.includes('100%')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-app').open") as? Bool == false)
    _ = try await view.evaluateJavaScript("document.querySelector('.usage-app-summary').click()")
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-process-table tbody tr').length") as? Int == 2)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-process-name').textContent") as? String == "测试 <b>主进程</b>")
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-process-name b').length") as? Int == 0)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-process-power').textContent.includes('2.00W')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-process-name.depth-1').textContent.includes('Helper & GPU')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("usageProcessPowerNumber(0.005)") as? String == "5.00mW")
    #expect(try await view.evaluateJavaScript("usageProcessPowerNumber(null)") as? String == "—")
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(json))")
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-app').open") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-process-table tbody tr').length") as? Int == 2)
    _ = try await view.evaluateJavaScript("document.getElementById('usage-sort').value='power';document.getElementById('usage-sort').dispatchEvent(new Event('change'))")
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-app').open") as? Bool == true)
    // Hundreds of historical instances remain reachable through pagination.
    _ = try await view.evaluateJavaScript("var many=\(json);var app=many.selected.applications['fixture-app'];var seed=Object.values(app.processes)[0];for(var i=0;i<105;i++){var p={...seed,id:'extra:'+i,pid:1000+i,parentID:null,isMain:false,name:'Worker '+i};app.processes[p.id]=p;}window.receiveUsage(many)")
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-process-table tbody tr').length") as? Int == 100)
    _ = try await view.evaluateJavaScript("document.querySelector('[data-process-page=\"1\"]').click()")
    #expect(try await view.evaluateJavaScript("document.querySelectorAll('.usage-process-table tbody tr').length") as? Int == 7)
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(json))")
    // Older records deliberately have no process map; never invent zero rows.
    _ = try await view.evaluateJavaScript("var oldDetails=\(json);delete oldDetails.selected.applications['fixture-app'].processes;window.receiveUsage(oldDetails)")
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-processes').textContent.includes('未保存进程明细')") as? Bool == true)
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(json))")
    if let directory = ProcessInfo.processInfo.environment["MACSTATE_USAGE_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (label, width, height, light) in [("dark-920",920.0,660.0,false),("light-600",600.0,420.0,true)] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)
            // This test has no native glass host; give its transparent document
            // a theme-appropriate backdrop for inspecting the HTML surface.
            _ = try await view.evaluateJavaScript("settings.theme='\(light ? "light" : "dark")';applyAppearance();document.documentElement.style.setProperty('background','\(light ? "#f0f0f0" : "#202126")','important');document.querySelector('.usage-app-card').scrollIntoView({block:'end'})")
            try await Task.sleep(nanoseconds: 50_000_000)
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: nil) { image, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                }
            }
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-processes-\(label).png"))
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 660), display: true)
        _ = try await view.evaluateJavaScript("settings.theme='dark';applyAppearance();document.documentElement.style.removeProperty('background');window.scrollTo(0,0)")
    }
    let legacyJSON = json.replacingOccurrences(of: "\"applicationPowerVersion\":5", with: "\"applicationPowerVersion\":1")
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(legacyJSON))")
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-coverage').textContent.includes('旧记录')") as? Bool == true)
    let scoreJSON = json.replacingOccurrences(of: "\"applicationPowerVersion\":5", with: "\"applicationPowerVersion\":3")
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(scoreJSON))")
    #expect(try await view.evaluateJavaScript("['旧算法','评分分摊'].every(s=>document.getElementById('usage-app-count').textContent.includes(s))") as? Bool == true)
    let cpuOnlyJSON = json.replacingOccurrences(of: "\"applicationPowerVersion\":5", with: "\"applicationPowerVersion\":4")
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(cpuOnlyJSON))")
    #expect(try await view.evaluateJavaScript("['旧算法','power（CPU）'].every(s=>document.getElementById('usage-app-count').textContent.includes(s))") as? Bool == true)
    _ = try await view.evaluateJavaScript("window.receiveUsage(\(json))")
    _ = try await view.evaluateJavaScript("document.getElementById('usage-delete').click()")
    #expect(try await view.evaluateJavaScript("document.getElementById('usage-delete-dialog').open") as? Bool == true)
    _ = try await view.evaluateJavaScript("document.getElementById('usage-delete-cancel').click()")
    #expect(!bridge.messages.contains { $0["action"] as? String == "deleteUsage" })
    _ = try await view.evaluateJavaScript("document.getElementById('usage-delete').click();window.openOverview()")
    #expect(try await view.evaluateJavaScript("document.getElementById('usage-delete-dialog').open") as? Bool == false)
    _ = try await view.evaluateJavaScript("document.querySelector('[data-view=usage]').click()")
    _ = try await view.evaluateJavaScript("document.getElementById('usage-delete').click();document.getElementById('usage-delete-confirm').click()")
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(bridge.messages.contains { $0["action"] as? String == "deleteUsage" && $0["sessionID"] as? String == firstID })
    #expect(bridge.messages.contains { $0["action"] as? String == "usageHistory" && $0["visible"] as? Bool == true })
    window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 420), display: true)
    try await Task.sleep(nanoseconds: 40_000_000)
    #expect(try await view.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth") as? Bool == true)
    // Readable text takes priority over keeping every summary above the fold.
    _ = try await view.evaluateJavaScript("document.querySelector('.usage-summary').scrollIntoView({block:'center',behavior:'instant'})")
    #expect(try await view.evaluateJavaScript("(()=>{const summary=document.querySelector('.usage-summary').getBoundingClientRect();return summary.top>=0 && summary.bottom<=document.querySelector('footer').getBoundingClientRect().top;})()") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.sidebar [data-view=settings]').getBoundingClientRect().bottom <= innerHeight") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.usage-process-table').getBoundingClientRect().right <= innerWidth") as? Bool == true)
    _ = try await view.evaluateJavaScript("document.querySelector('[data-view=overview]').click()")
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(bridge.messages.last { $0["action"] as? String == "usageHistory" }?["visible"] as? Bool == false)
    let process = ProcessRow(pid: 10, parent: 1, name: "测试 <b>进程</b>", path: "", user: "test", threads: 1,
                             cpu: 0, memory: 0, resident: 0, readRate: 0, writeRate: 0, wakeups: 0,
                             power: 5, smoothedPower: 6, lifetimeEnergy: 3600, status: "可读取")
    let snapshot = Snapshot(timestamp: 1_700_000_310, device: ["chip":"测试", "model":"MacBook", "cores":"10"],
                            metrics: [], cores: [], processes: [process], networks: [], volumes: [], sensors: [],
                            collectionMS: 10, issues: [], processPower: ProcessPowerSummary(measuredProcesses: 1, totalProcesses: 1, measuredPower: 5))
    let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    _ = try await view.evaluateJavaScript("window.receiveSnapshot(\(snapshotJSON));document.querySelector('[data-view=processes]').click()")
    #expect(try await view.evaluateJavaScript("document.querySelector('.process-power').textContent.includes('5.00W')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.process-power').textContent.includes('6.00W')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.process-power').firstChild.textContent.includes('5.00W')") as? Bool == true)
    #expect(try await view.evaluateJavaScript("document.querySelector('.process-power').textContent.includes('评分')") as? Bool == false)
    #expect(try await view.evaluateJavaScript("document.getElementById('process-power-summary').textContent.includes('已读取 1/1')") as? Bool == true)
    _ = try await view.evaluateJavaScript("document.querySelector('[data-pid]').click()")
    #expect(try await view.evaluateJavaScript("document.getElementById('detail-content').textContent.includes('CPU 功耗估算')") as? Bool == false)
    #expect(try await view.evaluateJavaScript("document.getElementById('detail-content').textContent.includes('1.0000Wh')") as? Bool == true)
    _ = try await view.evaluateJavaScript("document.getElementById('close-detail').click();window.openSettings()")
    #expect(try await view.evaluateJavaScript("document.getElementById('authorize-energy') === null") as? Bool == true)
}
