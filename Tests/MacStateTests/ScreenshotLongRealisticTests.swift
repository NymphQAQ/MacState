import AppKit
import WebKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor struct ScreenshotLongRealisticTests {
    // Dark document with small anti-aliased Chinese/Latin glyphs, similar to
    // an actual text-heavy browser screenshot on a 2x Retina display.
    static func document(width:Int=880,height:Int=2800) throws -> CGImage {
        let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,
                                                  bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                                                  colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context=try #require(NSGraphicsContext(bitmapImageRep:bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=context
        NSColor(calibratedWhite:0.045,alpha:1).setFill()
        NSRect(x:0,y:0,width:width,height:height).fill()
        for line in 0..<60 {
            let y=CGFloat(line*46+15)
            let length=CGFloat(250+(line*283 % 550))
            let label="长截屏滚动测试 - paragraph \(line) - This is text in the screenshot. 长截图自动/手动"
            let attrs:[NSAttributedString.Key:Any]=[
                .font:NSFont.systemFont(ofSize:CGFloat(13+line%4),weight:.regular),
                .foregroundColor:NSColor(calibratedWhite:CGFloat(0.65+Double(line%4)*0.08),alpha:1)
            ]
            (label as NSString).draw(in:NSRect(x:18,y:y,width:length,height:32),withAttributes:attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.cgImage)
    }

    @Test func screenCaptureKitReceivesTopLeftDisplayCoordinates() {
        let selected=CGRect(x:830,y:120,width:440,height:340)
        let converted=ScreenshotCaptureCoordinates.quartzRect(appKitRect:selected,primaryScreenTop:1080)
        #expect(converted == CGRect(x:830,y:620,width:440,height:340))
        let upperDisplay=CGRect(x:-200,y:1190,width:580,height:480)
        #expect(ScreenshotCaptureCoordinates.quartzRect(appKitRect:upperDisplay,primaryScreenTop:1080)
                == CGRect(x:-200,y:-590,width:580,height:480))
    }

    @Test func retinaTextScrollingByNormalWheelIncrementsStitches() throws {
        let page=try Self.document()
        let viewportHeight=680
        for offset in [71,127,173,257,333] {
            let first=try #require(page.cropping(to:CGRect(x:0,y:0,width:880,height:viewportHeight)))
            let second=try #require(page.cropping(to:CGRect(x:0,y:offset,width:880,height:viewportHeight)))
            let actual=ScreenshotLongStitcher.verticalShift(previous:first,next:second)
            #expect(actual == offset, "scroll offset \(offset) was recognized as \(String(describing:actual))")
        }
    }

    @Test func actualWebKitTextPageScrollProducesStitchableFrames() async throws {
        let web=WKWebView(frame:NSRect(x:0,y:0,width:750,height:540))
        let paragraphs=(0..<95).map { index in
            "<p>第\(index)段，MacState长截图滚动验证。Different paragraph \(index) — \(index*97+211) text and some <strong>bold highlights</strong>. 使用真实网页文字和布局检查上下滚动的像素拼接准确性。</p>"
        }.joined()
        web.loadHTMLString("""
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{padding:0;margin:0;background:#16191e;color:#e0e5ed}
        main{padding:20px 35px;font-family:-apple-system,sans-serif;font-size:15px;line-height:1.55}
        p{padding:0 0 6px;margin:0 0 22px;border-bottom:1px solid #37424d}</style></head>
        <body><main>\(paragraphs)</main></body></html>
        """,baseURL:nil)
        for _ in 0..<150 {
            let status=try? await web.evaluateJavaScript("document.readyState") as? String
            if status=="complete" {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        try #require((try await web.evaluateJavaScript("document.readyState")) as? String == "complete")
        // WebKit's readyState can become "complete" before its offscreen
        // page has actually produced a scrollable layout under test load.
        for _ in 0..<150 {
            let height=(try? await web.evaluateJavaScript(
                "Math.max(document.body.scrollHeight,document.documentElement.scrollHeight)"
            )) as? Double ?? 0
            if height > 1800 {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        let pageHeight=(try await web.evaluateJavaScript(
            "Math.max(document.body.scrollHeight,document.documentElement.scrollHeight)"
        )) as? Double ?? 0
        try #require(pageHeight > 1800)
        try await Task.sleep(nanoseconds:220_000_000)
        func snapshot() async throws -> CGImage {
            try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with:nil) { image,error in
                    if let image,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) {
                        continuation.resume(returning:cg)
                    } else {
                        continuation.resume(throwing:error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
        }
        let original=try await snapshot()
        _ = try await web.evaluateJavaScript("window.scrollTo(0,133)")
        try await Task.sleep(nanoseconds:180_000_000)
        let moved=try await snapshot()
        let factor=CGFloat(original.height)/CGFloat(web.frame.height)
        let expected=Int((133*factor).rounded())
        var stitch=ScreenshotLongStitcher(first:original)
        #expect(try stitch.append(moved)==expected)
        _ = try await web.evaluateJavaScript("window.scrollTo(0,293)")
        try await Task.sleep(nanoseconds:180_000_000)
        let third=try await snapshot()
        let nextShift=Int((160*factor).rounded())
        #expect(try stitch.append(third)==nextShift)
        #expect(stitch.frames==3)
        #expect(stitch.height==original.height+expected+nextShift)
        let composed=try stitch.compose()
        #expect(composed.width==original.width)
        #expect(composed.height==stitch.height)
    }

    @Test func realWebKitScrollUpAfterDownExtendsOnlyUncapturedTop() async throws {
        let web=WKWebView(frame:NSRect(x:0,y:0,width:720,height:520))
        let rows=(0..<110).map { index in
            let red=26+(index*43)%48,green=30+(index*17)%50,blue=41+(index*37)%55
            let paragraph=String(repeating:"不同长度的内容 \(index*113+17) ｜ ",count:1+index%6)
            return "<p style='background:rgb(\(red),\(green),\(blue))'>长截图双向测试 \(index)：\(paragraph) 上滑补齐上面的段落，下滑补齐下面的段落。</p>"
        }.joined()
        web.loadHTMLString("""
        <html><head><style>
        html,body{background:#121820;color:#e3eaf1;margin:0;padding:0}
        main{padding:24px;font:15px/1.5 -apple-system,sans-serif}
        p{margin:0 0 22px;padding:0 0 12px;border-bottom:1px solid #3c4855}
        </style></head><body><main>\(rows)</main></body></html>
        """,baseURL:nil)
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript("document.readyState") as? String)=="complete" {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        try #require((try await web.evaluateJavaScript("document.readyState")) as? String == "complete")
        // WebKit's readyState can become "complete" before its offscreen
        // page has actually produced a scrollable layout under test load.
        for _ in 0..<150 {
            let height=(try? await web.evaluateJavaScript(
                "Math.max(document.body.scrollHeight,document.documentElement.scrollHeight)"
            )) as? Double ?? 0
            if height > 1800 {break}
            try await Task.sleep(nanoseconds:20_000_000)
        }
        let pageHeight=(try await web.evaluateJavaScript(
            "Math.max(document.body.scrollHeight,document.documentElement.scrollHeight)"
        )) as? Double ?? 0
        try #require(pageHeight > 1800)
        try await Task.sleep(nanoseconds:220_000_000)
        func frame(at scrollY:Int) async throws -> CGImage {
            _ = try await web.evaluateJavaScript("window.scrollTo(0,\(scrollY))")
            try await Task.sleep(nanoseconds:150_000_000)
            return try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<CGImage,Error>) in
                web.takeSnapshot(with:nil) { image,error in
                    if let image,let bitmap=image.cgImage(forProposedRect:nil,context:nil,hints:nil) {
                        continuation.resume(returning:bitmap)
                    } else {continuation.resume(throwing:error ?? CocoaError(.fileReadUnknown))}
                }
            }
        }
        let first=try await frame(at:420)
        let factor=CGFloat(first.height)/web.frame.height
        func px(_ points:Int)->Int {Int((CGFloat(points)*factor).rounded())}
        var stitch=ScreenshotLongStitcher(first:first)
        let down=try await frame(at:600)
        #expect(try stitch.incorporate(down) == .extendedBottom(px(180)))
        let back=try await frame(at:500)
        #expect(try stitch.incorporate(back) == .revisited)
        let upper=try await frame(at:270)
        #expect(try stitch.incorporate(upper) == .extendedTop(px(150)))
        let top=try await frame(at:100)
        #expect(try stitch.incorporate(top) == .extendedTop(px(170)))
        #expect(stitch.frames==4)
        #expect(stitch.height==first.height+px(180)+px(150)+px(170))
        let composed=try stitch.compose()
        #expect(composed.height==stitch.height)
        #expect(composed.width==first.width)
    }

    @Test func changedOnlySmallHeaderDoesNotBecomeFakeScroll() throws {
        let page=try Self.document()
        let first=try #require(page.cropping(to:CGRect(x:0,y:0,width:880,height:680)))
        #expect(ScreenshotLongStitcher.verticalShift(previous:first,next:first) == nil)
    }
}
