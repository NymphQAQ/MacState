import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor
struct ScreenshotLongPreviewTests {
    @Test func previewSitsToLeftOfWideCaptureWithoutHidingItsScrollableArea() {
        let screen=CGRect(x:0,y:0,width:1920,height:1080)
        let selection=CGRect(x:860,y:140,width:790,height:610)
        let result=ScreenshotLongPreviewLayout.place(selection:selection,screens:[screen])
        #expect(result.position == .left)
        #expect(result.frame.maxX < selection.minX)
        #expect(result.frame.width>=295)
        #expect(result.frame.height>=390)
        #expect(screen.contains(result.frame))
        #expect(!result.frame.intersects(selection))
    }

    @Test func previewMovesRightWhenSelectionIsAtLeftEdge() {
        let screen=CGRect(x:0,y:0,width:1600,height:1000)
        let selection=CGRect(x:25,y:200,width:780,height:500)
        let result=ScreenshotLongPreviewLayout.place(selection:selection,screens:[screen])
        #expect(result.position == .right)
        #expect(result.frame.minX > selection.maxX)
        #expect(!result.frame.intersects(selection))
        #expect(screen.contains(result.frame))
    }

    @Test func previewFallsBackAboveOrToOtherMonitorWhenNeitherSideHasSpace() {
        let single=CGRect(x:0,y:0,width:1000,height:900)
        let selection=CGRect(x:85,y:80,width:840,height:500)
        let result=ScreenshotLongPreviewLayout.place(selection:selection,screens:[single])
        #expect(result.position == .above)
        #expect(result.frame.minY > selection.maxY)
        #expect(!result.frame.intersects(selection))
        let full=CGRect(x:20,y:30,width:960,height:840)
        let second=CGRect(x:-1300,y:0,width:1280,height:900)
        let other=ScreenshotLongPreviewLayout.place(selection:full,screens:[single,second])
        #expect(other.position == .otherDisplay)
        #expect(second.contains(other.frame))
        #expect(!other.frame.intersects(full))
    }

    @Test func overlayInkIsEntirelyOutsideSelectionAndViewIsNotOpaque() throws {
        let region=CGRect(x:0,y:0,width:240,height:160)
        let frame=ScreenshotLongCaptureFrameView(frame:region)
        #expect(!frame.isOpaque)
        let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:160,
                    bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                    colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context=try #require(NSGraphicsContext(bitmapImageRep:bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=context
        frame.draw(region)
        NSGraphicsContext.restoreGraphicsState()
        let inner=Int(ScreenshotLongCaptureFrameView.inset)
        // Representative top-left and centre pixels of the capture stay
        // completely transparent: only the border OUTSIDE it is painted.
        #expect((try #require(bitmap.colorAt(x:120,y:80))).alphaComponent < 0.01)
        #expect((try #require(bitmap.colorAt(x:inner+12,y:inner+12))).alphaComponent < 0.01)
        #expect((try #require(bitmap.colorAt(x:inner-4,y:80))).alphaComponent > 0.8)
    }

    @Test func upwardPreviewAnchorsNewTopAndPreservesManuallyViewedMiddle() {
        let calc=ScreenshotLongPreviewPanel.previewScrollOffset
        // If user was following the screenshot, new top rows should appear.
        #expect(calc(0,800,1050,300,250)==0)
        #expect(calc(500,800,1050,300,250)==0)
        // If the user intentionally scrolled the preview to the middle,
        // preserve their visible pixels by shifting their old offset.
        #expect(calc(180,800,1050,300,250)==430)
        // Downward growth preserves existing auto-follow semantics.
        #expect(calc(500,800,1050,300,0)==750)
        #expect(calc(180,800,1050,300,0)==180)
    }

    @Test func previewReusesImageSlicesAndGrowsAtNativeAspectRatio() throws {
        let first=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:400,
                       bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                       colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)?.cgImage)
        let image=ScreenshotLongPreviewImageView(frame:.zero)
        image.update(sections:[first],sourceWidth:240,sourceHeight:400,displayWidth:180)
        #expect(image.frame.width==180)
        #expect(image.frame.height==300)
        let second=try #require(first.cropping(to:CGRect(x:0,y:250,width:240,height:150)))
        image.update(sections:[first,second],sourceWidth:240,sourceHeight:550,displayWidth:180)
        #expect(image.sections.count==2)
        #expect(image.frame.height==413)
        #expect(image.sourceWidth==240 && image.sourceHeight==550)
    }
}
