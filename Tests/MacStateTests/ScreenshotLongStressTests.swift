import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor
struct ScreenshotLongStressTests {
    // Deliberately real text/graphics, including alternating background tones
    // and unique paragraph content. The vertically long source makes it easy
    // to assert the exact native-pixel displacement of cropped viewports.
    static func page(width:Int=880,height:Int=4000,contrast:CGFloat=0.55) throws -> CGImage {
        let bitmap=try #require(NSBitmapImageRep(
            bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
            colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0
        ))
        let ctx=try #require(NSGraphicsContext(bitmapImageRep:bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=ctx
        let background:CGFloat=0.25
        NSColor(calibratedWhite:background,alpha:1).setFill()
        NSRect(x:0,y:0,width:width,height:height).fill()
        for index in 0..<(height/64) {
            let y=CGFloat(index*64+8)
            let tone=background+CGFloat((index*31)%13)/250
            NSColor(calibratedWhite:tone,alpha:1).setFill()
            NSRect(x:12,y:y,width:CGFloat(width-28),height:47).fill()
            let text="Paragraph \(index) code \(index*17713+421). "
                + String(repeating:"滚动长图精度 \(index%73)",count:1+index%5)
            let attributes:[NSAttributedString.Key:Any]=[
                .font:NSFont.systemFont(ofSize:CGFloat(12+index%6)),
                .foregroundColor:NSColor(calibratedWhite:min(1,background+contrast),alpha:1)
            ]
            (text as NSString).draw(in:NSRect(x:22,y:y+5,width:CGFloat(width-45),height:31),
                                    withAttributes:attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.cgImage)
    }

    static func frame(_ source:CGImage,top:Int,height:Int)->CGImage? {
        source.cropping(to:CGRect(x:0,y:top,width:source.width,height:height))
    }

    @Test func manyWheelStepsAndReversals() throws {
        let source=try Self.page()
        for h in [320,680,1120] {
            for step in [3,6,11,35,127,Int(Double(h)*0.48),Int(Double(h)*0.71)] {
                let first=try #require(Self.frame(source,top:250,height:h))
                let second=try #require(Self.frame(source,top:250+step,height:h))
                #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:second)==step,
                        "viewport=\(h), step=\(step)")
                #expect(ScreenshotLongStitcher.verticalDisplacement(previous:second,next:first)==(-step),
                        "reverse viewport=\(h), step=\(step)")
            }
        }
    }

    @Test func lowContrastTextScroll() throws {
        let source=try Self.page(contrast:0.055)
        for offset in [28,95,220] {
            let first=try #require(Self.frame(source,top:400,height:680))
            let second=try #require(Self.frame(source,top:400+offset,height:680))
            #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:second)==offset,
                    "low contrast \(offset)")
        }
    }

    @Test func repetitiveImageButUniqueDistinctiveRowsAndNoFalseMotion() throws {
        let source=try Self.page()
        let before=try #require(Self.frame(source,top:220,height:680))
        let later=try #require(Self.frame(source,top:360,height:680))
        var stitch=ScreenshotLongStitcher(first:before)
        #expect(try stitch.incorporate(before) == .unmatched)
        #expect(try stitch.incorporate(later) == .extendedBottom(140))
        #expect(try stitch.incorporate(before) == .revisited)
        #expect(stitch.frames==2)
    }

    private static func animated(_ frame:CGImage,seed:Int,portion:CGFloat=0.14) throws -> CGImage {
        let width=frame.width,height=frame.height
        let context=try #require(CGContext(
            data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(frame,in:CGRect(x:0,y:0,width:width,height:height))
        let zone=CGRect(x:width/4,y:Int(CGFloat(height)*0.32),
                        width:width/2,height:Int(CGFloat(height)*portion))
        context.setFillColor(CGColor(red:CGFloat(seed%13)/14,
                                     green:CGFloat((seed*7)%17)/18,
                                     blue:CGFloat((seed*3)%19)/20,alpha:1))
        context.fill(zone)
        return try #require(context.makeImage())
    }

    @Test func animatedWidgetDoesNotFakeMotionOrBlockRealScroll() throws {
        let source=try Self.page(width:880,height:4000)
        let old=try #require(Self.frame(source,top:200,height:700))
        let moved=try #require(Self.frame(source,top:420,height:700))
        let oldAnimated=try Self.animated(old,seed:1)
        let newAnimated=try Self.animated(moved,seed:7)
        #expect(ScreenshotLongStitcher.verticalDisplacement(
            previous:oldAnimated,next:newAnimated)==220)
        let stationaryChanged=try Self.animated(old,seed:13)
        #expect(ScreenshotLongStitcher.verticalDisplacement(
            previous:oldAnimated,next:stationaryChanged)==nil)
    }

    @Test func deterministicLongScrollSequencePreservesEveryOriginalRow() throws {
        let source=try Self.page(width:760,height:4800)
        let viewport=620
        var top=800,lowest=800,highest=800
        let first=try #require(Self.frame(source,top:top,height:viewport))
        var stitch=ScreenshotLongStitcher(first:first)
        var seed=0x12B
        var additions=0
        for _ in 0..<26 {
            seed=(seed*1664525+1013904223)&0x7fffffff
            let delta=(seed%650)-325
            top=max(0,min(source.height-viewport,top+delta))
            lowest=min(lowest,top);highest=max(highest,top)
            let frame=try #require(Self.frame(source,top:top,height:viewport))
            let change=try stitch.incorporate(frame)
            if change.addedPixels != nil {additions+=1}
        }
        #expect(stitch.height==highest-lowest+viewport)
        #expect(stitch.frames==additions+1)
        #expect(stitch.viewportTop==top-lowest)
        let result=ScreenshotRaster(try stitch.compose())
        let expected=ScreenshotRaster(source)
        for row in stride(from:0,to:stitch.height,by:max(1,stitch.height/19)) {
            let original=try #require(expected.colorAtPixel(x:370,y:lowest+row))
            let actual=try #require(result.colorAtPixel(x:370,y:row))
            #expect(ScreenshotRaster.hex(actual)==ScreenshotRaster.hex(original),
                    "row \(row) after \(additions) extension events")
        }
    }

    @Test func thinViewportWithSmallSmoothScroll() throws {
        let source=try Self.page(width:760,height:2400)
        let old=try #require(Self.frame(source,top:200,height:230))
        for shift in [2,4,12,48,100] {
            let next=try #require(Self.frame(source,top:200+shift,height:230))
            #expect(ScreenshotLongStitcher.verticalDisplacement(
                previous:old,next:next)==shift,
                "small window shift \(shift)")
        }
    }

    @Test func unrelatedRandomFramesNeverProduceArtificialStitch() throws {
        func noise(seed:Int)->CGImage? {
            guard let bitmap=NSBitmapImageRep(
                bitmapDataPlanes:nil,pixelsWide:440,pixelsHigh:550,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0
            ),let data=bitmap.bitmapData else{return nil}
            var value=UInt64(seed)
            for y in 0..<550 {
                for x in 0..<440 {
                    value = value &* 6364136223846793005 &+ 1442695040888963407
                    let i=y*bitmap.bytesPerRow+x*4
                    data[i]=UInt8(truncatingIfNeeded:value>>24)
                    data[i+1]=UInt8(truncatingIfNeeded:value>>35)
                    data[i+2]=UInt8(truncatingIfNeeded:value>>45)
                    data[i+3]=255
                }
            }
            return bitmap.cgImage
        }
        let first=try #require(noise(seed:7))
        let unrelated=try #require(noise(seed:1234))
        #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:unrelated)==nil)
        var stitch=ScreenshotLongStitcher(first:first)
        #expect(try stitch.incorporate(unrelated) == .unmatched)
        #expect(stitch.height==first.height && stitch.frames==1)
    }

    @Test func responseTimingAndFinalFramePolicyRemainResponsive() {
        #expect(ScreenshotLongCapturePolicy.nextDelay(automatic:false,unchanged:0)==0.16)
        #expect(ScreenshotLongCapturePolicy.nextDelay(automatic:false,unchanged:4)==0.16)
        #expect(ScreenshotLongCapturePolicy.nextDelay(automatic:false,unchanged:5)==0.30)
        #expect(ScreenshotLongCapturePolicy.nextDelay(automatic:true,unchanged:8)==0.27)
        #expect(ScreenshotLongCapturePolicy.finishNeedsFinalFrame(
            hasBaseline:true,paused:false,finalCaptureStarted:false))
        #expect(!ScreenshotLongCapturePolicy.finishNeedsFinalFrame(
            hasBaseline:true,paused:false,finalCaptureStarted:true))
        #expect(!ScreenshotLongCapturePolicy.finishNeedsFinalFrame(
            hasBaseline:false,paused:false,finalCaptureStarted:false))
        #expect(!ScreenshotLongCapturePolicy.finishNeedsFinalFrame(
            hasBaseline:true,paused:true,finalCaptureStarted:false))
    }

    @Test func batchMatchingDurationAtRetinaViewport() throws {
        let source=try Self.page(width:1100,height:5500)
        let first=try #require(Self.frame(source,top:450,height:1800))
        let later=try #require(Self.frame(source,top:750,height:1800))
        let start=ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:later)==300)
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        print("LONG_CAPTURE_PERF fiveMatches(1100x1800): \(String(format:"%.3f",elapsed))s")
        // Original exhaustive matcher: ~3.57s for five frames on this host.
        // Allow >2x headroom for concurrent XCTest workloads and CI load.
        #expect(elapsed < 3.3)
    }
}
