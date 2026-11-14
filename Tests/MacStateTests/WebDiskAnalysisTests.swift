import AppKit
import WebKit
import Testing
@testable import MacState

private final class DiskMessageCapture: NSObject, WKScriptMessageHandler {
    var ready = false
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" { ready = true }
        if (body["action"] as? String)?.contains("Disk") == true || ["diskDirectory", "diskWorkbench", "navigation"].contains(body["action"] as? String ?? "") { messages.append(body) }
    }
}

@Test @MainActor func diskStorageGrowthShowsComparisonAndCanCaptureCurrentUsage() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let capture = DiskMessageCapture(), config = WKWebViewConfiguration()
    config.userContentController.add(capture, name: "macstate")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 580), configuration: config)
    defer { config.userContentController.removeScriptMessageHandler(forName: "macstate") }
    web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    for _ in 0..<200 { if capture.ready { break }; try await Task.sleep(nanoseconds: 20_000_000) }
    try #require(capture.ready)

    _ = try await web.evaluateJavaScript("""
    window.receiveSnapshot({timestamp:1000,device:{},metrics:[],cores:[],processes:[],sensors:[],issues:[],collectionMS:1,
      volumes:[{name:'Fixture',path:'/test',total:494384795648,available:18900000000}]});
    navigate('storage');
    window.receiveDiskAccess('granted');
    window.receiveDiskIndexes([{volumePath:'/test',state:'ready',files:1,directories:1,bytes:2000000000,ready:true}]);
    document.querySelector('[data-analyze-volume="/test"]').click();
    document.querySelector('[data-storage-section="growth"]').click();
    window.receiveDiskWorkbench({requestID:diskScan.requestID,queryID:diskWorkbench.queryID,mode:'growth',
      rows:[],stats:[],points:[],offset:0,hasMore:false,note:'',error:'',updated:1000});
    """)
    #expect(try await web.evaluateJavaScript("document.getElementById('wb-status').textContent.includes('建立第一份记录')") as? Bool == true)

    _ = try await web.evaluateJavaScript("""
    const direction=document.getElementById('wb-growth-direction');
    direction.value='decrease';direction.dispatchEvent(new Event('change'));
    document.getElementById('wb-growth-hours').value='1';
    window.receiveDiskWorkbench({requestID:diskScan.requestID,queryID:diskWorkbench.queryID,mode:'growth',
      rows:[{title:'Pack',path:'/test/.git/objects/pack',category:'directory',bytes:2000000000,previousBytes:4000000000,delta:-2000000000}],
      growth:{baseline:1000,latest:4600,volumeDelta:-2400000000,indexedDelta:-2000000000,unmatchedCount:1,resultCount:1,largestChange:4000000000,
        trend:[{timestamp:1000,volumeDelta:0,indexedDelta:0},{timestamp:2000,indexedDelta:1000000000},{timestamp:4600,volumeDelta:-2400000000,indexedDelta:-2000000000}]},
      stats:[],points:[],offset:0,hasMore:false,note:'',error:'',updated:4600});
    """)
    #expect(try await web.evaluateJavaScript("document.querySelector('.wb-growth-row .insight-size').textContent.includes('4.00 GB → 2.00 GB')") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.querySelector('.wb-growth-row .wb-delta-negative').textContent==='−2.00 GB' && document.querySelector('.wb-growth-row [data-wb-action=browse]')!==null") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.getElementById('wb-status').textContent.includes('→') && document.getElementById('wb-note').textContent.includes('1 项只出现在一次采样中')") as? Bool == true)
    #expect(try await web.evaluateJavaScript("(()=>{const pane=document.getElementById('disk-workbench-view'), filters=pane.querySelector('.wb-filters');return pane.clientWidth>0 && filters.scrollWidth<=filters.clientWidth+1;})()") as? Bool == true)
    #expect(try await web.evaluateJavaScript("""
    (()=>{const bar=document.querySelector('.wb-growth-bar-negative'),canvas=document.querySelector('#wb-chart canvas');
      return bar.position===0.5 && bar.getBoundingClientRect().height>0 && canvas.getBoundingClientRect().height>0;})()
    """) as? Bool == true)
    #expect(try await web.evaluateJavaScript("""
    (()=>{const input=document.getElementById('wb-trend-sample');
      input.value=1;input.dispatchEvent(new Event('input'));
      return input.getAttribute('aria-valuetext').includes('索引占用 +1.00 GB') &&
        document.querySelector('[data-trend-value=volumeDelta]').textContent==='—' &&
        document.querySelector('[data-trend-value=indexedDelta]').textContent==='+1.00 GB';})()
    """) as? Bool == true)

    _ = try await web.evaluateJavaScript("document.getElementById('wb-refresh').click();")
    for _ in 0..<100 {
        if capture.messages.contains(where: { $0["captureGrowthSample"] as? Bool == true }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let action = try #require(capture.messages.last { $0["captureGrowthSample"] as? Bool == true })
    #expect(action["mode"] as? String == "growth" && action["category"] as? String == "directory")
    #expect(action["growthHours"] as? Int == 1 && action["growthDecreasing"] as? Bool == true)
}

@Test @MainActor func diskAnalysisEntryDrilldownCancellationAndRefreshWorkInWebView() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let capture = DiskMessageCapture(), config = WKWebViewConfiguration()
    config.userContentController.add(capture, name: "macstate")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), configuration: config)
    defer { config.userContentController.removeScriptMessageHandler(forName: "macstate") }
    web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    for _ in 0..<200 { if capture.ready { break }; try await Task.sleep(nanoseconds: 20_000_000) }
    try #require(capture.ready)
    _ = try await web.evaluateJavaScript("document.getElementById('disk-access-settings').click();")
    for _ in 0..<50 {
        if capture.messages.contains(where: { $0["action"] as? String == "openDiskAccessSettings" }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(capture.messages.contains { $0["action"] as? String == "openDiskAccessSettings" })
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-access-settings').nextElementSibling.id==='disk-access-check'") as? Bool == true)
    _ = try await web.evaluateJavaScript("""
    window.receiveSnapshot({timestamp:1000,device:{},metrics:[],cores:[],processes:[],sensors:[],issues:[],collectionMS:1,
      volumes:[{name:'Test <Disk>',path:'/test',total:494384795648,available:18900000000,availableForImportantUsage:31540000000},{name:'Other',path:'/other',total:200000,available:100000}]});
    navigate('storage');
    window.permissionBlocked=document.querySelector('[data-analyze-volume="/test"]').disabled;
    window.receiveDiskAccess('granted');
    window.blockedUntilIndexed=document.querySelector('[data-analyze-volume="/test"]').disabled;
    window.receiveDiskIndexes([{volumePath:'/test',state:'indexing',files:123,directories:4,bytes:50000,elapsed:2,currentPath:'/test',message:'',ready:false}]);
    window.indexProgressVisible=!document.querySelector('.volume-index-progress').hidden && document.querySelector('.volume-index-detail').textContent.includes('123');
    window.receiveDiskIndexes([{volumePath:'/test',state:'ready',files:123,directories:4,bytes:50000,elapsed:2,currentPath:'/test',message:'',ready:true,completedAt:1000,buildElapsed:100,updated:1001}]);
    window.completeLabel=document.querySelector('.volume-index-label').textContent.includes('已就绪') && document.querySelector('.volume-index-detail').title.includes('用时 100 秒') && document.querySelector('.volume-index-progress').hidden;
    window.receiveDiskIndexes([{volumePath:'/test',state:'verifying',files:123,directories:4,bytes:50000,elapsed:0,currentPath:'/test',message:'局部核对',ready:true,completedAt:1000,buildElapsed:100,updated:1001}]);
    window.verificationPreservesCompletion=!document.querySelector('[data-analyze-volume="/test"]').disabled && document.querySelector('.volume-index-label').textContent.includes('已就绪') && document.querySelector('.volume-index-detail').title.includes('用时 100 秒');
    window.volumeAction=document.querySelector('[data-analyze-volume="/test"]');volumeAction.focus();
    window.receiveSnapshot({...snapshot,timestamp:1001,volumes:snapshot.volumes.map(v=>({...v,available:v.available-100}))});
    """)
    #expect(try await web.evaluateJavaScript("permissionBlocked && blockedUntilIndexed && indexProgressVisible && completeLabel && verificationPreservesCompletion") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-analyze-volume]').length") as? Int == 2)
    #expect(try await web.evaluateJavaScript("Array.from(document.querySelectorAll('[data-volume-path=\"/test\"] .kv strong'), node => node.textContent).join('|')") as? String == "494.38 GB|31.54 GB|462.84 GB")
    #expect(try await web.evaluateJavaScript("document.querySelector('[data-volume-path=\"/test\"] progress').value") as? Double == 462844795648)
    #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-volume-path=\"/other\"] .kv strong')[1].textContent") as? String == "99.90 KB")
    #expect(try await web.evaluateJavaScript("volumeAction===document.querySelector('[data-analyze-volume=\"/test\"]') && document.activeElement===volumeAction") as? Bool == true)
    #expect(try await web.evaluateJavaScript("(()=>{const b=volumeAction.getBoundingClientRect(),c=volumeAction.closest('article').getBoundingClientRect();return b.right<=c.right && b.left>c.left+c.width/2 && b.top<c.top+50;})()") as? Bool == true)
    _ = try await web.evaluateJavaScript("volumeAction.click();")
    for _ in 0..<50 { if !capture.messages.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let request = try #require(capture.messages.first { $0["action"] as? String == "startDiskAnalysis" })
    #expect(request["volumePath"] as? String == "/test")
    #expect((request["requestID"] as? String)?.isEmpty == false)
    #expect(try await web.evaluateJavaScript("!document.getElementById('disk-analysis').hidden && document.getElementById('volume-grid').hidden") as? Bool == true)

    #expect(try await web.evaluateJavaScript("document.getElementById('disk-access').hidden && document.getElementById('disk-largest-view').hidden && !document.getElementById('disk-directory-view').hidden") as? Bool == true)
    #expect(try await web.evaluateJavaScript("(()=>{const entry=document.getElementById('disk-largest-open').getBoundingClientRect(),search=document.getElementById('disk-search').getBoundingClientRect(),filters=document.getElementById('disk-kind-filters').getBoundingClientRect();return entry.bottom<=search.top && search.bottom<=filters.top && [...document.querySelectorAll('[data-disk-kind]')].every(b=>b.offsetTop===document.querySelector('[data-disk-kind]').offsetTop);})()") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.receiveDiskAccess('granted');")
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-access').hidden") as? Bool == true)

    _ = try await web.evaluateJavaScript("""
    window.receiveDiskAnalysis({requestID:diskScan.requestID,volumePath:'/test',rootPath:'/test',state:'scanning',files:1,directories:2,bytes:30000,skipped:0,elapsed:2,currentPath:'/test',largest:[]});
    window.receiveDiskDirectory({requestID:diskScan.requestID,path:'/test',bytes:30000,files:1,skipped:0,entryCount:1,offset:0,pending:true,
      breadcrumbs:[{name:'Test <Disk>',path:'/test'}],entries:[{path:'/test/folder',name:'Folder',directory:true,browsable:true,bytes:30000,files:1,skipped:0,pending:true}]});
    window.streamingRow=document.querySelector('#disk-entries [data-disk-directory]');streamingRow.focus();
    window.receiveDiskDirectory({...diskDirectory,bytes:40000,entries:diskDirectory.entries.map(e=>({...e,bytes:40000}))});
    diskProgressTime-=2100;renderDiskProgress();
    """)
    #expect(try await web.evaluateJavaScript("streamingRow===document.querySelector('#disk-entries [data-disk-directory]') && document.activeElement===streamingRow") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-directory-summary').textContent.includes('统计中') && document.getElementById('disk-scanned-count').textContent.includes('4 秒')") as? Bool == true)

    _ = try await web.evaluateJavaScript("""
    window.receiveDiskAnalysis({requestID:diskScan.requestID,volumePath:'/test',rootPath:'/test',state:'completed',files:8,directories:2,bytes:90000,skipped:1,elapsed:2,currentPath:'/test',message:'',largest:[{path:'/test/huge',name:'<img src=x>',directory:false,bytes:60000}]});
    window.receiveDiskDirectory({requestID:diskScan.requestID,path:'/test',bytes:90000,files:8,skipped:1,entryCount:2,offset:0,
      breadcrumbs:[{name:'Test <Disk>',path:'/test'}],entries:[{path:'/test/folder',name:'Folder',directory:true,browsable:true,bytes:30000,files:2,skipped:0},{path:'/test/huge',name:'<img src=x>',directory:false,bytes:60000,skipped:0}]});
    """)
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-state').textContent") as? String == "索引分析")
    #expect(try await web.evaluateJavaScript("document.querySelectorAll('#disk-analysis img').length") as? Int == 0)
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-scan-note').textContent.includes('1 项')") as? Bool == true)
    #expect(try await web.evaluateJavaScript("""
    (()=>{const pause=document.getElementById('disk-sync-pause'),manual=document.getElementById('disk-sync');
      const status={...diskIndexes.get('/test'),synchronizationPaused:true};
      const initial=pause.textContent==='暂停同步' && !manual.disabled;
      pause.click();receiveDiskIndexes([status]);
      const paused=pause.textContent==='恢复自动同步' && manual.textContent==='手动同步' && !manual.disabled;
      manual.click();receiveDiskIndexes([{...status,manualSynchronization:true}]);
      const running=pause.textContent==='停止本次同步' && manual.disabled;
      pause.click();receiveDiskIndexes([{...status,synchronizationPaused:false}]);
      return initial && paused && running;})()
    """) as? Bool == true)
    #expect(capture.messages.contains { $0["action"] as? String == "setDiskSynchronizationPaused" && $0["paused"] as? Bool == true })
    #expect(capture.messages.contains { $0["action"] as? String == "syncDiskIndexCache" && $0["volumePath"] as? String == "/test" })
    _ = try await web.evaluateJavaScript("""
    document.querySelector('#disk-entries [data-disk-directory]').click();
    const largeEntry=document.querySelector('[data-storage-section="large"]');
    largeEntry.focus();largeEntry.click();
    window.receiveDiskLargeFiles({requestID:diskScan.requestID,queryID:storageFiles.queryID,offset:0,hasMore:false,
      entries:[{category:'other',entry:{path:'/test/huge',name:'<img src=x>',directory:false,bytes:60000,logicalBytes:60000}}]});
    document.querySelector('#disk-largest [data-file-action="reveal"]').click();
    """)
    for _ in 0..<50 { if capture.messages.contains(where: { $0["action"] as? String == "revealDiskEntry" }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(capture.messages.last { $0["action"] as? String == "diskDirectory" }?["path"] as? String == "/test/folder")
    #expect(capture.messages.last { $0["action"] as? String == "revealDiskEntry" }?["path"] as? String == "/test/huge")
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-directory-view').hidden && !document.getElementById('disk-largest-view').hidden && document.getElementById('disk-access').hidden") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.activeElement===largeEntry && largeEntry.getAttribute('aria-current')==='page'") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.getElementById('disk-largest-back').click();")
    #expect(try await web.evaluateJavaScript("document.activeElement?.dataset.storageSection==='directory' && document.activeElement.getAttribute('aria-current')==='page'") as? Bool == true)

    _ = try await web.evaluateJavaScript("window.receiveDiskAnalysis({requestID:'obsolete',state:'failed'});window.receiveSnapshot({...snapshot,timestamp:1002});")
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-state').textContent") as? String == "索引分析")
    #expect(try await web.evaluateJavaScript("!document.getElementById('disk-analysis').hidden") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.getElementById('disk-search').value='photo';document.querySelector('[data-disk-kind=\"image\"]').click();")
    for _ in 0..<50 { if capture.messages.contains(where: { $0["action"] as? String == "searchDiskIndex" }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(capture.messages.last { $0["action"] as? String == "searchDiskIndex" }?["kind"] as? String == "image")
    #expect(capture.messages.last { $0["action"] as? String == "searchDiskIndex" }?["text"] as? String == "photo")
    _ = try await web.evaluateJavaScript("""
    window.receiveDiskDirectory({requestID:diskScan.requestID,path:'/test',bytes:90000,files:8,skipped:0,entryCount:101,offset:0,filtered:true,countIsExact:false,searchText:'photo',searchKind:'image',
      breadcrumbs:[{name:'Test',path:'/test'}],entries:[{path:'/test/photo.png',name:'photo.png',directory:false,browsable:false,bytes:100,kind:'image'}]});
    window.fastSearchRow=document.querySelector('#disk-entries [data-entry-path]');
    window.receiveDiskDirectory({...diskDirectory,searchText:'obsolete',entries:[]});
    """)
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-page-label').textContent.includes('至少 101') && !document.getElementById('disk-page-next').disabled") as? Bool == true)
    #expect(try await web.evaluateJavaScript("fastSearchRow===document.querySelector('#disk-entries [data-entry-path]') && document.getElementById('disk-directory-summary').textContent.includes('按索引顺序')") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.savedDiskSearchRow=fastSearchRow;document.getElementById('disk-largest-open').click();document.getElementById('disk-largest-back').click();")
    #expect(try await web.evaluateJavaScript("!document.getElementById('disk-directory-view').hidden && document.getElementById('disk-largest-view').hidden && document.getElementById('disk-search').value==='photo' && document.querySelector('[data-disk-kind=\"image\"]').getAttribute('aria-pressed')==='true' && savedDiskSearchRow===document.querySelector('#disk-entries [data-entry-path]')") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.querySelector('[data-disk-sort=\"size\"]').click();")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(capture.messages.last { $0["action"] as? String == "searchDiskIndex" }?["sortKey"] as? String == "size")
    #expect(capture.messages.last { $0["action"] as? String == "searchDiskIndex" }?["sortDescending"] as? Bool == true)
    _ = try await web.evaluateJavaScript("document.querySelector('[data-disk-sort=\"size\"]').click();")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(capture.messages.last { $0["action"] as? String == "searchDiskIndex" }?["sortDescending"] as? Bool == false)
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-breadcrumbs').hidden && document.querySelectorAll('[data-disk-sort]').length===5 && document.querySelector('.disk-scan-card')===null && document.getElementById('disk-scanned-size').closest('.disk-toolbar')!==null") as? Bool == true)
    _ = try await web.evaluateJavaScript("document.getElementById('disk-rescan').click();document.getElementById('disk-cancel').click();document.getElementById('disk-back').click();")
    for _ in 0..<50 { if capture.messages.contains(where: { $0["action"] as? String == "cancelDiskAnalysis" }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(capture.messages.contains { $0["action"] as? String == "cancelDiskAnalysis" })
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-analysis').hidden && !document.getElementById('volume-grid').hidden && document.getElementById('disk-access').getClientRects().length===0") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.receiveDiskAccess('unknown');")
    #expect(try await web.evaluateJavaScript("document.getElementById('disk-access-title').textContent.includes('无法确认') && document.getElementById('disk-access-note').textContent.includes('不代表')") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.receiveDiskAccess('missing');window.restorePage('storage');")
    #expect(try await web.evaluateJavaScript("view==='storage' && document.querySelector('[data-analyze-volume]').disabled && document.getElementById('disk-access-note').textContent.includes('自行') && document.getElementById('disk-access-check').getClientRects().length>0") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.restorePage('sensors');")
    #expect(try await web.evaluateJavaScript("view==='processes' && !document.getElementById('processes').hidden") as? Bool == true)
    _ = try await web.evaluateJavaScript("window.restorePage('invalid-page');")
    #expect(try await web.evaluateJavaScript("view==='overview'") as? Bool == true)
}
