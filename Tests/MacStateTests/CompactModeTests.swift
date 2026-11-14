import AppKit
import WebKit
import Testing
@testable import MacState

private final class CompactSettingsCapture: NSObject, WKScriptMessageHandler {
    var savedValues: [Bool] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["action"] as? String == "saveSettings",
              let settings = body["settings"] as? [String: Any],
              let compact = settings["compact"] as? Bool else { return }
        savedValues.append(compact)
    }
}

@Test @MainActor func compactModeToggleChangesOverviewDensityAndSavesSetting() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let capture = CompactSettingsCapture()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(capture, name: "macstate")
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: configuration)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer {
        window.orderOut(nil)
        configuration.userContentController.removeScriptMessageHandler(forName: "macstate")
        window.contentView = nil
    }

    view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState==='complete' && typeof window.receiveSnapshot==='function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded)

    _ = try await view.evaluateJavaScript("""
    window.receiveSnapshot({timestamp:1000,device:{chip:'Test',model:'Test Mac',cores:2},
      metrics:[['cpu','CPU',25,'%'],['memory','内存',60,'%'],['gpu','GPU',30,'%'],['download','下载',5000,'B/s'],['cpuTemp','CPU 温度',50,'°C']]
        .map(([id,title,value,unit])=>({id,title,value,unit,kind:'measured',source:'test',detail:'test detail'})),
      cores:[20,40],sensors:[],processes:[],issues:[],collectionMS:1});
    """)

    let before = try #require(try await view.evaluateJavaScript("""
    (()=>{
      const tile=document.querySelector('#hero-metrics .summary-tile');
      const row=document.querySelector('#metric-grid .metric-row > summary');
      const section=document.querySelector('#metric-grid .metric-section-title');
      return {enabled:document.body.classList.contains('compact'),checked:document.getElementById('compact').checked,
        tile:tile.getBoundingClientRect().height,row:row.getBoundingClientRect().height,section:section.getBoundingClientRect().height};
    })()
    """) as? [String: Any])
    #expect(before["enabled"] as? Bool == false)
    #expect(before["checked"] as? Bool == false)

    _ = try await view.evaluateJavaScript("document.getElementById('compact').click()")
    let enabled = try #require(try await view.evaluateJavaScript("""
    (()=>{
      const tile=document.querySelector('#hero-metrics .summary-tile');
      const row=document.querySelector('#metric-grid .metric-row > summary');
      const section=document.querySelector('#metric-grid .metric-section-title');
      return {enabled:document.body.classList.contains('compact'),checked:document.getElementById('compact').checked,
        setting:settings.compact,tile:tile.getBoundingClientRect().height,row:row.getBoundingClientRect().height,
        section:section.getBoundingClientRect().height};
    })()
    """) as? [String: Any])
    #expect(enabled["enabled"] as? Bool == true)
    #expect(enabled["checked"] as? Bool == true)
    #expect(enabled["setting"] as? Bool == true)
    #expect((enabled["tile"] as? Double ?? 0) < (before["tile"] as? Double ?? .infinity), "Hero tiles should become shorter in compact mode")
    #expect((enabled["row"] as? Double ?? 0) < (before["row"] as? Double ?? .infinity), "Metric rows should become shorter in compact mode")
    #expect((enabled["section"] as? Double ?? 0) < (before["section"] as? Double ?? .infinity), "Section headers should become shorter in compact mode")

    for _ in 0..<30 {
        if capture.savedValues.last == true { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(capture.savedValues.last == true, "The native settings bridge should receive compact=true")

    _ = try await view.evaluateJavaScript("document.getElementById('compact').click()")
    let disabled = try #require(try await view.evaluateJavaScript("""
    ({enabled:document.body.classList.contains('compact'),checked:document.getElementById('compact').checked,setting:settings.compact})
    """) as? [String: Any])
    #expect(disabled["enabled"] as? Bool == false)
    #expect(disabled["checked"] as? Bool == false)
    #expect(disabled["setting"] as? Bool == false)
    for _ in 0..<30 {
        if capture.savedValues.last == false { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(capture.savedValues.last == false, "The native settings bridge should receive compact=false")
}

@Test @MainActor func compactModeTightensEveryPage() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let configuration = WKWebViewConfiguration()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: configuration)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }

    view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState==='complete' && typeof window.receiveSnapshot==='function' && typeof window.receiveUsage==='function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded)

    _ = try await view.evaluateJavaScript("""
    window.receiveSnapshot({timestamp:1000,device:{chip:'Test',model:'Test Mac',cores:2},
      metrics:[['cpu','CPU',25,'%'],['memory','内存',60,'%'],['gpu','GPU',30,'%'],['download','下载',5000,'B/s'],['memoryTotal','物理内存',32000000000,'B']]
        .map(([id,title,value,unit])=>({id,title,value,unit,kind:'measured',source:'test',detail:'fixture'})),
      cores:[20,40],
      sensors:[{key:'TCL1',type:'温度',value:50,unit:'°C'}],
      processes:[{pid:1,parent:0,name:'fixture-process',path:'/fixture',user:'test',threads:2,cpu:10,gpu:1,memory:1024,resident:1024,readRate:1,writeRate:1,wakeups:1,power:2,smoothedPower:2,powerStatus:'fixture',status:'fixture'}],
      networks:[{name:'en0',up:true,address:'127.0.0.1',download:1,upload:1,received:10,sent:10}],
      volumes:[{name:'Macintosh HD',path:'/',total:1000000,available:500000}],
      issues:[],collectionMS:1});
    window.receiveUsage({sessions:[],selected:null,averagePower:null,theoreticalRuntime:null});
    """)

    let pageNames = ["overview", "processes", "sensors", "network", "storage", "usage", "misc", "settings"]
    let measureScript = #"""
    (()=>{
      const pages=[
        ['overview','.summary-tile','height'],
        ['processes','#processes .table-wrap td','paddingTop'],
        ['sensors','#sensor-grid .metric-card','paddingTop'],
        ['network','#network-grid .metric-card','paddingTop'],
        ['storage','#volume-grid .metric-card','paddingTop'],
        ['usage','#usage .usage-chart-card','paddingTop'],
        ['misc','#misc .settings-section','paddingTop'],
        ['settings','#settings .settings-section','paddingTop']
      ];
      const density={},navigated=[];
      for(const [name,selector,property] of pages){
        document.querySelector(`#monitor-tabs [data-view="${name}"],.sidebar [data-view="${name}"]`).click();
        const section=document.getElementById(name),node=document.querySelector(selector);
        if(section && !section.hidden && node){
          density[name]=property==='height' ? node.getBoundingClientRect().height : Number.parseFloat(getComputedStyle(node)[property]);
          navigated.push(name);
        }
      }
      return {density,navigated};
    })()
    """#
    let beforeResult = try #require(try await view.evaluateJavaScript(measureScript) as? [String: Any])
    let before = try #require(beforeResult["density"] as? [String: Any])
    #expect(beforeResult["navigated"] as? [String] == pageNames, "Every page should navigate and render its compact-mode target")

    _ = try await view.evaluateJavaScript("document.getElementById('compact').click()")
    #expect(try await view.evaluateJavaScript("document.body.classList.contains('compact')") as? Bool == true)
    let afterResult = try #require(try await view.evaluateJavaScript(measureScript) as? [String: Any])
    let after = try #require(afterResult["density"] as? [String: Any])
    #expect(afterResult["navigated"] as? [String] == pageNames, "Every page should remain navigable in compact mode")
    for page in pageNames {
        let regularDensity = before[page] as? Double ?? .infinity
        let compactDensity = after[page] as? Double ?? .infinity
        #expect(compactDensity < regularDensity, "\(page) should use less vertical space in compact mode")
    }
}
