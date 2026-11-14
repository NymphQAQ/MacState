import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor struct ScreenshotLongCaptureTests {
    private func page(width:Int=240,height:Int=1200) throws -> CGImage {
        let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,
                                                  bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                                                  colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let ptr=try #require(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let index=y*bitmap.bytesPerRow+x*4
                let value=(x*31+y*73+(y/9)*57+(x/7*y/11)*13) % 256
                ptr[index]=UInt8(value)
                ptr[index+1]=UInt8((value*3+y/3)%256)
                ptr[index+2]=UInt8((value+x*11)%256)
                ptr[index+3]=255
            }
        }
        return try #require(bitmap.cgImage)
    }

    @Test func overlapDetectionStitchesExactNewRowsAndPreservesPixels() throws {
        let original=try page()
        let first=try #require(original.cropping(to:CGRect(x:0,y:0,width:240,height:420)))
        let second=try #require(original.cropping(to:CGRect(x:0,y:160,width:240,height:420)))
        let third=try #require(original.cropping(to:CGRect(x:0,y:320,width:240,height:420)))
        #expect(ScreenshotLongStitcher.verticalShift(previous:first,next:second)==160)
        var stitch=ScreenshotLongStitcher(first:first)
        #expect(try stitch.append(second)==160)
        #expect(try stitch.append(third)==160)
        #expect(stitch.frames==3)
        #expect(stitch.height==740)
        let merged=try stitch.compose()
        #expect(merged.width==240 && merged.height==740)
        let result=ScreenshotRaster(merged)
        let expected=ScreenshotRaster(original)
        for y in [0,159,160,419,420,579,580,739] {
            #expect(ScreenshotRaster.hex(try #require(result.colorAtPixel(x:110,y:y))) ==
                    ScreenshotRaster.hex(try #require(expected.colorAtPixel(x:110,y:y))))
        }
    }

    @Test func scrollUpPrependsOnlyPreviouslyMissingPixels() throws {
        let full=try page(height:1600)
        func view(_ top:Int) throws -> CGImage {
            try #require(full.cropping(to:CGRect(x:0,y:top,width:240,height:420)))
        }
        var stitch=ScreenshotLongStitcher(first:try view(320))
        #expect(try stitch.append(view(480))==160)
        #expect(stitch.height==580)
        #expect(stitch.frames==2)

        // Revisit an existing region; the cursor must update, but neither
        // preview height nor section count may increase.
        #expect(try stitch.append(view(380))==nil)
        #expect(stitch.height==580)
        #expect(stitch.frames==2)

        #expect(try stitch.append(view(190))==130)
        #expect(stitch.height==710)
        #expect(stitch.frames==3)
        #expect(try stitch.append(view(80))==110)
        #expect(stitch.height==820)
        #expect(stitch.frames==4)

        let composed=try stitch.compose()
        #expect(composed.width==240 && composed.height==820)
        let expected=ScreenshotRaster(full), actual=ScreenshotRaster(composed)
        for y in [0,1,109,110,129,130,239,240,420,579,580,819] {
            let actualColor=try #require(actual.colorAtPixel(x:133,y:y))
            let fullColor=try #require(expected.colorAtPixel(x:133,y:y+80))
            #expect(ScreenshotRaster.hex(actualColor)==ScreenshotRaster.hex(fullColor),
                    "Mismatch at stitched row \\(y)")
        }

        // Downward movement through already collected content must not
        // append repeated rows, even after a top extension.
        #expect(try stitch.append(view(250))==nil)
        #expect(try stitch.append(view(410))==nil)
        #expect(stitch.height==820)
        #expect(stitch.frames==4)
    }

    @Test func directUpwardDisplacementUsesNegativePixels() throws {
        let full=try page()
        let first=try #require(full.cropping(to:CGRect(x:0,y:340,width:240,height:420)))
        let above=try #require(full.cropping(to:CGRect(x:0,y:210,width:240,height:420)))
        #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:above)==(-130))
        #expect(ScreenshotLongStitcher.verticalDisplacement(previous:above,next:first)==130)
        #expect(ScreenshotLongStitcher.verticalDisplacement(previous:first,next:first)==nil)
    }

    @Test func stickyHeaderDoesNotConfuseOverlapDetection() throws {
        let original=try page()
        let first=try #require(original.cropping(to:CGRect(x:0,y:0,width:240,height:420)))
        let scrolled=try #require(original.cropping(to:CGRect(x:0,y:160,width:240,height:420)))
        let header=try #require(first.cropping(to:CGRect(x:0,y:0,width:240,height:28)))
        let context=try #require(CGContext(data:nil,width:240,height:420,bitsPerComponent:8,
                                         bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(scrolled,in:CGRect(x:0,y:0,width:240,height:420))
        context.draw(header,in:CGRect(x:0,y:392,width:240,height:28))
        let second=try #require(context.makeImage())
        #expect(ScreenshotLongStitcher.verticalShift(previous:first,next:second)==160)
    }

    @Test func identicalOrUnrelatedFramesDoNotCreateDuplicateSlices() throws {
        let original=try page()
        let first=try #require(original.cropping(to:CGRect(x:0,y:0,width:240,height:420)))
        let unrelated=try #require(original.cropping(to:CGRect(x:0,y:700,width:240,height:420)))
        var stitch=ScreenshotLongStitcher(first:first)
        #expect(try stitch.append(first)==nil)
        #expect(try stitch.append(unrelated)==nil)
        #expect(stitch.frames==1)
        #expect(stitch.height==420)
    }

    @Test func ambiguousRepeatingPatternsDoNotDuplicateRows() throws {
        let source=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,
                            pixelsHigh:1040,bitsPerSample:8,samplesPerPixel:4,
                            hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
                            bytesPerRow:0,bitsPerPixel:0))
        let bytes=try #require(source.bitmapData)
        for y in 0..<1040 {
            for x in 0..<240 {
                let index=y*source.bytesPerRow+x*4
                let tone=UInt8(((y%80)*19+x*7+(x/9*13))%255)
                bytes[index]=tone
                bytes[index+1]=UInt8((Int(tone)+x*3)%255)
                bytes[index+2]=UInt8((Int(tone)+y%80*2)%255)
                bytes[index+3]=255
            }
        }
        let image=try #require(source.cgImage)
        let first=try #require(image.cropping(to:CGRect(x:0,y:0,width:240,height:420)))
        let second=try #require(image.cropping(to:CGRect(x:0,y:160,width:240,height:420)))
        var stitch=ScreenshotLongStitcher(first:first)
        #expect(try stitch.incorporate(second) == .unmatched)
        #expect(stitch.frames==1 && stitch.height==420 && stitch.viewportTop==0)
    }

    @Test func longCaptureButtonInvokesSelectedNativeImage() throws {
        let first=try page(width:240,height:420)
        let rect=NSRect(x:55,y:70,width:160,height:250)
        let editor=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:240,height:420),image:first,selection:rect)
        var area:NSRect?
        var result:CGImage?
        editor.onLongCapture={ selection,image in area=selection;result=image }
        let button=editor.subviews.flatMap(\.subviews).compactMap{$0 as? NSButton}
            .first{$0.identifier?.rawValue=="long"}
        #expect(try #require(button).isEnabled)
        editor.performAction("long")
        #expect(area==rect)
        #expect(result?.width==160 && result?.height==250)
    }
}
