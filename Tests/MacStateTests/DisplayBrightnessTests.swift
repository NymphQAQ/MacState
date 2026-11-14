import Foundation
import AppKit
import WebKit
import Testing
@testable import MacState

@Test func displayBrightnessFrameValidatesChecksumsAndBounds() {
    #expect(DisplayBrightnessMath.clamp(-45) == 0)
    #expect(DisplayBrightnessMath.clamp(67.5) == 68)
    #expect(DisplayBrightnessMath.clamp(222) == 100)
    #expect(DisplayBrightnessMath.clamp(.nan) == nil)
    #expect(DisplayBrightnessMath.clamp(.infinity) == nil)
    #expect(DisplayBrightnessMath.ddcWaitNanos(now:500_000_000,last:nil) == 0)
    #expect(DisplayBrightnessMath.ddcWaitNanos(now:500_000_000,last:480_000_000) == 65_000_000)
    #expect(DisplayBrightnessMath.ddcWaitNanos(now:500_000_000,last:400_000_000) == 0)
    #expect(DisplayBrightnessMath.ddcWaitNanos(now:20,last:40) == 0)
    #expect(DisplayBrightnessMath.ddcValue(percent:35,maximum:255) == 89)
    #expect(DisplayBrightnessMath.ddcValue(percent:100,maximum:75) == 75)
    #expect(DisplayBrightnessMath.ddcValue(percent:0,maximum:255) == 0)
    #expect(DisplayBrightnessMath.writeFrame(vcp:0x10,value:50).count == 6)
    #expect(DisplayBrightnessMath.readFrame(vcp:0x10).count == 4)
    #expect(DisplayBrightnessMath.writeFrame(vcp:0x10,value:50)
        .reduce(UInt8(0x6e ^ 0x51),^) == 0)
    #expect(DisplayBrightnessMath.readFrame(vcp:0x10)
        .reduce(UInt8(0x6e ^ 0x51),^) == 0)

    var response:[UInt8] = [0x6e,0x88,0x02,0x00,0x10,0x00,0x00,0x64,0x00,0x28]
    response.append(response.reduce(UInt8(0x50),^))
    let read=DisplayBrightnessMath.parseReply(response,vcp:0x10)
    #expect(read?.current == 40)
    #expect(read?.maximum == 100)
    var invalid=response;invalid[9]=0xff
    #expect(DisplayBrightnessMath.parseReply(invalid,vcp:0x10) == nil)
    invalid=response;invalid[4]=0x62
    #expect(DisplayBrightnessMath.parseReply(invalid,vcp:0x10) == nil)
    invalid=response;invalid[7]=0
    #expect(DisplayBrightnessMath.parseReply(invalid,vcp:0x10) == nil)
    #expect(DisplayBrightnessMath.parseReply(response,vcp:0x62) == nil)
    #expect(DisplayBrightnessMath.softwareFactor(0) >= 0.12)
    #expect(DisplayBrightnessMath.softwareFactor(100) == 1)
}


@Test func ddciReadFailureKeepsSafeHardwareWriteCandidate() {
    #expect(DisplayBrightnessMath.controlMode(hasNative: true,hasChannel: false,hasValidDDCRead: false,failedWrites: 0) == "system")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: true,hasValidDDCRead: true,failedWrites: 0) == "ddc")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: true,hasValidDDCRead: false,failedWrites: 0) == "ddcUnverified",
            "A failed VCP read cannot prove a monitor rejects VCP writes")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: true,hasValidDDCRead: false,failedWrites: 2) == "ddcUnverified",
            "Single flaky writes must not immediately switch to gamma")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: true,hasValidDDCRead: false,failedWrites: 3) == "software")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: false,hasValidDDCRead: false,failedWrites: 0) == "software")
    #expect(DisplayBrightnessMath.controlMode(hasNative: false,hasChannel: true,hasValidDDCRead: false,failedWrites: 0) != "software")
}

