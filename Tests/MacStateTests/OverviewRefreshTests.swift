import AppKit
import WebKit
import Testing
@testable import MacState

@Test @MainActor func overviewSamplingPreservesGlassBoundariesFocusAndVisibilityChanges() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let configuration = WKWebViewConfiguration()
    // The real component bridge needs a native handler to annotate boundaries.
    let messages = OverviewMessages()
    configuration.userContentController.add(messages, name: "macstate")
    let view = WKWebView(frame: NSRect(x:0,y:0,width:920,height:660), configuration:configuration)
    let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.contentView = view; window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView=nil; configuration.userContentController.removeScriptMessageHandler(forName:"macstate") }
    view.loadFileURL(root.appendingPathComponent("index.html"),allowingReadAccessTo:root)
    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState==='complete' && typeof window.receiveSnapshot==='function'")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds:20_000_000)
    }
    try #require(loaded)
    _ = try await view.evaluateJavaScript("""
    window.setComponentGlassEnabled(true);
    window.refreshFixture={timestamp:1000,device:{chip:'Apple Test',model:'Test Mac',cores:2},
      metrics:[['cpu','CPU',25,'%'],['memory','内存',60,'%'],['gpu','GPU',30,'%'],['download','下载',5000,'B/s'],
        ['cpuTemp','CPU 温度',50,'°C'],['gpuTemp','GPU 温度',45,'°C'],['upload','上传',6000,'B/s']]
        .map(([id,title,value,unit])=>({id,title,value,unit,kind:'measured',source:'test',detail:''})),
      cores:[20,40],sensors:[],processes:[],issues:[],collectionMS:1};
    window.receiveSnapshot(window.refreshFixture);
    """)
    for _ in 0..<100 {
        if (try? await view.evaluateJavaScript("document.querySelectorAll('#hero-metrics > [data-native-glass]').length===4")) as? Bool == true { break }
        try await Task.sleep(nanoseconds:20_000_000)
    }
    let result = try #require(try await view.evaluateJavaScript("""
    (()=>{
      const cards=[...document.querySelectorAll('#hero-metrics > button')];
      cards[0].focus();
      const originalChart=cards[0].querySelector('.summary-chart').innerHTML;
      const updated=JSON.parse(JSON.stringify(window.refreshFixture));
      updated.timestamp+=2;updated.metrics[0].value=75;updated.metrics[4].value=80;
      window.receiveSnapshot(updated);
      const stable=cards.every((card,i)=>card===document.getElementById('hero-metrics').children[i]);
      const annotations=cards.every(card=>card.dataset.nativeGlass==='true');
      const focus=document.activeElement===cards[0];
      const value=cards[0].querySelector('.summary-value').textContent;
      const subtitle=cards[0].querySelector('.summary-subtitle').textContent;
      const chartChanged=originalChart!==cards[0].querySelector('.summary-chart').innerHTML;
      const noLoading=!document.querySelector('#metric-grid > .loading');
      settings.hiddenMetrics=['memory'];renderOverview();
      const hidden=document.getElementById('hero-metrics').children.length===3 && !cards[1].isConnected;
      settings.hiddenMetrics=[];renderOverview();
      const shown=document.getElementById('hero-metrics').children.length===4 && cards[0].isConnected && cards[2].isConnected && cards[3].isConnected;
      return {stable,annotations,focus,value,subtitle,chartChanged,hidden,shown,noLoading};
    })()
    """) as? [String:Any])
    for key in ["stable","annotations","focus","chartChanged","hidden","shown","noLoading"] { #expect(result[key] as? Bool == true, "\(key): \(result)") }
    #expect((result["value"] as? String)?.contains("75") == true)
    #expect((result["subtitle"] as? String)?.contains("80") == true)
    // Exercise both material modes. Keep the actual summary focused/open,
    // then observe sampling, disappearance and return of a different metric.
    for enhanced in [false,true] {
        _ = try await view.evaluateJavaScript("""
        window.setComponentGlassEnabled(\(enhanced));
        settings.hiddenMetrics=[];group='all';focusedMetric=null;renderOverview();
        window.detailFixture={row:document.getElementById('metric-cpuTemp'),other:document.getElementById('metric-gpuTemp')};
        window.detailFixture.summary=window.detailFixture.row.querySelector('summary');
        window.detailFixture.section=window.detailFixture.row.parentElement;
        window.detailFixture.lane=window.detailFixture.section.parentElement;
        if(!window.detailFixture.row.open)window.detailFixture.summary.click();window.detailFixture.summary.focus();
        """)
        let details = try #require(try await view.evaluateJavaScript("""
        (()=>{
          const {row,other,summary,section,lane}=window.detailFixture;
          const before=summary.querySelector('.row-chart').innerHTML;
          const removed=[];
          const observer=new MutationObserver(()=>{});
          observer.observe(document.getElementById('metric-grid'),{subtree:true,childList:true});
          const updated=JSON.parse(JSON.stringify(snapshot));updated.timestamp+=2;
          const metric=updated.metrics.find(m=>m.id==='cpuTemp');
          metric.value=91;metric.title='温度 <test>';metric.kind='estimated';metric.source='source <test>';metric.detail='detail <test>';
          window.receiveSnapshot(updated);
          for(const record of observer.takeRecords())removed.push(...record.removedNodes);
          observer.disconnect();
          const stable=row===document.getElementById('metric-cpuTemp') && summary===row.querySelector('summary') && section===row.parentElement && lane===section.parentElement;
          const noRemoval=![row,summary,section,lane].some(node=>removed.includes(node));
          const focus=document.activeElement===summary,open=row.open;
          const content=summary.querySelector('.row-value').textContent.includes('91') && summary.querySelector('.row-name').textContent.includes('温度 <test>') && row.querySelector('.row-detail').textContent.includes('source <test>') && !row.querySelector('test') && row.querySelector('.estimate-mark')!==null;
          const chartChanged=before!==summary.querySelector('.row-chart').innerHTML;
          updated.timestamp+=2;metric.value=null;window.receiveSnapshot(updated);
          const unavailable=row.classList.contains('is-unavailable') && row.open && document.activeElement===summary;
          settings.hiddenMetrics=['gpuTemp'];renderOverview();
          const hidden=!other.isConnected && row===document.getElementById('metric-cpuTemp');
          settings.hiddenMetrics=[];renderOverview();
          const shown=!!document.getElementById('metric-gpuTemp') && row===document.getElementById('metric-cpuTemp') && row.open;
          group='nonexistent';renderOverview();
          const empty=document.querySelectorAll('#metric-grid > .empty').length===1;
          group='all';renderOverview();
          const restored=!!document.getElementById('metric-cpuTemp') && !document.querySelector('#metric-grid > .empty');
          return {stable,noRemoval,focus,open,content,chartChanged,unavailable,hidden,shown,empty,restored};
        })()
        """) as? [String:Any])
        for key in ["stable","noRemoval","focus","open","content","chartChanged","unavailable","hidden","shown","empty","restored"] {
            #expect(details[key] as? Bool == true, "enhanced=\(enhanced), \(key): \(details)")
        }
    }
    _ = try await view.evaluateJavaScript("window.setComponentGlassEnabled(false)")
    let cards = try #require(try await view.evaluateJavaScript("""
    (()=>{
      const group=document.querySelector('.usage-summary'),cards=[...group.querySelectorAll('article')],style=getComputedStyle(group);
      return {gap:parseFloat(style.columnGap),background:style.backgroundColor,border:parseFloat(style.borderTopWidth),
        independent:cards.length===3 && cards.every(card=>{const s=getComputedStyle(card);return parseFloat(s.borderRadius)>0 && parseFloat(s.borderTopWidth)>0 && s.backgroundColor!=='rgba(0, 0, 0, 0)'})};
    })()
    """) as? [String:Any])
    #expect((cards["gap"] as? Double ?? 0) > 0)
    #expect(cards["background"] as? String == "rgba(0, 0, 0, 0)")
    #expect(cards["border"] as? Double == 0)
    #expect(cards["independent"] as? Bool == true)
}

private final class OverviewMessages: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
