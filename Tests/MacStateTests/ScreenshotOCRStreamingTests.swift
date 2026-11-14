import AppKit
import CoreText
import Foundation
import Testing
@testable import MacState

private final class OCRStreamCredentials:ScreenshotOCRCredentialStore {
    func read(_ id:UUID) throws ->String? {"fixture"}
    func write(_ value:String?,for id:UUID) throws {}
}

private final class OCRStreamAPI:URLProtocol {
    static var head=Data(),tail=Data()
    static var gate=DispatchSemaphore(value:0)
    static var inspect:((URLRequest)->Void)?
    private let lock=NSLock()
    private var stopped=false
    private var waiting:DispatchSemaphore?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        let head=Self.head,tail=Self.tail,gate=Self.gate,inspect=Self.inspect
        lock.lock();waiting=gate;lock.unlock()
        DispatchQueue.global().async { [self] in
            inspect?(request)
            let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,
                headerFields:["Content-Type":"text/event-stream"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:head)
            if gate.wait(timeout:.now()+45) == .timedOut {
                client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return
            }
            lock.lock();let cancelled=stopped;lock.unlock()
            guard !cancelled else{return}
            // Split multi-byte UTF-8 text across transport chunks.
            for start in stride(from:0,to:tail.count,by:3) {
                client?.urlProtocol(self,didLoad:tail.subdata(in:start..<min(tail.count,start+3)))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock();stopped=true;let gate=waiting;lock.unlock();gate?.signal()
    }
}

@Suite(.serialized) @MainActor struct ScreenshotOCRStreamingTests {
    @Test func partialParagraphIsAvailableBeforeCompletion() {
        let progress=ScreenshotOCRRevealProgress()
        for text in ["The service’","The service’s full paragraph.","Le café","中文逐字显示，"] {
            progress.received[0]=text;#expect(progress.available(0)==text)
        }
        progress.received[0]="Last word";progress.finished.insert(0)
        #expect(progress.available(0)=="Last word")
        progress.received[1]="Final";progress.completed=true
        #expect(progress.available(1)=="Final")
        let reordered=ScreenshotOCRRevealProgress()
        reordered.received[1]="Later paragraph";reordered.finished.insert(1)
        #expect(reordered.next(count:2)==0,"Batch responses cannot display a later paragraph before the preceding one.")
        reordered.received[0]="First";reordered.finished.insert(0);reordered.shown[0]=5
        #expect(reordered.next(count:2)==1)
        reordered.shown[1]="Later paragraph".count
        #expect(reordered.next(count:2)==nil)
    }
    @Test func completedTranslationIsNotHeldInACharacterQueue() {
        let progress=ScreenshotOCRRevealProgress()
        progress.received[0]=String(repeating:"翻译",count:300)
        progress.finished.insert(0)
        for _ in 0..<8 { progress.advance(0) }
        #expect(progress.shown[0]==600,"A completed paragraph should finish displaying within eight frames.")
    }
    private func event(_ body:[String:Any]) throws ->String {
        let data=try JSONSerialization.data(withJSONObject:body)
        return "data: "+String(decoding:data,as:UTF8.self)+"\n\n"
    }
    private func wire(_ api:ScreenshotOCRAPIProtocol,finish:String?=nil) throws ->(String,String) {
        switch api {
        case .openAI,.azure:
            return (try event(["choices":[["delta":["content":"你好"]]]]),
                try event(["choices":[["delta":["reasoning_content":"private thinking"]]]]) +
                event(["choices":[["delta":["content":" 👋"]]]]) +
                event(["choices":[["delta":[:],"finish_reason":finish ?? "stop"]]]) + "data: [DONE]\n\n")
        case .anthropic:
            return (try event(["type":"content_block_delta","delta":["type":"text_delta","text":"你好"]]),
                try event(["type":"content_block_delta","delta":["type":"thinking_delta","thinking":"private thinking"]]) +
                event(["type":"content_block_delta","delta":["type":"text_delta","text":" 👋"]]) +
                event(["type":"message_delta","delta":["stop_reason":finish ?? "end_turn"]]) +
                event(["type":"message_stop"]))
        case .gemini:
            return (try event(["candidates":[["content":["parts":[["text":"你好"]]]]]]),
                try event(["candidates":[["content":["parts":[["thought":true,"text":"private thinking"],["text":" 👋"]]],
                                         "finishReason":finish ?? "STOP"]]]))
        }
    }
    private func install(_ api:ScreenshotOCRAPIProtocol = .openAI) throws ->URLSession {
        let parts=try wire(api)
        let newline=api == .azure ? "\r\n":api == .anthropic ? "\r":"\n"
        OCRStreamAPI.head=Data(parts.0.replacingOccurrences(of:"\n",with:newline).utf8)
        OCRStreamAPI.tail=Data(parts.1.replacingOccurrences(of:"\n",with:newline).utf8)
        OCRStreamAPI.gate=DispatchSemaphore(value:0);OCRStreamAPI.inspect=nil
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[OCRStreamAPI.self]
        return URLSession(configuration:configuration)
    }
    private func profile(_ api:ScreenshotOCRAPIProtocol = .openAI)->ScreenshotOCRLLMProfile {
        .init(name:"Fixture",api:api,baseURL:"https://example.invalid/v1",model:"fixture-model")
    }
    private func image() throws ->CGImage {
        let context=try #require(CGContext(data:nil,width:800,height:320,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:0,y:0,width:800,height:320))
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:"Hello translation!",attributes:[
            .font:NSFont.systemFont(ofSize:26),.foregroundColor:NSColor.white]))
        context.textPosition=CGPoint(x:40,y:230);CTLineDraw(line,context)
        return try #require(context.makeImage())
    }
    private func descendants(_ view:NSView)->[NSView] {view.subviews+view.subviews.flatMap{descendants($0)}}
    private func waitUntil(_ check:()->Bool) async throws {
        for _ in 0..<4500 {
            if check() {return}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        Issue.record("Timed out waiting for the OCR stream state.")
    }

    @Test func fourProtocolsRequestStreamingAndHonorBothLanguages() throws {
        for api in ScreenshotOCRAPIProtocol.allCases {
            let request=try ScreenshotOCRLLMService.request(profile:profile(api),apiKey:"fixture",
                text:"Original",target:"fr",source:"ja",stream:true)
            #expect(request.value(forHTTPHeaderField:"Accept")=="text/event-stream")
            let data=try #require(request.httpBody)
            let body=try #require(try JSONSerialization.jsonObject(with:data) as? [String:Any])
            if api == .gemini {
                #expect(request.url?.path.hasSuffix(":streamGenerateContent")==true)
                #expect(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.contains(
                    URLQueryItem(name:"alt",value:"sse"))==true)
            } else {#expect(body["stream"] as? Bool == true)}
            let payload=String(decoding:data,as:UTF8.self)
            #expect(payload.contains("日语") && payload.contains("法语"))
            #expect(!payload.contains("fixture-secret"))
        }
        #expect(ScreenshotOCRTranslationLanguage.supported.count>=30)
        #expect(ScreenshotOCRTranslationLanguage.defaultTarget(source:"zh-Hant")=="en")
        #expect(ScreenshotOCRTranslationLanguage.defaultTarget(source:"ja")=="zh-Hans")
        #expect(ScreenshotOCRTranslationLanguage.source(for:"Hello OCR")=="en")
        #expect(ScreenshotOCRTranslationLanguage.source(for:"Bonjour")=="fr")
        #expect(ScreenshotOCRTranslationLanguage.source(for:"Selamat pagi")=="id")
        let deepseek=ScreenshotOCRLLMProfile(name:"DeepSeek",baseURL:"https://api.deepseek.com/v1",model:"deepseek-flash")
        let request=try ScreenshotOCRLLMService.request(profile:deepseek,apiKey:"fixture",text:"Hello",target:"zh-Hans",stream:true)
        let bytes=try #require(request.httpBody)
        let body=try #require(try JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        #expect((body["thinking"] as? [String:String])?["type"]=="disabled")
    }

    @Test func decodersKeepVisibleTextAndRejectBrokenOrTruncatedStreams() throws {
        for api in ScreenshotOCRAPIProtocol.allCases {
            let parts=try wire(api)
            var decoder=ScreenshotOCRStreamDecoder(api:api)
            for line in (parts.0+parts.1).components(separatedBy:"\n") {_ = try decoder.consume(line)}
            let completed=try decoder.completedText()
            #expect(completed=="你好 👋")
            var broken=ScreenshotOCRStreamDecoder(api:api)
            for line in parts.0.components(separatedBy:"\n") {_ = try broken.consume(line)}
            #expect(throws:ScreenshotOCRTranslationError.self) {try broken.completedText()}
            let truncated=try wire(api,finish:api == .gemini ? "MAX_TOKENS":api == .anthropic ? "max_tokens":"length")
            #expect(throws:ScreenshotOCRTranslationError.self) {
                var value=ScreenshotOCRStreamDecoder(api:api)
                for line in (truncated.0+truncated.1).components(separatedBy:"\n") {_ = try value.consume(line)}
                _ = try value.completedText()
            }
        }
        var error=ScreenshotOCRStreamDecoder(api:.openAI)
        #expect(throws:ScreenshotOCRTranslationError.self) {
            _ = try error.consume("data: {\"error\":{\"message\":\"fixture-secret\"}}")
            _ = try error.consume("")
        }
        var multiline=ScreenshotOCRStreamDecoder(api:.openAI)
        for line in [": ping","event: message","data: {\"choices\":","data: [{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}",""] {
            _ = try multiline.consume(line)
        }
        let completed=try multiline.completedText()
        #expect(completed=="OK")
    }

    @Test func nativeNetworkReceivesPartialUTF8BeforeTheResponseEnds() async throws {
        for api in ScreenshotOCRAPIProtocol.allCases {
            let session=try install(api);defer{session.invalidateAndCancel()}
            let gate=OCRStreamAPI.gate
            var updates:[String]=[]
            var completed:[Int]=[]
            let translated=try await ScreenshotOCRLLMService(session:session).translate([
                .init(text:"Hello",rect:NSRect(x:20,y:20,width:250,height:30),lineHeight:26)
            ],target:"zh-Hans",profile:profile(api),apiKey:"fixture",onProgress:{ _,text in
                updates.append(text)
                if text == "你好" {gate.signal()}
            },onSegmentComplete:{ completed.append($0) })
            #expect(updates.first=="你好")
            #expect(translated.first?.text=="你好 👋")
            #expect(completed==[0])
            #expect(updates.allSatisfy{!$0.contains("private thinking")})
        }
    }

    @Test func oneClickRecognizesStreamsThenSelectsAllAndKeepsTheOCRPanel() async throws {
        _ = NSApplication.shared
        let suite="OCR-stream-view-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer{defaults.removePersistentDomain(forName:suite)}
        let store=ScreenshotOCRTranslationPreferences(defaults:defaults,credentials:OCRStreamCredentials())
        let selected=profile()
        try store.save(.init(profiles:[selected],selectedID:selected.id),keys:[:])
        let session=try install();defer{session.invalidateAndCancel()}
        let source=NSRect(x:50,y:60,width:800,height:320)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:750),image:try image(),selection:source,
            preferences:defaults,sourceRect:source,translationPreferences:store,translationClient:.init(session:session))
        let toolbar=try #require(view.subviews.first{$0.frame==view.editorToolbarFrameForTesting})
        let buttons=toolbar.subviews.compactMap{$0 as?NSButton}
        let ids=buttons.compactMap{$0.identifier?.rawValue}
        let ocr=try #require(ids.firstIndex(of:"ocr"))
        #expect(ids[ocr+1]=="translate")
        view.performAction("translate")
        try await waitUntil {view.ocrTranslatingForTesting}
        try await waitUntil {view.ocrTranslationOverlaysForTesting.first?.text=="你好"}
        #expect(view.ocrModeForTesting && view.ocrTranslatingForTesting)
        let partial=try #require(view.ocrTranslationOverlaysForTesting.first)
        #expect(!partial.sourceFullyReplaced,"The unreturned part of the original must remain visible.")
        let rects=partial.replacementRects(sourceRows:partial.sourceLines)
        #expect(rects.allSatisfy{$0.maxX<partial.sourceRect.maxX},"Only the area occupied by translated text is covered while the source is incomplete.")
        let partialFolder=URL(fileURLWithPath:"reports/ocr-live-replacement-2026-10-29")
        try FileManager.default.createDirectory(at:partialFolder,withIntermediateDirectories:true)
        let partialImage=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:partialImage)
        let sx=CGFloat(partialImage.pixelsWide)/view.bounds.width,sy=CGFloat(partialImage.pixelsHigh)/view.bounds.height
        let tail=NSRect(x:partial.sourceRect.midX,y:partial.sourceRect.minY,
            width:partial.sourceRect.width/2,height:partial.sourceRect.height)
        var lightPixels=0
        for y in max(0,Int(tail.minY*sy))..<min(partialImage.pixelsHigh,Int(tail.maxY*sy)) {
            for x in max(0,Int(tail.minX*sx))..<min(partialImage.pixelsWide,Int(tail.maxX*sx)) {
                if let color=partialImage.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
                    color.redComponent>0.7 && color.greenComponent>0.7 && color.blueComponent>0.7 {lightPixels+=1}
            }
        }
        #expect(lightPixels>10,"Original glyphs beyond the current translated prefix must remain visible.")
        try #require(partialImage.representation(using:.png,properties:[:])).write(to:partialFolder.appendingPathComponent("partial.png"))
        let copy=try #require(descendants(view).compactMap{$0 as?NSButton}.first{$0.identifier?.rawValue=="copyOCRSelection"})
        #expect(!copy.isEnabled)
        OCRStreamAPI.gate.signal()
        try await waitUntil {!view.ocrTranslatingForTesting}
        let background=try #require(view.ocrTranslationOverlaysForTesting.first?.backgroundColor)
        #expect(background.alphaComponent==1 && background.redComponent<0.01)
        #expect(view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.allSatisfy{$0.backgroundColor?.isEqual(background)==true})
        #expect(view.ocrSelectionForTesting=="你好 👋")
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType:.string)=="你好 👋")
        let toggle=try #require(descendants(view).compactMap{$0 as?NSButton}.first{$0.identifier?.rawValue=="translateOCR"})
        toggle.performClick(nil)
        #expect(!view.ocrShowingTranslationForTesting && !view.ocrSelectionForTesting.isEmpty)
        toggle.performClick(nil)
        #expect(view.ocrSelectionForTesting=="你好 👋")
        let folder=URL(fileURLWithPath:"reports/ocr-streaming-2026-10-28")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let bitmap=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("one-click-translated.png"))
        view.performAction("ocr")
    }

    @Test func multilineStreamRevealsCharactersAndKeepsPublishedRowsFixed() async throws {
        let suite="OCR-stable-stream-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        let store=ScreenshotOCRTranslationPreferences(defaults:defaults,credentials:OCRStreamCredentials())
        let selected=profile();try store.save(.init(profiles:[selected],selectedID:selected.id),keys:[:])
        let session=try install();defer{session.invalidateAndCancel();OCRStreamAPI.gate.signal()}
        let head="更高的亮度：XDR 款 MacBook 显示屏以及 HDR 显示器能够实现超过 100% 的亮度输出；每一个新字都应该紧接前面，填满这一行以后再换行。"
        let tail=" 后续的文字继续向后追加，之前已经读过的文字不能重新分行，也不能改变字号和位置。"
        OCRStreamAPI.head=Data(try event(["choices":[["delta":["content":head]]]]).utf8)
        OCRStreamAPI.tail=Data((try event(["choices":[["delta":["content":tail]]]]) +
            event(["choices":[["delta":[:],"finish_reason":"stop"]]]) + "data: [DONE]\n\n").utf8)
        let source=NSRect(x:50,y:60,width:800,height:500)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:850),image:try image(),selection:source,
            preferences:defaults,sourceRect:source,translationPreferences:store,translationClient:.init(session:session))
        view.installOCRForTesting([0.12,0.20,0.28].enumerated().map { index,y in
            .init(text:["Higher brightness: XDR MacBook displays and HDR screens", "can exceed their normal brightness limits,", "and keep output readable."][index],
                rect:NSRect(x:0.08,y:y,width:index==2 ? 0.30:0.80,height:0.05))
        })
        view.performAction("translate")
        OCRStreamAPI.gate.signal()
        try await waitUntil {!(view.ocrTranslationOverlaysForTesting.first?.text.isEmpty ?? true)}
        let first=try #require(view.ocrTranslationOverlaysForTesting.first)
        #expect(first.text.count<head.count,"A network chunk must be revealed progressively instead of appearing as a whole block.")
        #expect(first.lines.count==1,"The first characters must not be spread over the source's three rows.")
        var previous=first
        let folder=URL(fileURLWithPath:"reports/ocr-stable-stream-2026-10-29")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        func save(_ name:String) throws {
            let bitmap=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name))
        }
        try save("01-first-characters.png")
        var savedMiddle=false
        while view.ocrTranslatingForTesting {
            try await Task.sleep(nanoseconds:25_000_000)
            guard let current=view.ocrTranslationOverlaysForTesting.first else{continue}
            for (old,new) in zip(previous.lines,current.lines) {
                #expect(new.text.hasPrefix(old.text),"Published characters must stay on their existing row.")
                #expect(abs(old.rect.minX-new.rect.minX)<0.01 && abs(old.rect.minY-new.rect.minY)<0.01)
                #expect(abs(old.fontSize-new.fontSize)<0.01)
            }
            previous=current
            if !savedMiddle,current.text.count>=35 {try save("02-continuing.png");savedMiddle=true}
        }
        let final=try #require(view.ocrTranslationOverlaysForTesting.first)
        #expect(final.text==head+tail)
        #expect(final.lines.count>1)
        #expect(final.lines[0].rect.width>source.width*0.65,"Fill the column before creating another row.")
        #expect(final.lines.map(\.text).joined().filter{!$0.isWhitespace}==(head+tail).filter{!$0.isWhitespace})
        try save("03-completed.png")
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType:.string)?.filter{!$0.isWhitespace}==(head+tail).filter{!$0.isWhitespace})
        view.performAction("ocr")
    }

    @Test func cancelStopsQueuedCharactersAfterNetworkCompletion() async throws {
        let suite="OCR-cancel-reveal-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        let store=ScreenshotOCRTranslationPreferences(defaults:defaults,credentials:OCRStreamCredentials())
        let selected=profile();try store.save(.init(profiles:[selected],selectedID:selected.id),keys:[:])
        let session=try install();defer{session.invalidateAndCancel();OCRStreamAPI.gate.signal()}
        OCRStreamAPI.head=Data(try event(["choices":[["delta":["content":String(repeating:"后续文字",count:100)]]]]).utf8)
        OCRStreamAPI.tail=Data((try event(["choices":[["delta":[:],"finish_reason":"stop"]]])+"data: [DONE]\n\n").utf8)
        let source=NSRect(x:50,y:60,width:800,height:320)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:750),image:try image(),selection:source,
            preferences:defaults,sourceRect:source,translationPreferences:store,translationClient:.init(session:session))
        view.installOCRForTesting([.init(text:"Original text",rect:NSRect(x:0.08,y:0.15,width:0.8,height:0.1))])
        view.performAction("translate");OCRStreamAPI.gate.signal()
        try await waitUntil {!(view.ocrTranslationOverlaysForTesting.first?.text.isEmpty ?? true)}
        #expect(view.ocrTranslatingForTesting)
        view.performAction("ocr")
        try await Task.sleep(nanoseconds:150_000_000)
        #expect(!view.ocrModeForTesting && !view.ocrTranslatingForTesting && !view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.isEmpty)
    }

    @Test func adaptiveOverflowScrollsSelectsAndCopiesTheCompleteTranslation() throws {
        let suite="OCR-overflow-reveal-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        let text=String(repeating:"完整译文继续逐字显示。",count:300)
        let source=NSRect(x:50,y:60,width:800,height:80)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:500),image:try image(),selection:source,
            preferences:defaults,sourceRect:source)
        view.installOCRForTesting([.init(text:"Original text",rect:NSRect(x:0.08,y:0.15,width:0.8,height:0.3))])
        view.installOCRTranslationsForTesting([text],streamingTarget:"zh-Hans")
        let overlay=try #require(view.ocrTranslationOverlaysForTesting.first)
        #expect(!overlay.isTruncated && overlay.lines.map(\.text).joined()==text)
        #expect(view.ocrTranslationContentRectForTesting.height>source.height)
        let scroller=try #require(descendants(view).compactMap{$0 as?NSScroller}.first{$0.identifier?.rawValue=="ocrTranslationScroller"})
        #expect(scroller.isEnabled && !scroller.isHidden && scroller.knobProportion<1)
        #expect(descendants(view).compactMap{$0 as?NSTextField}.contains{$0.stringValue.contains("滚动查看全文")})
        func save(_ name:String) throws {
            let bitmap=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let folder=URL(fileURLWithPath:"reports/ocr-adaptive-anchors-2026-10-29")
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name))
        }
        try save("scroll-top.png")
        let copy=try #require(descendants(view).compactMap{$0 as?NSButton}.first{$0.identifier?.rawValue=="copyOCRAll"})
        copy.performClick(nil)
        #expect(NSPasteboard.general.string(forType:.string)==text)
        let end=try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:119))
        view.keyDown(with:end)
        #expect(view.ocrTranslationScrollOffsetForTesting>0)
        let last=try #require(overlay.lines.last)
        let y=last.rect.midY-view.ocrTranslationScrollOffsetForTesting
        #expect(y>source.minY && y<source.maxY)
        try save("scroll-bottom.png")
        func mouse(_ kind:NSEvent.EventType,_ x:CGFloat) throws ->NSEvent {
            try #require(NSEvent.mouseEvent(with:kind,location:view.convert(NSPoint(x:x,y:y),to:nil),
                modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        view.mouseDown(with:try mouse(.leftMouseDown,last.rect.minX))
        view.mouseDragged(with:try mouse(.leftMouseDragged,last.rect.maxX))
        view.mouseUp(with:try mouse(.leftMouseUp,last.rect.maxX))
        #expect(view.ocrSelectionForTesting==last.text,"Scrolled hit testing must select the visible last row.")
        view.copy(nil);#expect(NSPasteboard.general.string(forType:.string)==last.text)
        let toggle=try #require(descendants(view).compactMap{$0 as?NSButton}.first{$0.identifier?.rawValue=="translateOCR"})
        toggle.performClick(nil);#expect(!view.ocrShowingTranslationForTesting && scroller.isHidden)
        toggle.performClick(nil);#expect(view.ocrShowingTranslationForTesting && !scroller.isHidden)
        view.performAction("ocr")
    }

    @Test func englishParagraphWaitsForItsFinalSizeThenRevealsWithoutReflow() async throws {
        let suite="OCR-word-stream-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        let store=ScreenshotOCRTranslationPreferences(defaults:defaults,credentials:OCRStreamCredentials())
        let selected=profile();try store.save(.init(profiles:[selected],selectedID:selected.id),keys:[:])
        let session=try install();defer{session.invalidateAndCancel();OCRStreamAPI.gate.signal()}
        let head="The quick brown fox jumps over the extraor",tail="dinary fence. Earlier words remain on their original rows."
        OCRStreamAPI.head=Data(try event(["choices":[["delta":["content":head]]]]).utf8)
        OCRStreamAPI.tail=Data((try event(["choices":[["delta":["content":tail]]]]) +
            event(["choices":[["delta":[:],"finish_reason":"stop"]]]) + "data: [DONE]\n\n").utf8)
        let source=NSRect(x:50,y:60,width:320,height:260)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:750,height:650),image:try image(),selection:source,
            preferences:defaults,sourceRect:source,translationPreferences:store,translationClient:.init(session:session))
        view.installOCRForTesting([.init(text:"这是一段需要翻译的中文原文。",rect:NSRect(x:0.08,y:0.12,width:0.80,height:0.12))])
        view.performAction("translate")
        try await waitUntil {view.ocrTranslatingForTesting}
        try await waitUntil {view.ocrTranslationOverlaysForTesting.first?.text==head}
        #expect(view.ocrTranslatingForTesting,"The first network chunk must appear while the response is still open.")
        OCRStreamAPI.gate.signal()
        try await waitUntil {!(view.ocrTranslationOverlaysForTesting.first?.text.isEmpty ?? true)}
        var previous=try #require(view.ocrTranslationOverlaysForTesting.first)
        #expect(previous.text.count<(head+tail).count)
        while view.ocrTranslatingForTesting {
            try await Task.sleep(nanoseconds:25_000_000)
            guard let current=view.ocrTranslationOverlaysForTesting.first else{continue}
            for (old,new) in zip(previous.lines,current.lines) {
                #expect(new.text.hasPrefix(old.text))
                #expect(old.rect.origin==new.rect.origin && old.fontSize==new.fontSize)
            }
            previous=current
        }
        #expect(previous.text==head+tail)
        #expect(previous.lines.map(\.text).joined().contains("extraordinary"))
        view.performAction("ocr")
    }

    @Test func changingLanguagesIsVisibleBeforeTranslatingAndCancelsOldResults() async throws {
        let suite="OCR-stream-language-\(UUID())"
        let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        let store=ScreenshotOCRTranslationPreferences(defaults:defaults,credentials:OCRStreamCredentials())
        let selected=profile();try store.save(.init(profiles:[selected],selectedID:selected.id),keys:[:])
        let session=try install();defer{session.invalidateAndCancel()}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1000,height:700),image:try image(),
            selection:NSRect(x:50,y:60,width:800,height:320),preferences:defaults,
            translationPreferences:store,translationClient:.init(session:session))
        view.installOCRForTesting([.init(text:"这是中文原文。",rect:NSRect(x:0.1,y:0.1,width:0.4,height:0.1))])
        let popups=descendants(view).compactMap{$0 as?NSPopUpButton}
        let source=try #require(popups.first{$0.identifier?.rawValue=="ocrSourceLanguage"})
        let target=try #require(popups.first{$0.identifier?.rawValue=="ocrTargetLanguage"})
        #expect(source.title.contains("自动识别") && source.title.contains("中文"))
        #expect(target.title.contains("英语"))
        source.selectItem(withTitle:"日语");_ = source.sendAction(source.action,to:source.target)
        #expect(target.title.contains("简体中文"))
        target.selectItem(withTitle:"法语");_ = target.sendAction(target.action,to:target.target)
        #expect(source.title=="日语" && target.title=="法语")
        view.performAction("translate")
        try await waitUntil {view.ocrTranslatingForTesting}
        view.performAction("ocr")
        OCRStreamAPI.gate.signal()
        try await Task.sleep(nanoseconds:100_000_000)
        #expect(!view.ocrModeForTesting && !view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.isEmpty)
    }
}
