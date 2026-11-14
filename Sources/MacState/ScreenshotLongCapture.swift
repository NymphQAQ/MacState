import AppKit
import ScreenCaptureKit
import ImageIO

/// Translates an AppKit selection (origin at the lower-left of the primary
/// screen) to ScreenCaptureKit/Quartz global display coordinates (upper-left).
/// The same rectangle must drive snapshots, legacy capture, and scroll events.
enum ScreenshotCaptureCoordinates {
    static func quartzRect(appKitRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x:appKitRect.minX,
               y:primaryScreenTop-appKitRect.maxY,
               width:appKitRect.width,height:appKitRect.height)
    }
}

/// Keeps a contiguous interval of original pixels. New rows extend either
/// the top or bottom; revisit frames never duplicate captured pixels.
/// Full-resolution composition happens only on Stop (bounded by 100 MP).
struct ScreenshotLongStitcher {
    enum StitchError: LocalizedError {
        case incompatibleSize, tooLarge, unableToCompose
        var errorDescription: String? {
            switch self {
            case .incompatibleSize: return "滚动区域尺寸发生变化，请重新框选。"
            case .tooLarge: return "长截图已达到 1 亿像素限制，请停止并保存。"
            case .unableToCompose: return "长截图合成失败，可能是内存不足。"
            }
        }
    }

    enum Change: Equatable {
        case extendedTop(Int)
        case extendedBottom(Int)
        case revisited
        case unmatched

        var addedPixels: Int? {
            switch self {
            case .extendedTop(let count), .extendedBottom(let count): return count
            case .revisited, .unmatched: return nil
            }
        }
    }

    private(set) var lastFrame: CGImage
    private(set) var height: Int
    private(set) var sections: [CGImage]
    private(set) var frames = 1
    /// Latest live viewport offset from the stitched image's upper edge.
    private(set) var viewportTop = 0
    // Cached greyscale thumbnail of the last accepted frame. Avoids a
    // redundant CoreGraphics resampling on every capture tick.
    private var lastGraySample: [UInt8]?
    var width: Int { lastFrame.width }

    init(first: CGImage) {
        lastFrame = first; height = first.height; sections = [first]
    }

    /// Existing callers receive the number of genuinely new pixels.
    mutating func append(_ next: CGImage) throws -> Int? {
        try incorporate(next).addedPixels
    }

    /// A revisit updates the live cursor without changing captured pixels.
    /// This makes it possible to go down, return to the middle, then extend
    /// above the initial viewport without duplicating any rows.
    mutating func incorporate(_ next: CGImage) throws -> Change {
        guard next.width == width, next.height == lastFrame.height else {
            throw StitchError.incompatibleSize
        }
        let sampleWidth=Self.sampleWidth(for:width)
        guard let previous=lastGraySample ??
                  Self.sample(lastFrame,width:sampleWidth,height:lastFrame.height),
              let upcoming=Self.sample(next,width:sampleWidth,height:next.height) else {
            return .unmatched
        }
        if lastGraySample == nil {lastGraySample=previous}
        guard let shift=Self.displacement(previous,upcoming,width:sampleWidth,height:next.height) else {
            return .unmatched
        }
        let incomingTop = viewportTop + shift
        let incomingBottom = incomingTop + next.height
        let prepend = max(0, -incomingTop)
        let append = max(0, incomingBottom - height)
        let added = prepend + append
        guard Double(width)*Double(height+added) <= 100_000_000 else {
            throw StitchError.tooLarge
        }

        if prepend > 0 {
            guard let head = next.cropping(to:CGRect(x:0,y:0,width:width,height:prepend)) else {
                throw StitchError.unableToCompose
            }
            sections.insert(head,at:0)
        }
        if append > 0 {
            guard let tail = next.cropping(to:CGRect(x:0,y:next.height-append,width:width,height:append)) else {
                throw StitchError.unableToCompose
            }
            sections.append(tail)
        }
        height += added
        viewportTop = incomingTop + prepend
        lastFrame = next
        lastGraySample = upcoming
        if added > 0 { frames += 1 }
        if prepend > 0 { return .extendedTop(prepend) }
        if append > 0 { return .extendedBottom(append) }
        return .revisited
    }

