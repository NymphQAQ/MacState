import AppKit
import WebKit
import Testing
@testable import MacState

@Test @MainActor func desktopDesignKeepsAllPagesReadableAtSupportedSizes() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 850))
    let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await web.evaluateJavaScript("document.readyState==='complete' && typeof receiveSnapshot==='function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded)
    _ = try await web.evaluateJavaScript("""
    window.receiveSnapshot({timestamp:1000,device:{chip:'Apple Silicon',model:'Test Mac',cores:8},
      metrics:[['cpu','CPU',25,'%'],['memory','内存',60,'%'],['gpu','GPU',30,'%'],['download','下载',5000,'B/s'],['cpuTemp','CPU 温度',50,'°C'],['memoryTotal','物理内存',32000000000,'B']]
        .map(([id,title,value,unit])=>({id,title,value,unit,kind:'measured',source:'test fixture',detail:'测试数据'})),
      cores:[20,40,10,50,30,60,20,10],
      sensors:[{key:'TCL1',type:'温度',value:50,unit:'°C'}],
      processes:[{pid:1,parent:0,name:'fixture-process',path:'/fixture',user:'test',threads:2,cpu:10,gpu:1,memory:1024,resident:1024,readRate:1,writeRate:1,wakeups:1,power:2,smoothedPower:2,powerStatus:'fixture',status:'fixture'}],
      networks:[{name:'en0',up:true,address:'127.0.0.1',download:1,upload:1,received:10,sent:10}],
      volumes:[{name:'Macintosh HD',path:'/',total:1000000,available:500000}],issues:[],collectionMS:1});
    window.receiveUsage({sessions:[],selected:null,averagePower:null,theoreticalRuntime:null});
    window.receiveScreenshotState({settings:{destination:'both',format:'png',prefix:'MacState',delay:0,pointer:false,shadow:true,preview:true,
      directory:'/Users/test/截图/'+('很长的保存目录/'.repeat(8)),shortcuts:{region:{enabled:true,label:'⌃⌥1'},window:{enabled:true,label:'⌃⌥2'},screen:{enabled:true,label:'⌃⌥3'}}},
      permission:true,busy:false,canCancel:false,message:'截屏设置已保存。',hotkeyError:'',records:[],displays:['测试显示器']});
    """)
    let monitoring = try #require(try await web.evaluateJavaScript("""
    (()=>{
      const checks={},tabs=[...document.querySelectorAll('#monitor-tabs [role=tab]')];
      const entry=document.querySelector('.sidebar [data-view=processes]');
      const selected=()=>tabs.find(tab=>tab.getAttribute('aria-selected')==='true');
      checks.singleEntry=entry.textContent.includes('监控') && !document.querySelector('.sidebar [data-view=sensors],.sidebar [data-view=network]');
      checks.tabOrder=tabs.map(tab=>tab.textContent).join(',')==='进程,传感器,网络';
      entry.click();
      checks.defaultProcess=!document.getElementById('processes').hidden && selected()===tabs[0] && document.getElementById('page-title').textContent==='监控';
      document.getElementById('process-search').value='fixture';
      document.getElementById('process-search').dispatchEvent(new Event('input',{bubbles:true}));
      document.getElementById('pause-processes').click();
      tabs[1].click();tabs[1].focus();
      checks.sensorData=!document.getElementById('sensors').hidden && document.getElementById('sensor-grid').textContent.includes('TCL1');
      window.receiveSnapshot({...snapshot,timestamp:1001,
        sensors:snapshot.sensors.map(sensor=>({...sensor,value:61})),
        processes:snapshot.processes.map(process=>({...process,name:'fixture-latest'}))});
      checks.liveSampling=selected()===tabs[1] && document.querySelector('#sensor-grid .metric-value').textContent.includes('61.0');
      tabs[1].dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
      checks.networkData=!document.getElementById('network').hidden && document.getElementById('network-grid').textContent.includes('en0');
      checks.keyboardFocus=selected()===tabs[2] && document.activeElement===tabs[2] && tabs.filter(tab=>tab.tabIndex===0).length===1;
      tabs[2].dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',isComposing:true,bubbles:true}));
      checks.imeGuard=selected()===tabs[2];
      tabs[2].dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true}));
      checks.preservedProcess=selected()===tabs[0] && document.getElementById('process-search').value==='fixture' && document.getElementById('process-rows').textContent.includes('fixture-process');
      document.getElementById('pause-processes').click();
      checks.resumedProcess=document.getElementById('process-rows').textContent.includes('fixture-latest');
      tabs[0].dispatchEvent(new KeyboardEvent('keydown',{key:'End',bubbles:true}));
      checks.endKey=selected()===tabs[2];
      tabs[2].dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
      checks.wrapRight=selected()===tabs[0];
      tabs[0].dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));
      checks.wrapLeft=selected()===tabs[2];
      checks.sharedNavigation=entry.getAttribute('aria-current')==='page' && document.querySelectorAll('.sidebar .nav.active').length===1;
      checks.panelLabels=tabs.every(tab=>document.getElementById(tab.getAttribute('aria-controls')).getAttribute('aria-labelledby')===tab.id);
      document.querySelector('.sidebar [data-view=overview]').click();
      checks.hiddenOutsideMonitor=document.getElementById('monitor-tabs').hidden && tabs.every(tab=>document.getElementById(tab.getAttribute('aria-controls')).hidden);
      entry.click();
      checks.reentryDefaults=selected()===tabs[0];
      for(const saved of ['processes','sensors','network']){
        window.restorePage(saved);checks['restore-'+saved]=selected()===tabs[0];
      }
      document.getElementById('process-search').value='';
      return checks;
    })()
    """) as? [String: Bool])
    for (behavior, passed) in monitoring {
        #expect(passed, "Monitoring tabs: \(behavior)")
    }
    let categories = try #require(try await web.evaluateJavaScript("""
    (()=>{
      window.openSettings();
      const checks={},tabs=[...document.querySelectorAll('#settings-tabs [role=tab]')],last=tabs.at(-1);
      const selected=()=>tabs.find(tab=>tab.getAttribute('aria-selected')==='true');
      checks.defaultGeneral=selected()===tabs[0] && !document.getElementById('settings-general').hidden;
      checks.labels=tabs.map(tab=>tab.textContent).join(',')==='通用,外观与面板,状态栏,截屏,文件操作,关于';
      const groups={general:['interval','history','launch-login'],appearance:['theme','glass-opacity','native-glass-enabled','compact','panel-options'],menu:['name-style','value-style','menu-preview','menu-options','menu-column-spacing','hide-fan-unit'],screenshot:['shot-settings','shot-destination','shot-prefix','shot-directory','shot-delay','shot-shortcuts'],files:['file-open-applications','file-add-application'],about:['quit']};
      for(const [group,ids] of Object.entries(groups)){
        const tab=tabs.find(tab=>tab.dataset.settingsCategory===group);tab.click();
        const panel=document.getElementById(tab.getAttribute('aria-controls'));
        checks[group]=!panel.hidden && panel.getAttribute('aria-labelledby')===tab.id && ids.every(id=>document.getElementById(id).closest('.settings-category')===panel);
        checks[group+'-visible']=document.querySelectorAll('.settings-category:not([hidden])').length===1 && (group==='screenshot' ? document.getElementById('save-status').hidden && document.getElementById('shot-settings-feedback').getClientRects().length>0 : document.getElementById('save-status').getClientRects().length>0);
      }
      last.focus();last.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
      checks.wrapRight=selected()===tabs[0] && document.activeElement===tabs[0];
      tabs[0].dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));
      checks.wrapLeft=selected()===last;
      last.dispatchEvent(new KeyboardEvent('keydown',{key:'Home',bubbles:true}));
      checks.home=selected()===tabs[0];
      tabs[0].dispatchEvent(new KeyboardEvent('keydown',{key:'End',bubbles:true}));
      checks.end=selected()===last && tabs.filter(tab=>tab.tabIndex===0).length===1;
      last.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',isComposing:true,bubbles:true}));
      checks.imeGuard=selected()===last;
      checks.independentTabs=document.getElementById('monitor-tabs').hidden && document.querySelector('#monitor-tabs [aria-selected=true]')===null;
      selectSettingsCategory('invalid');checks.invalidCategory=selected()===last;
      selectSettingsCategory('appearance');window.receiveSettings({...settings});
      checks.syncKeepsCategory=selected()===tabs[1] && !document.getElementById('settings-appearance').hidden;
      navigate('overview');window.openSettings();checks.reentryGeneral=selected()===tabs[0];
      return checks;
    })()
    """) as? [String: Bool])
    for (behavior, passed) in categories {
        #expect(passed, "Settings categories: \(behavior)")
    }
    let auditPath = ProcessInfo.processInfo.environment["MACSTATE_CLIP_AUDIT"]
    let audit = try auditPath.map { try String(contentsOfFile: $0, encoding: .utf8) }
    let report = ProcessInfo.processInfo.environment["MACSTATE_DESIGN_REPORT"].map { URL(fileURLWithPath: $0) }
    if let report { try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true) }
    var records: [[String: Any]] = []
    for (width, height) in [(1200, 850), (920, 660), (600, 420)] {
        window.setContentSize(NSSize(width: width, height: height))
        web.frame.size = NSSize(width: width, height: height)
        for compact in [false, true] {
            for light in [false, true] {
                window.backgroundColor = light ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
                _ = try await web.evaluateJavaScript("settings.compact=\(compact);settings.theme='\(light ? "light" : "dark")';applyAppearance();document.getElementById('preview-notice').hidden=true")
                for (page, category) in [
                    ("overview", ""), ("processes", ""), ("sensors", ""), ("network", ""),
                    ("storage", ""), ("usage", ""), ("screenshot", ""), ("misc", ""),
                    ("settings", "general"), ("settings", "appearance"), ("settings", "menu"),
                    ("settings", "screenshot"), ("settings", "files"), ("settings", "about")
                ] {
                    _ = try await web.evaluateJavaScript("navigate('\(page)')")
                    if !category.isEmpty { _ = try await web.evaluateJavaScript("selectSettingsCategory('\(category)')") }
                    let destination = category.isEmpty ? page : "\(page)-\(category)"
                    let result = try #require(try await web.evaluateJavaScript("""
                    (()=>{
                      const tiny=[],sizes=new Set();
                      for(const el of document.querySelectorAll('body *')){
                        if(!el.getClientRects().length || getComputedStyle(el).visibility==='hidden')continue;
                        if(![...el.childNodes].some(n=>n.nodeType===3 && n.textContent.trim()))continue;
                        const size=parseFloat(getComputedStyle(el).fontSize);sizes.add(size);
                        if(size<12)tiny.push(el.id||el.className||el.tagName);
                      }
                      const active=document.querySelector('.nav[aria-current="page"]');
                      return {tiny,sizes:[...sizes],overflow:document.documentElement.scrollWidth>innerWidth+1,
                        current:active?.dataset.view,rail:document.querySelector('.sidebar').getBoundingClientRect().width};
                    })()
                    """) as? [String: Any])
                    let context = "\(destination) \(width)x\(height) compact=\(compact) light=\(light)"
                    #expect((result["tiny"] as? [String])?.isEmpty == true, "Unreadable text: \(context) \(result)")
                    #expect(result["overflow"] as? Bool == false, "Page must not overflow horizontally: \(context)")
                    let navigationPage = ["processes", "sensors", "network"].contains(page) ? "processes" : page
                    #expect(result["current"] as? String == navigationPage)
                    #expect((result["sizes"] as? [Double] ?? []).count <= 4, "Typography scale: \(context) \(result)")
                    var record = result
                    record["context"] = context
                    if let audit {
                        let response = try #require(try await web.evaluateJavaScript("(\(audit))({viewport:true})") as? [String: Any])
                        #expect(response["cut"] as? Int == 0, "Shadow clipping: \(context) \(response)")
                        record["audit"] = response
                    }
                    records.append(record)
                    if let report, !compact, width == 1200 || width == 600 && ["overview", "settings"].contains(page) {
                        // Let the existing 150 ms navigation color transition finish before capturing.
                        try await Task.sleep(nanoseconds: 180_000_000)
                        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                            web.takeSnapshot(with: nil) { image, error in
                                if let image { continuation.resume(returning: image) }
                                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                            }
                        }
                        let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                        try data.write(to: report.appendingPathComponent("\(destination)-\(width)-\(light ? "light" : "dark").png"))
                    }
                }
            }
        }
    }
    _ = try await web.evaluateJavaScript("""
    settings.compact=false;applyAppearance();navigate('storage');
    receiveDiskAccess('granted');
    receiveDiskIndexes([{volumePath:'/',state:'ready',ready:true,files:30,directories:1,bytes:90000}]);
    openDiskAnalysis('/');
    receiveDiskAnalysis({requestID:diskScan.requestID,volumePath:'/',rootPath:'/',state:'completed',files:30,directories:1,bytes:90000,skipped:0,elapsed:1,currentPath:'/',largest:[]});
    receiveDiskDirectory({requestID:diskScan.requestID,path:'/',bytes:90000,files:30,skipped:0,entryCount:30,offset:0,
      breadcrumbs:[{name:'Macintosh HD',path:'/'}],entries:Array.from({length:30},(_,i)=>({path:'/fixture-'+i,name:'测试文件夹 '+i,directory:true,browsable:true,bytes:3000,files:1,skipped:0}))});
    """)
    window.setContentSize(NSSize(width: 920, height: 660))
    web.frame.size = NSSize(width: 920, height: 660)
    let fullNavigation = try await web.evaluateJavaScript("""
    (()=>{
      const nav=$('storage-navigation');
      const rows=[...nav.querySelectorAll('button')].filter(button=>button.getClientRects().length).map(button=>button.getBoundingClientRect());
      return rows.length===20 && nav.scrollHeight<=nav.clientHeight && nav.scrollWidth<=nav.clientWidth &&
        rows.every((row,i)=>row.left===rows[0].left && (!i || row.top>=rows[i-1].bottom)) &&
        nav.getBoundingClientRect().right<document.querySelector('.disk-workspace-content').getBoundingClientRect().left;
    })()
    """) as? Bool
    #expect(fullNavigation == true, "All 19 pages and Export fit in one left column at the default size")
    for height in [392, 420] {
        window.setContentSize(NSSize(width: 600, height: height))
        web.frame.size = NSSize(width: 600, height: height)
        let usable = try await web.evaluateJavaScript("""
        (()=>{const list=document.getElementById('disk-entries');
          return list.clientHeight>=160 && list.scrollHeight>list.clientHeight && document.documentElement.scrollWidth<=innerWidth+1;
        })()
        """) as? Bool
        #expect(usable == true, "Short storage windows retain a usable scrollable result list")
    }
    let hiddenEntry = try await web.evaluateJavaScript("""
    (()=>{
      const nav=$('storage-navigation'),last=$('storage-export-toggle');
      nav.scrollTop=nav.scrollHeight;
      const reachable=last.getBoundingClientRect().bottom<=nav.getBoundingClientRect().bottom;
      nav.scrollTop=0;
      return reachable && nav.scrollWidth<=nav.clientWidth;
    })()
    """) as? Bool
    #expect(hiddenEntry == true, "The final sidebar entry is reachable at the minimum window size")
    _ = try await web.evaluateJavaScript("navigate('processes');document.querySelector('[data-pid]').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true}))")
    #expect(try await web.evaluateJavaScript("!document.getElementById('process-detail').open") as? Bool == true)
    if let report {
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("layout-audit.json"))
    }
}