@Test func ambiguousDDCChannelsMustNotControlWrongScreen() {
    typealias Identity = DisplayBrightnessMath.Identity
    let first=Identity(vendor:1,product:2,serial:10)
    let second=Identity(vendor:1,product:2,serial:20)
    let same=Identity(vendor:1,product:2,serial:0)
    #expect(DisplayBrightnessMath.match(externals:[(3,first)],channels:[nil]) == [3:0])
    #expect(DisplayBrightnessMath.match(externals:[(3,first),(4,second)],
                                       channels:[second,first]) == [3:1,4:0])
    #expect(DisplayBrightnessMath.match(externals:[(3,same),(4,same)],
                                       channels:[same,same]).isEmpty)
    #expect(DisplayBrightnessMath.match(externals:[(3,first),(4,second)],
                                       channels:[nil]).isEmpty)
}


@Test @MainActor func displayBrightnessReadOnlyProbeFindsOnlineScreens() async {
    let service=DisplayBrightnessController()
    var received:[DisplayBrightnessRow]=[]
    service.onUpdate={rows in received=rows}
    service.refresh() // Read-only: do not call set(), never alter backlight/gamma.
    for _ in 0..<400 {
        if !received.isEmpty {break}
        try? await Task.sleep(nanoseconds:25_000_000)
    }
    #expect(!received.isEmpty)
    #expect(received.allSatisfy{!$0.id.isEmpty && (0...100).contains($0.percent)})
    for row in received {
        print("BRIGHTNESS_PROBE \(row.name) mode=\(row.mode) level=\(row.percent) detail=\(row.detail)")
    }
}

private final class BrightnessWebCapture: NSObject, WKScriptMessageHandler {
    var actions:[[String:Any]]=[]
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let data=message.body as? [String:Any] else{return}
        actions.append(data)
    }
}