    func compose() throws -> CGImage {
        guard Double(width)*Double(height) <= 100_000_000,
              let space = lastFrame.colorSpace ?? CGColorSpace(name:CGColorSpace.sRGB),
              let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
                                  bytesPerRow:0,space:space,
                                  bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StitchError.unableToCompose
        }
        var top = height
        for section in sections {
            top -= section.height
            ctx.draw(section,in:CGRect(x:0,y:top,width:section.width,height:section.height))
        }
        guard let result=ctx.makeImage() else {throw StitchError.unableToCompose}
        return result
    }

    private struct MotionMatch {
        let pixels: Int
        let score: Double
    }

    /// Backwards-compatible downward-only estimate.
    static func verticalShift(previous:CGImage,next:CGImage) -> Int? {
        guard let shift=verticalDisplacement(previous:previous,next:next),shift>0 else {return nil}
        return shift
    }

    /// Positive = page content moved upward (scroll down); negative = page
    /// content moved downward (scroll up). Samples are shared for both tests;
    /// large blank areas never count as matching evidence.
    static func verticalDisplacement(previous:CGImage,next:CGImage) -> Int? {
        guard previous.width==next.width,previous.height==next.height,
              previous.height>=100 else{return nil}
        let height=previous.height,width=sampleWidth(for:previous.width)
        guard let a=sample(previous,width:width,height:height),
              let b=sample(next,width:width,height:height) else{return nil}
        return displacement(a,b,width:width,height:height)
    }

    private static func sampleWidth(for pixelWidth:Int)->Int {
        min(128,max(72,pixelWidth/7))
    }

    private static func displacement(_ a:[UInt8],_ b:[UInt8],
                                     width:Int,height:Int)->Int? {
        let forward=match(a,b,width:width,height:height)
        let backward=match(b,a,width:width,height:height)
        switch (forward,backward) {
        case (let forward?,nil): return forward.pixels
        case (nil,let backward?): return -backward.pixels
        case (let forward?,let backward?):
            // A repeating page pattern can align in both directions. Reject
            // ambiguous evidence rather than duplicating parts of the image.
            if forward.score+0.10 < backward.score*0.90 {return forward.pixels}
            if backward.score+0.10 < forward.score*0.90 {return -backward.pixels}
            return nil
        case (nil,nil): return nil
        }
    }

    /// Two-stage motion matching: a cheap, contrast-adaptive scan nominates
    /// offsets, then a dense comparison checks the few best candidates.
    /// Searching every pixel with the old dense matcher took ~700ms for a
    /// 1100×1800 viewport, which blocked the capture loop on macOS.
    private static func match(_ source:[UInt8],_ target:[UInt8],
                              width w:Int,height h:Int) -> MotionMatch? {
        let maxShift=min(h-30,Int(Double(h)*0.75))
        guard maxShift>1 else{return nil}
        let startY=max(4,Int(Double(h)*0.07))
        let bottomTrim=max(3,Int(Double(h)*0.018))
        let stepX=max(2,w/22)
        let minTexture=2 // smaller contrasts than the previous 14-luma cutoff

        func coarse(_ offset:Int)->(score:Double,evidence:Int,rows:Int) {
            let end=h-offset-bottomTrim
            if end<=startY+3 {return (.infinity,0,0)}
            let stepY=max(1,(end-startY)/18)
            var cost=0,weight=0,evidence=0,rows=0
            for y in stride(from:startY,to:end,by:stepY) {
                var rowEvidence=0
                let line=(y+offset)*w
                let compared=y*w
                for x in stride(from:4,to:w-4,by:stepX) {
                    let pixel=Int(source[line+x])
                    let textured=max(abs(pixel-Int(source[line+x-2])),
                                     abs(pixel-Int(source[line+x-2*w]))) >= minTexture
                    let importance=textured ? 4 : 1
                    cost += min(24,abs(pixel-Int(target[compared+x])))*importance
                    weight += importance
                    if textured {evidence+=1;rowEvidence+=1}
                }
                if rowEvidence>0 {rows+=1}
            }
            let minEvidence=max(3,Int(Double(h-offset)/80))
            guard evidence>=minEvidence && rows >= (h-offset<h/4 ? 2 : 4) else {
                return (.infinity,evidence,rows)
            }
            return (Double(cost)/Double(max(1,weight)),evidence,rows)
        }

        let stationary=coarse(0).score
        var candidates:[MotionMatch]=[]
        candidates.reserveCapacity(maxShift)
        for offset in 1...maxShift {
            let score=coarse(offset).score
            if score.isFinite { candidates.append(MotionMatch(pixels:offset,score:score)) }
        }
        guard !candidates.isEmpty else{return nil}
        candidates.sort {$0.score < $1.score}
        let bestCoarse=candidates[0].score
        // Retain more than one offset when the page contains repetitive rows,
        // but put a hard cap on dense matches to keep latency bounded.
        let close=candidates.filter {$0.score <= bestCoarse+max(1.7,bestCoarse*0.30)}
        // Sparse row sampling can miss the *exact* pixel offset (especially
        // low-contrast text and 1px wheel steps). Always refine the immediate
        // neighbourhood around leading coarse offsets at full resolution.
        var offsets=Set(close.prefix(16).map(\.pixels))
        for candidate in candidates.prefix(2) {
            for delta in -4...4 {
                let offset=candidate.pixels+delta
                if offset>=1 && offset<=maxShift { offsets.insert(offset) }
            }
        }
        let shortlisted=offsets.sorted()

        func dense(_ offset:Int)->Double {
            let end=h-offset-bottomTrim
            guard end>startY+4 else{return .infinity}
            var sum=0,count=0
            for y in stride(from:startY,to:end,by:3) {
                let line=(y+offset)*w
                let compared=y*w
                for x in stride(from:2,to:w-2,by:3) {
                    sum+=min(24,abs(Int(source[line+x])-Int(target[compared+x])))
                    count+=1
                }
            }
            return Double(sum)/Double(max(1,count))
        }
        let ranked=shortlisted.map { MotionMatch(pixels:$0,score:dense($0)) }
            .sorted {$0.score < $1.score}
        guard let winner=ranked.first,winner.score<17 else{return nil}
        // Prevent motion inferred from unchanged or slightly animated images.
        let unchanged=dense(0)
        guard winner.score+0.4 < unchanged*0.73 else{return nil}
        // A repeated background can produce several pixel-perfect alignments.
        // Never pick one arbitrarily; this is a conservative safety check.
        if ranked.count>1,ranked[1].score-winner.score < max(0.12,winner.score*0.13) {
            return nil
        }
        // Sparse candidate must also beat near-zero motion for tiny scrolls.
        if winner.pixels<=3 && stationary.isFinite && bestCoarse>=stationary*0.95 {
            return nil
        }
        return winner
    }

    private static func sample(_ image:CGImage,width:Int,height:Int)->[UInt8]? {
        guard let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
                               bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
              let data=ctx.data else{return nil}
        ctx.interpolationQuality = .low
        ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let bytes=data.assumingMemoryBound(to:UInt8.self)
        var result=[UInt8](repeating:0,count:width*height)
        for i in 0..<result.count {
            result[i]=UInt8((Int(bytes[i*4])*54+Int(bytes[i*4+1])*183+Int(bytes[i*4+2])*19)/256)
        }
        return result
    }
}

/// Poll aggressively while the content is changing, and back off when idle.
/// Keeping these decisions separate from AppKit lets us test latency policy
/// without requesting screen recording or system input permissions.
enum ScreenshotLongCapturePolicy {
    static func nextDelay(automatic:Bool,unchanged:Int)->TimeInterval {
        automatic ? 0.27 : (unchanged>=5 ? 0.30 : 0.16)
    }
    static func finishNeedsFinalFrame(hasBaseline:Bool,paused:Bool,
                                      finalCaptureStarted:Bool)->Bool {
        hasBaseline && !paused && !finalCaptureStarted
    }
}

/// A one-shot region screenshot followed by optional synthetic scrolling.
/// The user can always scroll manually. Nothing is recorded continuously.
final class ScreenshotLongCapture {
    private let rect: CGRect
    private let onFinish: (CGImage?,String?) -> Void
    private var stitcher: ScreenshotLongStitcher
    private var previewPanel: ScreenshotLongPreviewPanel?
    private var captureFrame: ScreenshotLongCaptureFrame?
    private var token = UUID()
    private var scheduledID = UUID()
    private var active = true
    // Manual scrolling is the default: the webpage must remain interactive.
    private var automatic = false
    private var paused = false
    private var unchanged = 0
    private var capturing = false
    private var hasBaseline = false
    private var previewHiddenForCapture = false
    private var processing = false
    private var pendingFinish = false
    private var finalCaptureStarted = false
    // Pixel matching is deliberately never performed on AppKit's main thread.
    private let matchingQueue=DispatchQueue(label:"MacState.screenshot.long.match",qos:.userInitiated)