@Test @MainActor func brightnessDragStreamsWritesBeforePointerRelease() async throws {
    let resource=try #require(Bundle.module.url(forResource:"Web",withExtension:nil))
    let receiver=BrightnessWebCapture()
    let configuration=WKWebViewConfiguration()
    configuration.userContentController.add(receiver,name:"macstate")
    let web=WKWebView(frame:NSRect(x:0,y:0,width:900,height:700),configuration:configuration)
    defer {configuration.userContentController.removeScriptMessageHandler(forName:"macstate")}
    web.loadFileURL(resource.appendingPathComponent("index.html"),allowingReadAccessTo:resource)
    var loaded=false
    for _ in 0..<125 {
        loaded=(try? await web.evaluateJavaScript(
          "document.readyState==='complete' && typeof window.receiveDisplayBrightness==='function'")) as? Bool == true
        if loaded {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    try #require(loaded)
    _=try await web.evaluateJavaScript("""
        window.receiveDisplayBrightness([{id:'drag-screen',name:'DDC 监视器',
          percent:50,mode:'ddcUnverified',valueKnown:false,detail:'DDC/CI'}]);
        const track=document.querySelector('[data-brightness-id="drag-screen"]');
        track.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
        track.value='44'; track.dispatchEvent(new Event('input',{bubbles:true}));
        """)
    // The first DDC update must not wait for a change or pointerup.
    for _ in 0..<4 {
        if receiver.actions.contains(where:{$0["action"] as? String == "setDisplayBrightness"}) {break}
        try await Task.sleep(nanoseconds:15_000_000)
    }
    var writes=receiver.actions.filter{$0["action"] as? String == "setDisplayBrightness"}
    #expect(writes.count >= 1,"Brightness should change while mouse is still down")
    #expect((writes.first?["percent"] as? NSNumber)?.intValue == 44)

    _=try await web.evaluateJavaScript("""
        const slider=document.querySelector('[data-brightness-id="drag-screen"]');
        slider.value='39'; slider.dispatchEvent(new Event('input',{bubbles:true}));
        slider.value='31'; slider.dispatchEvent(new Event('input',{bubbles:true}));
        slider.value='25'; slider.dispatchEvent(new Event('input',{bubbles:true}));
        """)
    try await Task.sleep(nanoseconds:108_000_000)
    writes=receiver.actions.filter{$0["action"] as? String == "setDisplayBrightness"}
    #expect(writes.count >= 2,"DDC values must continue streaming before release")
    #expect((writes.last?["percent"] as? NSNumber)?.intValue == 25)
    #expect(writes.count <= 3,"Coalesce obsolete drag values instead of flooding DDC")

    _=try await web.evaluateJavaScript("""
        const final=document.querySelector('[data-brightness-id="drag-screen"]');
        final.value='19'; final.dispatchEvent(new Event('input',{bubbles:true}));
        document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true}));
        final.dispatchEvent(new Event('change',{bubbles:true}));
        """)
    for _ in 0..<20 {
        writes=receiver.actions.filter{$0["action"] as? String == "setDisplayBrightness"}
        if (writes.last?["percent"] as? NSNumber)?.intValue == 19 {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    writes=receiver.actions.filter{$0["action"] as? String == "setDisplayBrightness"}
    #expect((writes.last?["percent"] as? NSNumber)?.intValue == 19,
            "The final pointer location must be committed")
    let finalWrites=writes.filter{($0["percent"] as? NSNumber)?.intValue == 19}
    #expect(finalWrites.count == 1,"Release and change must not double-send the final DDC value")
    #expect(try await web.evaluateJavaScript(
       "document.querySelector('[data-brightness-id=drag-screen]').value") as? String == "19")
}

@Test @MainActor func miscBrightnessControlsRenderAndSendOnlyExplicitUserChanges() async throws {
    let resource=try #require(Bundle.module.url(forResource:"Web",withExtension:nil))
    let capture=BrightnessWebCapture()
    let config=WKWebViewConfiguration()
    config.userContentController.add(capture,name:"macstate")
    let web=WKWebView(frame:NSRect(x:0,y:0,width:960,height:780),configuration:config)
    defer {config.userContentController.removeScriptMessageHandler(forName:"macstate")}
    web.loadFileURL(resource.appendingPathComponent("index.html"),allowingReadAccessTo:resource)
    var loaded=false
    for _ in 0..<150 {
        loaded=(try? await web.evaluateJavaScript(
            "document.readyState==='complete' && typeof window.receiveDisplayBrightness==='function'")) as? Bool == true
        if loaded {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    try #require(loaded)
    _=try await web.evaluateJavaScript("navigate('misc');")
    #expect((capture.actions.last { $0["action"] as? String == "getDisplayBrightness" }) != nil)
    _=try await web.evaluateJavaScript("""
       window.receiveDisplayBrightness([
         {id:'id-system',name:'MacBook 内建显示器',percent:64,mode:'system',detail:'系统背光'},
         {id:'id-external',name:'DM73u pro',percent:85,mode:'software',detail:'软件调暗 · 仅改变画面'},
         {id:'id-missing',name:'无亮度接口',percent:100,mode:'unavailable',detail:'不可调'}
       ]);
       """)
    #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-brightness-id]').length") as? Int == 3)
    #expect(try await web.evaluateJavaScript("document.querySelector('.mode-software').textContent") as? String == "软件调暗")
    #expect(try await web.evaluateJavaScript("document.querySelector('[data-brightness-id=id-missing]').disabled") as? Bool == true)
    #expect(try await web.evaluateJavaScript("document.querySelector('#brightness-status').textContent.includes('不会调整物理背光')") as? Bool == true)
    // Render/refresh must never write brightness without user action.
    #expect(capture.actions.filter{$0["action"] as? String == "setDisplayBrightness"}.isEmpty)
    _=try await web.evaluateJavaScript("document.getElementById('refresh-brightness').click()")
    for _ in 0..<30 {
        if capture.actions.contains(where:{$0["action"] as? String == "retryDisplayBrightness"}) {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    #expect(capture.actions.contains(where:{$0["action"] as? String == "retryDisplayBrightness"}))
    #expect(capture.actions.filter{$0["action"] as? String == "setDisplayBrightness"}.isEmpty)
    _=try await web.evaluateJavaScript("""
        const slider=document.querySelector('[data-brightness-id=id-external]');
        slider.value='40';
        slider.dispatchEvent(new Event('input',{bubbles:true}));
        slider.dispatchEvent(new Event('change',{bubbles:true}));
        """)
    for _ in 0..<35 {
        if capture.actions.contains(where:{$0["action"] as? String == "setDisplayBrightness"}) {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    let action=try #require(capture.actions.last(where:{$0["action"] as? String == "setDisplayBrightness"}))
    #expect(action["id"] as? String == "id-external")
    #expect((action["percent"] as? NSNumber)?.intValue == 40)
    #expect(try await web.evaluateJavaScript("document.querySelector('[data-brightness-id=id-external]').nextElementSibling.textContent") as? String == "40%")
    let image=try await web.takeSnapshot(configuration:nil)
    let tiff=try #require(image.tiffRepresentation)
    let bitmap=try #require(NSBitmapImageRep(data:tiff))
    let folder=URL(fileURLWithPath:"reports/display-brightness-2026-10-24")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    try #require(bitmap.representation(using:.png,properties:[:]))
        .write(to:folder.appendingPathComponent("misc-brightness.png"))

    let initialWrites=capture.actions.filter{$0["action"] as? String == "setDisplayBrightness"}.count
    _=try await web.evaluateJavaScript("""
       window.receiveDisplayBrightness([
         {id:'id-external',name:'DM73u pro',percent:50,valueKnown:false,
          mode:'ddcUnverified',detail:'DDC 通道已配对，但显示器未返回亮度读数'}
       ]);
       """)
    #expect(try await web.evaluateJavaScript(
        "document.querySelector('.mode-ddcUnverified').textContent") as? String == "DDC/CI 待读回")
    #expect(try await web.evaluateJavaScript(
        "document.querySelector('[data-brightness-id=id-external]').nextElementSibling.textContent") as? String == "—",
        "Do not claim a fabricated 50% is a measured brightness")
    #expect(try await web.evaluateJavaScript(
        "document.querySelector('[data-brightness-id=id-external]').disabled") as? Bool == false)
    #expect(try await web.evaluateJavaScript(
        "document.querySelector('#brightness-status').textContent.includes('首次拖动')") as? Bool == true)
    #expect(capture.actions.filter{$0["action"] as? String == "setDisplayBrightness"}.count == initialWrites,
        "Merely discovering write-only DDC must not move physical brightness")
    let unknownImage=try await web.takeSnapshot(configuration:nil)
    let unknownTiff=try #require(unknownImage.tiffRepresentation)
    let unknownBitmap=try #require(NSBitmapImageRep(data:unknownTiff))
    try #require(unknownBitmap.representation(using:.png,properties:[:]))
        .write(to:folder.appendingPathComponent("misc-brightness-ddc-unknown.png"))
    _=try await web.evaluateJavaScript("""
       const control=document.querySelector('[data-brightness-id=id-external]');
       control.value='60';
       control.dispatchEvent(new Event('input',{bubbles:true}));
       control.dispatchEvent(new Event('change',{bubbles:true}));
       """)
    for _ in 0..<35 {
        if capture.actions.filter({$0["action"] as? String == "setDisplayBrightness"}).count > initialWrites {break}
        try await Task.sleep(nanoseconds:20_000_000)
    }
    let newWrites=capture.actions.filter{$0["action"] as? String == "setDisplayBrightness"}
    #expect(newWrites.count == initialWrites + 1,
        "One deliberate drag/commit should send only one hardware command")
    #expect((newWrites.last?["percent"] as? NSNumber)?.intValue == 60)
}