    init(rect:CGRect,first:CGImage,completion:@escaping(CGImage?,String?)->Void) {
        self.rect=rect;stitcher=ScreenshotLongStitcher(first:first);onFinish=completion
        showPanels()
        scheduleNext(after:0.20)
    }

    func cancel() { finish(save:false) }

    private func showPanels() {
        // The frame is visual-only. It never receives mouse, wheel or keyboard
        // events and it draws only outside the actual capture rectangle.
        captureFrame=ScreenshotLongCaptureFrame(selection:rect)
        let panel=ScreenshotLongPreviewPanel(selection:rect,
                                              screens:NSScreen.screens.map(\.visibleFrame))
        panel.onAutomaticToggle={ [weak self] in self?.toggleAutomatic() }
        panel.onPauseToggle={ [weak self] in self?.togglePause() }
        panel.onComplete={ [weak self] in self?.finish(save:true) }
        panel.onCancel={ [weak self] in self?.finish(save:false) }
        panel.show(stitcher:stitcher,message:"等待目标页面首帧…")
        panel.setControls(automatic:automatic,paused:paused)
        previewPanel=panel
    }

    private func toggleAutomatic() {
        guard active else{return}
        if !automatic && !CGPreflightPostEventAccess() {
            // Permission is requested ONLY for the explicit Auto button.
            // Manual scrolling never requires synthetic-event access.
            guard CGRequestPostEventAccess() else {
                previewPanel?.showStatus("自动滚动需要系统「辅助功能」权限；仍可在右侧手动滚动")
                previewPanel?.setControls(automatic:false,paused:paused)
                return
            }
        }
        automatic.toggle();unchanged=0
        previewPanel?.setControls(automatic:automatic,paused:paused)
        previewPanel?.showStatus(automatic ? "自动向下滚动 · 可以随时切换手动" :
                                               "手动滚动右侧页面 · 自动检测新增内容")
        // Auto mode starts from the previous valid screenshot after the next
        // capture. The first frame is not scrolled until it is re-sampled.
        if automatic && hasBaseline && !paused && !capturing && !processing {scrollDown()}
    }

    private func togglePause() {
        guard active else{return}
        paused.toggle()
        previewPanel?.setControls(automatic:automatic,paused:paused)
        previewPanel?.showStatus(paused ? "已暂停；页面仍可滚动" : "继续采集中…")
        if paused {scheduledID=UUID()}
        else {scheduleNext(after:0.15)}
    }

    private func scheduleNext(after delay:TimeInterval) {
        guard active,!paused,!pendingFinish else{return}
        let current=token, planned=UUID()
        scheduledID=planned
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
            guard let self,self.active,!self.paused,self.token==current,
                  self.scheduledID==planned else{return}
            self.capture()
        }
    }

    private func capture() {
        guard active,!capturing,!processing,!paused,!pendingFinish else{return}
        capturing=true
        // Do not blink the preview during ordinary captures. If the user
        // drags it across the selection, briefly hide it just for that frame.
        previewHiddenForCapture=previewPanel?.intersectsCapture(rect) == true
        if previewHiddenForCapture {previewPanel?.orderOut(nil)}
        let current=token
        DispatchQueue.main.asyncAfter(deadline:.now()+(previewHiddenForCapture ? 0.08 : 0.02)) { [weak self] in
            guard let self,self.active,self.token==current else{return}
            if #available(macOS 15.2, *) {
                SCScreenshotManager.captureImage(in:ScreenshotCaptureCoordinates.quartzRect(appKitRect:self.rect,primaryScreenTop:NSScreen.screens.first?.frame.maxY ?? 0)) { [weak self] image,error in
                    DispatchQueue.main.async {
                        guard let self,self.active,self.token==current else{return}
                        self.received(image,error:error)
                    }
                }
            } else {
                self.legacyCapture(current:current)
            }
        }
    }

    private func legacyCapture(current:UUID) {
        let screenTop=NSScreen.screens.first?.frame.maxY ?? 0
        let regionRect=ScreenshotCaptureCoordinates.quartzRect(appKitRect:rect,primaryScreenTop:screenTop)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let target=FileManager.default.temporaryDirectory.appendingPathComponent("MacState-long-\(UUID().uuidString).png")
            defer {try? FileManager.default.removeItem(at:target)}
            let region="\(Int(regionRect.minX)),\(Int(regionRect.minY)),\(Int(regionRect.width)),\(Int(regionRect.height))"
            let process=Process()
            process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments=["-x","-t","png","-R"+region,target.path]
            process.standardOutput=FileHandle.nullDevice
            process.standardError=FileHandle.nullDevice
            var image:CGImage?
            do {
                try process.run();process.waitUntilExit()
                if process.terminationStatus==0,
                   let source=CGImageSourceCreateWithURL(target as CFURL,nil) {
                    image=CGImageSourceCreateImageAtIndex(source,0,nil)
                }
            } catch {}
            DispatchQueue.main.async {
                guard let self,self.active,self.token==current else{return}
                self.received(image,error:nil)
            }
        }
    }

    private func received(_ image:CGImage?,error:Error?) {
        capturing=false
        if previewHiddenForCapture {previewPanel?.orderFrontRegardless()}
        previewHiddenForCapture=false
        guard active else{return}
        if paused || image == nil {
            if image == nil {
                previewPanel?.showStatus("采集失败：\(error?.localizedDescription ?? "系统未返回画面")；可以完成已有截图")
                automatic=false
                previewPanel?.setControls(automatic:false,paused:paused)
            }
            if finishPendingIfNecessary() {return}
            if !paused {scheduleNext(after:0.48)}
            return
        }
        guard let image else{return}
        if !hasBaseline {
            // The frozen selection image may include windows removed at start.
            stitcher=ScreenshotLongStitcher(first:image)
            hasBaseline=true
            previewPanel?.show(stitcher:stitcher,
                               message:"在右侧蓝框内上下滚动，新增内容实时拼接")
            if finishPendingIfNecessary() {return}
            if automatic {scrollDown()}
            scheduleNext(after:automatic ? 0.27:0.16)
            return
        }

        // Copy-on-write slices/CGImage backing are immutable. A worker
        // computes the next stitch while the mouse, scroll and HUD controls
        // remain responsive on the main AppKit thread.
        processing=true
        let current=token, previous=stitcher
        matchingQueue.async { [weak self] in
            var candidate=previous
            let result:Result<(ScreenshotLongStitcher,ScreenshotLongStitcher.Change),Error>
            do {
                let change=try candidate.incorporate(image)
                result = .success((candidate,change))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self,self.active,self.token==current else{return}
                self.processing=false
                if !self.paused {
                    switch result {
                    case .success(let value):
                        self.stitcher=value.0
                        self.presentStitchChange(value.1)
                    case .failure(let error):
                        self.automatic=false
                        self.previewPanel?.setControls(automatic:false,paused:self.paused)
                        self.previewPanel?.showStatus(error.localizedDescription)
                        if case ScreenshotLongStitcher.StitchError.tooLarge = error {
                            self.finish(save:true)
                            return
                        }
                    }
                }
                if self.finishPendingIfNecessary() {return}
                if !self.paused {
                    // Adaptively poll while motion is happening; use slightly
                    // less CPU when the page is stationary.
                    let wait=ScreenshotLongCapturePolicy.nextDelay(automatic:self.automatic,unchanged:self.unchanged)
                    self.scheduleNext(after:wait)
                }
            }
        }
    }

    private func presentStitchChange(_ change:ScreenshotLongStitcher.Change) {
        switch change {
        case .extendedTop(let added):
            unchanged=0
            previewPanel?.show(stitcher:stitcher,
                               message:"已向上补齐 \(added) 像素 · 可继续上下滚动",
                               prependedPixels:added)
        case .extendedBottom(let added):
            unchanged=0
            previewPanel?.show(stitcher:stitcher,
                               message:"已向下拼接 \(added) 像素 · 可继续上下滚动")
        case .revisited:
            unchanged=0
            previewPanel?.showStatus("正在浏览已截取内容 · 不会重复拼接")
        case .unmatched:
            unchanged+=1
            if automatic && unchanged>=3 {
                automatic=false
                previewPanel?.setControls(automatic:false,paused:paused)
                previewPanel?.showStatus("未检测到可靠重叠，请减小滚动幅度或切换手动")
            } else if unchanged>=3 {
                previewPanel?.showStatus("仍在检查画面；请在蓝框内小幅滚动")
            }
        }
        if automatic {scrollDown()}
    }

    /// Save only after the last in-flight screenshot has been matched.
    /// Cancel always remains immediate.
    @discardableResult private func finishPendingIfNecessary()->Bool {
        guard pendingFinish,!capturing,!processing else{return false}
        pendingFinish=false
        finish(save:true)
        return true
    }

    private func scrollDown() {
        guard CGPreflightPostEventAccess() else {
            automatic=false
            previewPanel?.setControls(automatic:false,paused:paused)
            previewPanel?.showStatus("自动滚动权限不可用；请在右侧直接手动滚动网页")
            return
        }
        // The system routes HID wheel events by their Quartz coordinates.
        // Line units are more compatible with browsers than synthetic pixel
        // events, which some apps simply drop.
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let region=ScreenshotCaptureCoordinates.quartzRect(appKitRect:rect,primaryScreenTop:top)
        let lines=Int32(max(3,min(10,Int(rect.height/65))))
        guard let event=CGEvent(scrollWheelEvent2Source:CGEventSource(stateID:.hidSystemState),
                                units:.line,wheelCount:1,wheel1:-lines,wheel2:0,wheel3:0) else {
            automatic=false
            previewPanel?.setControls(automatic:false,paused:paused)
            previewPanel?.showStatus("无法创建滚轮事件；请手动滚动目标网页")
            return
        }
        event.location=CGPoint(x:region.midX,y:region.midY)
        event.post(tap:.cghidEventTap)
    }

    private func finish(save:Bool) {
        guard active else{return}
        if save {
            if capturing || processing {
                pendingFinish=true
                previewPanel?.showStatus("正在拼接最后一帧，请稍候…")
                return
            }
            // A user can scroll and immediately click Finish before the next
            // scheduled snapshot. Always take one final live frame instead
            // of exporting a stale preview; this can only happen once.
            if ScreenshotLongCapturePolicy.finishNeedsFinalFrame(hasBaseline:hasBaseline,paused:paused,finalCaptureStarted:finalCaptureStarted) {
                finalCaptureStarted=true
                previewPanel?.showStatus("正在抓取最后一帧…")
                capture()
                if capturing {
                    pendingFinish=true
                    return
                }
            }
        }
        active=false;token=UUID();scheduledID=UUID()
        previewPanel?.orderOut(nil);previewPanel?.close();previewPanel=nil
        captureFrame?.orderOut(nil);captureFrame?.close();captureFrame=nil
        guard save else{onFinish(nil,nil);return}
        let frames=stitcher,callback=onFinish
        DispatchQueue.global(qos:.userInitiated).async {
            let result:Result<CGImage,Error>
            do {result = .success(try frames.compose())}
            catch {result = .failure(error)}
            DispatchQueue.main.async {
                switch result {
                case .success(let image): callback(image,nil)
                case .failure(let error): callback(nil,error.localizedDescription)
                }
            }
        }
    }
}
