import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor struct ScreenshotCaptureEditorTests {
    private func fixture() throws -> CGImage {
        let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:480,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let bytes=try #require(bitmap.bitmapData)
        for y in 0..<480 {for x in 0..<640 {let i=y*bitmap.bytesPerRow+x*4;bytes[i]=UInt8(x%255);bytes[i+1]=UInt8(y%255);bytes[i+2]=((x/4+y/4)%2==0) ? 20 : 240;bytes[i+3]=255}}
        return try #require(bitmap.cgImage)
    }
    private func event(_ kind:NSEvent.EventType,_ point:NSPoint,in view:NSView,clicks:Int=1) throws -> NSEvent {
        let location=view.convert(point,to:nil)
        return try #require(NSEvent.mouseEvent(with:kind,location:location,modifierFlags:[],timestamp:0,windowNumber:view.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:clicks,pressure:1))
    }
    @Test func historyEditorDimmedSurfaceKeepsNativePixelsAndEntireToolbarVisible() throws {
        let image=try fixture()
        let canvas=NSRect(x:0,y:0,width:1132,height:900)
        let source=ScreenshotEditorLayout.sourceFrame(
            imageSize:NSSize(width:image.width,height:image.height),
            backingScale:2,canvas:canvas)
        #expect(source.size == NSSize(width:320,height:240))
        #expect(abs(source.midX-canvas.midX)<0.01)
        let editor=ScreenshotEditingView(frame:canvas,image:image,selection:source,sourceRect:source)
        editor.layoutSubtreeIfNeeded()
        #expect(editor.document.selection==source)
        #expect(editor.document.pixelSize==NSSize(width:640,height:480))
        #expect(editor.editorToolbarFrameForTesting.minX>=0)
        #expect(editor.editorToolbarFrameForTesting.maxX<=canvas.width)
        #expect(editor.editorOptionsFrameForTesting.maxX<=canvas.width)
        #expect(editor.editorOptionsFrameForTesting.maxY<=canvas.height)
        #expect(editor.editorHeaderFrameForTesting.maxX<=canvas.width)
        let unchanged=try #require(editor.document.render(includeShadow:false))
        #expect(unchanged.width==image.width && unchanged.height==image.height)
        let cropped=ScreenshotRaster(unchanged),original=ScreenshotRaster(image)
        #expect(ScreenshotRaster.hex(try #require(cropped.colorAtPixel(x:300,y:160))) ==
                ScreenshotRaster.hex(try #require(original.colorAtPixel(x:300,y:160))))
        let resized=NSRect(x:source.minX+30,y:source.minY+20,width:source.width-30,height:source.height-20)
        editor.document.selection=resized
        #expect(editor.document.pixelSize==NSSize(width:580,height:440))
        let crop=try #require(editor.document.render(includeShadow:false))
        #expect(crop.width==580 && crop.height==440)
    }
    @Test func largeHistoryScreenshotCanPanWithoutRescalingOrAlteringOutput() throws {
        let image=try fixture(),canvas=NSRect(x:0,y:0,width:230,height:200)
        let source=ScreenshotEditorLayout.sourceFrame(
            imageSize:NSSize(width:640,height:480),backingScale:1,canvas:canvas)
        let editor=ScreenshotEditingView(frame:canvas,image:image,selection:source,sourceRect:source)
        editor.configureHistoryViewport(backingScale:1)
        let before=try #require(editor.document.render(includeShadow:false))
        editor.panHistoryImage(by:NSPoint(x:-90,y:-65))
        #expect(editor.document.selection==editor.document.sourceRect)
        #expect(editor.document.sourceRect.origin != source.origin)
        #expect(editor.document.pixelSize==NSSize(width:640,height:480))
        let after=try #require(editor.document.render(includeShadow:false))
        #expect(after.width==before.width && after.height==before.height)
        #expect(ScreenshotRaster.hex(try #require(ScreenshotRaster(before).colorAtPixel(x:225,y:155))) ==
                ScreenshotRaster.hex(try #require(ScreenshotRaster(after).colorAtPixel(x:225,y:155))))
    }
    @Test func historyImagePanningPreservesUndoCoordinates() throws {
        let source=NSRect(x:-30,y:-40,width:640,height:480)
        let doc=ScreenshotEditDocument(image:try fixture(),
                                       viewSize:NSSize(width:320,height:240),selection:source,sourceRect:source)
        doc.checkpoint()
        doc.selection=source.insetBy(dx:40,dy:30)
        doc.panCanvas(by:NSPoint(x:-75,y:-45))
        #expect(doc.pixelSize==NSSize(width:560,height:420))
        doc.undo()
        #expect(doc.selection==doc.sourceRect)
        #expect(doc.pixelSize==NSSize(width:640,height:480))
        let output=try #require(doc.render(includeShadow:false))
        #expect(output.width==640 && output.height==480)
    }
    @Test func oversizedImageFitsAndCanZoomPanBackToTopWithoutChangingRaster() throws {
        let image=try fixture(),canvas=NSRect(x:0,y:0,width:520,height:390)
        let frame=ScreenshotEditorLayout.sourceFrame(
            imageSize:NSSize(width:640,height:480),backingScale:1,canvas:canvas)
        #expect(frame.minY>=ScreenshotEditorLayout.topInset)
        #expect(frame.maxY<=canvas.height-ScreenshotEditorLayout.bottomInset+0.001)
        #expect(frame.minX>=ScreenshotEditorLayout.horizontalInset)
        #expect(frame.maxX<=canvas.width-ScreenshotEditorLayout.horizontalInset)
        let editor=ScreenshotEditingView(frame:canvas,image:image,selection:frame,sourceRect:frame)
        editor.configureHistoryViewport(backingScale:1)
        #expect(editor.viewportZoom<1)
        #expect(editor.document.pixelSize==NSSize(width:640,height:480))
        var mark=ScreenshotAnnotation(tool:.rectangle,start:NSPoint(x:frame.minX+15,y:frame.minY+20),
                                      end:NSPoint(x:frame.minX+40,y:frame.minY+60),width:3)
        editor.document.annotations=[mark]
        let pixelWidth=mark.width/editor.document.sourceRect.width*640
        editor.document.checkpoint()
        editor.document.selection=frame.insetBy(dx:10,dy:8)
        editor.zoomViewport(to:1)
        #expect(abs(editor.viewportZoom-1)<0.001)
        #expect(abs(editor.document.sourceRect.width-640)<0.001)
        #expect(abs(editor.document.annotations[0].width/editor.document.sourceRect.width*640-pixelWidth)<0.001)
        editor.panHistoryImage(by:NSPoint(x:0,y:2000))
        #expect(abs(editor.viewportFrameForTesting.minY-ScreenshotEditorLayout.topInset)<0.001)
        editor.panHistoryImage(by:NSPoint(x:0,y:-2000))
        #expect(abs(editor.viewportFrameForTesting.maxY-(canvas.height-ScreenshotEditorLayout.bottomInset))<0.001)
        editor.document.undo()
        #expect(editor.document.selection==editor.document.sourceRect)
        #expect(editor.document.annotations.count==1)
        #expect(editor.document.pixelSize==NSSize(width:640,height:480))
        editor.fitImageToViewport()
        #expect(abs(editor.viewportFrameForTesting.minY-frame.minY)<0.001)
        let rendered=try #require(editor.document.render(includeShadow:false))
        #expect(rendered.width==640 && rendered.height==480)
        mark=editor.document.annotations[0]
        #expect(mark.width>0)
    }
    @Test func panModeAllowsDirectDraggingWithoutMovingCropOrAnnotations() throws {
        let image=try fixture(),canvas=NSRect(x:0,y:0,width:900,height:650)
        let source=ScreenshotEditorLayout.sourceFrame(imageSize:NSSize(width:640,height:480),
                                                       backingScale:1,canvas:canvas)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:canvas,image:image,selection:source,sourceRect:source)
        window.contentView=view
        view.configureHistoryViewport(backingScale:1)
        let pan=try #require(descendants(of:view).compactMap{$0 as?NSButton}
            .first{$0.identifier?.rawValue=="panMode"})
        pan.performClick(nil)
        let center=NSPoint(x:source.midX,y:source.midY)
        view.mouseDown(with:try event(.leftMouseDown,center,in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:center.x+45,y:center.y+20),in:view))
        view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:center.x+45,y:center.y+20),in:view))
        #expect(view.document.sourceRect.origin != source.origin)
        #expect(view.document.selection==view.document.sourceRect)
        #expect(view.document.pixelSize==NSSize(width:640,height:480))
        pan.performClick(nil)
    }
    @Test func historyEditorSmallScreenshotVisualFixture() throws {
        let image=try #require(fixture().cropping(to: CGRect(x:0,y:0,width:404,height:403)))
        let canvas=NSRect(x:0,y:0,width:1132,height:900)
        let frame=ScreenshotEditorLayout.sourceFrame(
            imageSize:NSSize(width:404,height:403),backingScale:1,canvas:canvas)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer {window.close()}
        let view=ScreenshotEditingView(frame:canvas,image:image,selection:frame,sourceRect:frame)
        view.configureHistoryViewport(backingScale:1)
        window.contentView=view
        view.selectTool(.text)
        view.layoutSubtreeIfNeeded()
        #expect(view.editorToolbarFrameForTesting.minX>=0)
        #expect(view.editorToolbarFrameForTesting.maxX<=canvas.width)
        #expect(view.editorOptionsFrameForTesting.maxY<=canvas.height)
        let cached=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:cached)
        let folder=URL(fileURLWithPath:"reports/screenshot-overlay-2026-10-10")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try #require(cached.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("editor-404x403.png"))
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"第一行 Hello MacState",rect:NSRect(x:0.08,y:0.12,width:0.78,height:0.065)),
            ScreenshotOCRBox(text:"第二行 2026",rect:NSRect(x:0.08,y:0.20,width:0.65,height:0.065))
        ])
        let firstPoint=NSPoint(x:frame.minX+frame.width*0.08+2,y:frame.minY+frame.height*0.152)
        let lastPoint=NSPoint(x:frame.minX+frame.width*0.86-2,y:firstPoint.y)
        view.mouseDown(with:try event(.leftMouseDown,firstPoint,in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,lastPoint,in:view))
        view.mouseUp(with:try event(.leftMouseUp,lastPoint,in:view))
        view.layoutSubtreeIfNeeded()
        #expect(view.editorOptionsFrameForTesting.maxY<=canvas.height)
        let ocrImage=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:ocrImage)
        try #require(ocrImage.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("editor-ocr-404x403.png"))
    }
    @Test func ocrGraphemeSelectionParagraphsAndZoomedGeometry() throws {
        let source=NSRect(x:60,y:80,width:600,height:500)
        let lines=[
            ScreenshotOCRBox(text:"中文 Hello 🎉 World",rect:NSRect(x:0.10,y:0.08,width:0.65,height:0.05)),
            ScreenshotOCRBox(text:"第二行 ABC",rect:NSRect(x:0.10,y:0.14,width:0.50,height:0.05)),
            ScreenshotOCRBox(text:"单独段落",rect:NSRect(x:0.1,y:0.35,width:0.4,height:0.05))
        ]
        var selection=ScreenshotOCRTextSelection()
        let region=NSRect(x:0.20,y:0.10,width:0.60,height:0.70)
        selection.install(lines,region:region)
        let first=selection.frame(for:0,in:source)
        #expect(abs(first.minX-(source.minX+(region.minX+0.10*region.width)*source.width))<0.001)
        let began=selection.begin(at:NSPoint(x:first.minX+1,y:first.midY),in:source)
        #expect(began)
        selection.extend(to:NSPoint(x:first.maxX-1,y:first.midY),in:source)
        #expect(selection.selectedText().contains("中文 Hello 🎉"))
        #expect(selection.selectedRects(in:source).count==1)
        selection.selectLine(1)
        #expect(selection.selectedText()=="第二行 ABC")
        selection.selectParagraph(0,in:source)
        #expect(selection.selectedText()=="中文 Hello 🎉 World\n第二行 ABC")
        selection.selectParagraph(2,in:source)
        #expect(selection.selectedText()=="单独段落")
        let second=selection.frame(for:1,in:source)
        selection.selectWord(at:NSPoint(x:second.maxX-3,y:second.midY),in:source)
        #expect(selection.selectedText()=="ABC")
        let zoomed=NSRect(x:-120,y:-55,width:1200,height:1000)
        let mapped=selection.frame(for:0,in:zoomed)
        #expect(abs(mapped.width-first.width*2)<0.001)
        #expect(abs(mapped.height-first.height*2)<0.001)
    }
    @Test func ocrModeSelectsTextAndCopiesWithoutChangingCrop() throws {
        let canvas=NSRect(x:0,y:0,width:900,height:650),source=NSRect(x:140,y:140,width:640,height:480)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:source,sourceRect:source)
        window.contentView=view
        let box=ScreenshotOCRBox(text:"复制你好 ABC",rect:NSRect(x:0.1,y:0.1,width:0.60,height:0.07))
        view.installOCRForTesting([box])
        let start=NSPoint(x:source.minX+source.width*0.1+1,y:source.minY+source.height*0.135)
        let end=NSPoint(x:source.minX+source.width*0.52,y:start.y)
        view.mouseDown(with:try event(.leftMouseDown,start,in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,end,in:view))
        view.mouseUp(with:try event(.leftMouseUp,end,in:view))
        #expect(view.ocrModeForTesting)
        #expect(view.ocrSelectionForTesting.contains("你好"))
        #expect(view.ocrTranslationTextForTesting==view.ocrSelectionForTesting)
        #expect(view.document.selection==source)
        #expect(view.document.annotations.isEmpty)
        let selected=view.ocrSelectionForTesting
        #expect(selected != box.text)
        let target=try #require(descendants(of:view).compactMap{$0 as?NSPopUpButton}
            .first{$0.identifier?.rawValue=="ocrTargetLanguage"})
        target.selectItem(withTitle:"法语");_ = target.sendAction(target.action,to:target.target)
        #expect(view.ocrSelectionForTesting==selected)
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType:.string)==view.ocrSelectionForTesting)
        view.performAction("ocr")
        #expect(!view.ocrModeForTesting)
        #expect(view.document.selection==source)
    }
    @Test func outputPreservesPixelsAndClipsRoundedCorners() throws {
        let image=try fixture(),doc=ScreenshotEditDocument(image:image,viewSize:NSSize(width:320,height:240),selection:NSRect(x:20,y:30,width:180,height:140))
        let crop=try #require(doc.raster.crop(doc.selection,viewSize:doc.viewSize)),plain=try #require(doc.render())
        #expect(plain.width==crop.width && plain.height==crop.height)
        let actual=ScreenshotRaster(plain),expected=ScreenshotRaster(crop)
        #expect(ScreenshotRaster.hex(try #require(actual.color(at:NSPoint(x:37,y:51),viewSize:NSSize(width:360,height:280)))) == ScreenshotRaster.hex(try #require(expected.color(at:NSPoint(x:37,y:51),viewSize:NSSize(width:360,height:280)))))
        doc.checkpoint();doc.cornerRadius=18
        let rounded=try #require(doc.render()),pixel=try #require(ScreenshotRaster(rounded).colorAtPixel(x:0,y:0))
        #expect(pixel.alphaComponent==0)
        doc.shadow=true;let shadowed=try #require(doc.render());#expect(shadowed.width==plain.width+24 && shadowed.height==plain.height+24)
        doc.undo();#expect(doc.cornerRadius==0 && !doc.shadow)
    }

    private func descendants(of view:NSView)->[NSView] {
        view.subviews.flatMap {[$0]+descendants(of:$0)}
    }

    @Test func restyledControlsKeepOriginalPlacementAndFullToggleHitArea() throws {
        let canvas=NSRect(x:0,y:0,width:1100,height:900)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let crop=NSRect(x:100,y:100,width:500,height:300)
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:crop)
        window.contentView=view;view.selectTool(.text);view.layoutSubtreeIfNeeded()
        #expect(view.editorHeaderFrameForTesting.origin == NSPoint(x:100,y:64))
        #expect(view.editorToolbarFrameForTesting.origin == NSPoint(x:100,y:410))
        #expect(view.editorOptionsFrameForTesting.origin == NSPoint(x:100,y:454))
        let buttons=descendants(of:view).compactMap{$0 as?NSButton}
        let actions=try ["pin","cancel","save","copy","undo","long","ocr"].map { action in
            try #require(buttons.first{$0.identifier?.rawValue==action})
        }
        #expect(actions.allSatisfy{$0.superview === actions[0].superview})
        let shadow=try #require(buttons.first{$0.title=="阴影" && $0.superview?.frame==view.editorHeaderFrameForTesting})
        for point in [NSPoint(x:11,y:shadow.bounds.midY),NSPoint(x:40,y:shadow.bounds.midY)] {
            let down=try event(.leftMouseDown,shadow.convert(point,to:view),in:view)
            #expect(shadow.cell!.hitTest(for:down,in:shadow.bounds,of:shadow).contains(.trackableArea))
        }
        let before=view.document.shadow;shadow.performClick(nil)
        #expect(view.document.shadow != before)
        view.installOCRForTesting([ScreenshotOCRBox(text:"sample",rect:NSRect(x:0.1,y:0.1,width:0.3,height:0.1))])
        for action in ["copyOCRSelection","copyOCRAll","translateOCR","translateAndCopyOCR"] {
            let button=try #require(buttons.first{$0.identifier?.rawValue==action})
            #expect(button.layer?.borderWidth == 0.5)
            #expect(button.layer?.cornerRadius == 7)
            #expect(button.layer?.backgroundColor != nil)
        }
    }

    @Test func compactBottomToolbarFitsStandardAndNarrowCanvasesWithoutLosingActions() throws {
        let expectedActions=[
            "tool:select","tool:rectangle","tool:ellipse","tool:line",
            "tool:arrow","tool:pen","tool:mask","tool:text","tool:number",
            "tool:highlight","pin","undo","ocr","translate","cancel","long","save","copy"
        ]
        for canvas in [NSRect(x:0,y:0,width:1100,height:900),
                       NSRect(x:0,y:0,width:470,height:580),
                       NSRect(x:0,y:0,width:360,height:520)] {
            let crop=NSRect(x:30,y:55,width:min(260,canvas.width-60),height:170)
            let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:crop)
            view.layoutSubtreeIfNeeded()
            let toolbar=try #require(view.subviews.first {
                $0.frame==view.editorToolbarFrameForTesting &&
                $0.subviews.compactMap{$0 as? NSButton}.count==18
            })
            let buttons=toolbar.subviews.compactMap{$0 as? NSButton}
            #expect(buttons.compactMap{$0.identifier?.rawValue}==expectedActions)
            #expect(canvas.contains(toolbar.frame))
            #expect(toolbar.frame.width <= canvas.width-8)
            #expect(toolbar.frame.height <= (canvas.width >= 510 ? 41 : 72))
            #expect(buttons.allSatisfy {
                toolbar.bounds.contains($0.frame) && $0.frame.width >= 24 &&
                $0.frame.height >= 24 && $0.action != nil
            })
            for i in buttons.indices {
                for j in buttons.indices where j>i {
                    #expect(!buttons[i].frame.intersects(buttons[j].frame))
                }
            }
            if canvas.width>=510 {
                #expect(toolbar.frame.width<=544)
                #expect(Set(buttons.map{$0.frame.minY}).count==1)
            } else if canvas.width<440 {
                #expect(Set(buttons.map{$0.frame.minY}).count==2)
            }
            #expect(view.editorOptionsFrameForTesting.minY==toolbar.frame.maxY+4)
        }
    }

    @Test func compactToolbarReflowsWhenScreenshotCanvasResizes() throws {
        let initial=NSRect(x:0,y:0,width:1100,height:850)
        let view=ScreenshotEditingView(frame:initial,image:try fixture(),
                                       selection:NSRect(x:30,y:60,width:260,height:175))
        let toolbar=try #require(view.subviews.first {
            $0.frame==view.editorToolbarFrameForTesting &&
            $0.subviews.compactMap{$0 as? NSButton}.count==18
        })
        view.layoutSubtreeIfNeeded()
        #expect(toolbar.frame.size==NSSize(width:535,height:40))
        view.frame.size=NSSize(width:360,height:540)
        view.needsLayout=true;view.layoutSubtreeIfNeeded()
        #expect(toolbar.frame.height==70)
        #expect(toolbar.frame.maxX<=view.bounds.maxX-4)
        #expect(view.editorOptionsFrameForTesting.minY==toolbar.frame.maxY+4)
        view.frame.size=initial.size
        view.needsLayout=true;view.layoutSubtreeIfNeeded()
        #expect(toolbar.frame.size==NSSize(width:535,height:40))
        #expect(Set(toolbar.subviews.compactMap{$0 as? NSButton}.map{$0.frame.minY}).count==1)
    }

    @Test func compactOptionPanelsUseHalfAreaWithoutShrinkingInteractiveControls() throws {
        let canvas=NSRect(x:0,y:0,width:1350,height:990)
        let baselines:[ScreenshotEditTool:CGFloat]=[
            .rectangle:612*156,.ellipse:612*156,.line:612*90,
            .arrow:612*90,.pen:612*156,.mask:612*156,
            .text:612*248,.number:612*316,.highlight:612*78
        ]
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),
                                       selection:NSRect(x:130,y:110,width:650,height:300))
        for (tool,area) in baselines {
            view.selectTool(tool)
            view.layoutSubtreeIfNeeded()
            let panel=view.editorOptionsFrameForTesting
            print("COMPACT_PANEL \(tool) \(Int(panel.width))x\(Int(panel.height)) ratio=\(String(format:"%.3f",panel.width*panel.height/area))")
            #expect(!panel.isEmpty)
            #expect(panel.width*panel.height<=area*0.50,
                    "The \(tool) panel must be <= 50% of previous \(area)pt²")
            #expect(canvas.contains(panel))
            let scroll=try #require(descendants(of:view).compactMap{$0 as? NSScrollView}.first)
            let content=try #require(scroll.documentView)
            let controls=content.subviews.compactMap{$0 as? NSControl}.filter{!$0.isHidden}
            #expect(!controls.isEmpty)
            for control in controls {
                #expect(content.bounds.contains(control.frame),
                        "\(tool): \(type(of:control)) escaped layout")
                #expect(scroll.documentVisibleRect.contains(control.frame),
                        "\(tool): \(type(of:control)) clipped by compact panel")
                let minimumHeight:CGFloat=[ScreenshotEditTool.rectangle,.ellipse,.line,.arrow,.pen,.mask,.text,.number,.highlight].contains(tool) ? 16 :
                    (control is NSTextField && !(control as! NSTextField).isEditable ? 17:20)
                #expect(control.frame.height >= minimumHeight)
                if control is NSColorWell {
                    if [.rectangle,.ellipse,.line,.arrow,.pen,.mask].contains(tool) {
                        #expect(control.frame.size==NSSize(width:16,height:16))
                    } else if [.text,.number].contains(tool) {
                        #expect([16,18].contains(Int(control.frame.width)))
                    } else {
                        #expect(control.frame.width>=46)
                    }
                }
                if control is NSSlider {#expect(control.frame.height >= ([ScreenshotEditTool.rectangle,.ellipse,.line,.arrow,.pen,.mask,.text,.number,.highlight].contains(tool) ? 17:24))}
                if let button=control as? NSButton {#expect(button.action != nil)}
            }
            for (i,first) in controls.enumerated() {
                for second in controls.dropFirst(i+1) {
                    #expect(!first.frame.intersects(second.frame),
                            "\(tool): overlapping controls \(first) and \(second)")
                }
            }
        }
        view.installOCRForTesting([ScreenshotOCRBox(text:"ABC",rect:NSRect(x:0.2,y:0.2,width:0.4,height:0.06))])
        view.layoutSubtreeIfNeeded()
        let panel=view.editorOptionsFrameForTesting
        print("COMPACT_OCR \(Int(panel.width))x\(Int(panel.height)) ratio=\(String(format:"%.3f",panel.width*panel.height/CGFloat(612*136)))")
        #expect(panel.width*panel.height <= CGFloat(612*136)*0.5,
                "OCR panel also must fit into half its old footprint")
        let scroll=try #require(descendants(of:view).compactMap{$0 as? NSScrollView}.first)
        let ocr=try #require(scroll.documentView)
        let actions=ocr.subviews.compactMap{$0 as? NSButton}.filter{!$0.isHidden && !($0 is NSPopUpButton)}
        #expect(actions.count==5)
        #expect(actions.allSatisfy{ocr.bounds.contains($0.frame)})
    }

    @Test func ocrButtonContentHasConsistentLeftAndRightPadding() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1120,height:890),
                                       image:try fixture(),
                                       selection:NSRect(x:110,y:120,width:520,height:250))
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"OCR preview",rect:NSRect(x:0.2,y:0.2,width:0.4,height:0.08))
        ])
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let content=try #require(scroll.documentView)
        for width in [1120.0,470,320] {
            view.frame.size.width=width
            view.needsLayout=true;view.layoutSubtreeIfNeeded()
            let buttons=content.subviews.compactMap{$0 as?NSButton}.filter{!$0.isHidden && !($0 is NSPopUpButton)}
            #expect(buttons.count==5)
            for button in buttons {
                let bitmap=try #require(button.bitmapImageRepForCachingDisplay(in:button.bounds))
                button.cacheDisplay(in:button.bounds,to:bitmap)
                let scale=CGFloat(bitmap.pixelsWide)/button.bounds.width
                var minX=bitmap.pixelsWide
                var maxX=0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        guard let rgb=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
                              rgb.alphaComponent>0.85,
                              rgb.redComponent>0.72,
                              rgb.greenComponent>0.72,
                              rgb.blueComponent>0.72 else {continue}
                        minX=min(minX,x);maxX=max(maxX,x)
                    }
                }
                #expect(minX<bitmap.pixelsWide,"Button \(button.title) must show its icon")
                let left=CGFloat(minX)/scale
                let right=CGFloat(bitmap.pixelsWide-1-maxX)/scale
                print("OCR_CONTENT_INSETS \(button.title) width=\(width) left=\(left) right=\(right)")
                #expect(left>=8,"OCR icon too close to the left edge: \(button.title)")
                #expect(right>=3,"OCR title clipped against the right edge: \(button.title)")
            }
        }
    }

    @Test func ocrOfflineTranslationDirectionUsesDetectedLanguage() {
        #expect(ScreenshotOCRTranslationLanguage.source(
            for:"今天天气非常好，我们准备一起去公园散步，顺便喝杯咖啡。")=="zh-Hans")
        #expect(ScreenshotOCRTranslationLanguage.defaultTarget(
            for:"今天天气非常好，我们准备一起去公园散步，顺便喝杯咖啡。")=="en")
        #expect(ScreenshotOCRTranslationLanguage.defaultTarget(
            for:"The weather is lovely today and we are going to the park for a walk.")=="zh-Hans")
    }

    @Test func ocrTranslationSegmentsFollowOriginalLinesOrSelectedText() throws {
        let source=NSRect(x:80,y:100,width:520,height:320)
        var selection=ScreenshotOCRTextSelection()
        selection.install([
            ScreenshotOCRBox(text:"First line",rect:NSRect(x:0.1,y:0.12,width:0.6,height:0.09)),
            ScreenshotOCRBox(text:"Second line",rect:NSRect(x:0.1,y:0.24,width:0.7,height:0.09)),
            ScreenshotOCRBox(text:"Separate paragraph",rect:NSRect(x:0.1,y:0.51,width:0.7,height:0.09))
        ],region:NSRect(x:0,y:0,width:1,height:1))
        let all=ScreenshotOCRTranslationSegment.make(from:selection,in:source)
        #expect(all.count==2)
        #expect(all.map(\.text)==["First line Second line","Separate paragraph"])
        #expect(all[0].rect==selection.frame(for:0,in:source).union(selection.frame(for:1,in:source)))
        #expect(all[1].rect==selection.frame(for:2,in:source))
        let first=selection.frame(for:0,in:source)
        selection.selectWord(at:NSPoint(x:first.minX+8,y:first.midY),in:source)
        let selected=ScreenshotOCRTranslationSegment.make(from:selection,in:source)
        #expect(selected.count==1)
        #expect(selected[0].text=="First")
        #expect(first.contains(selected[0].rect))
        let overlay=ScreenshotOCRTranslationOverlay(text:"A much longer translated sentence",
            sourceRect:selected[0].rect)
        #expect(source.contains(overlay.displayRect(within:source)))
    }

    @Test func ocrTranslationSeparatesThreeVisuallySpacedParagraphs() throws {
        // Real OCR boxes have fairly large line heights. The former
        // 1.15-height gap threshold treated these three distinct text blocks
        // as one translation request even though each block has two lines.
        let region=NSRect(x:0,y:0,width:1200,height:400)
        var selection=ScreenshotOCRTextSelection()
        let rows:[(String,CGFloat,CGFloat)]=[
            ("Work on the real project.",12,0.84),
            ("Follow the actual tool results as they arrive.",58,0.89),
            ("Give it a team.",126,0.83),
            ("Workers keep their context.",173,0.87),
            ("Stay in control of long tasks.",241,0.83),
            ("Compact and Resume carries the history.",288,0.90)
        ]
        selection.install(rows.map { text,y,width in
            ScreenshotOCRBox(text:text,rect:NSRect(x:0.01,y:y/region.height,
                                                    width:width,height:32/region.height))
        },region:NSRect(x:0,y:0,width:1,height:1))
        let segments=ScreenshotOCRTranslationSegment.make(from:selection,in:region)
        #expect(segments.count==3)
        #expect(segments.map(\.text)==[
            "Work on the real project. Follow the actual tool results as they arrive.",
            "Give it a team. Workers keep their context.",
            "Stay in control of long tasks. Compact and Resume carries the history."
        ])
        let translated=segments.enumerated().map { index,segment in
            ScreenshotOCRTranslationOverlay(text:"翻译段落\(index + 1)。",
                                            sourceRect:segment.rect,sourceLineHeight:segment.lineHeight)
        }
        let layout=try #require(ScreenshotOCRTranslationLayout.arrange(translated,within:region))
        #expect(layout.count==3)
        for pair in zip(layout,layout.dropFirst()) {
            #expect(pair.0.lines.last!.rect.maxY < pair.1.lines.first!.rect.minY)
        }
    }

    @Test func translatedParagraphsReflowCompletelyWithoutOverlapping() throws {
        // Three two-line English paragraphs from the reported screenshot.
        // The last paragraph previously collided with its English source and
        // was visibly truncated by a forced single-line drawing rectangle.
        let region=NSRect(x:0,y:0,width:1490,height:355)
        var original=ScreenshotOCRTextSelection()
        let rows:[(String,CGFloat)]=[
            ("Work on the real project. Let ChatGPT read and edit files, run tests,",16),
            ("keep terminals open and use your desktop. Follow the actual tool results.",68),
            ("Give it a team. Split independent jobs across workers, then bring results back.",148),
            ("Workers keep their context, so the next task can pick up where they left off.",190),
            ("Stay in control of long tasks. Send a correction while work runs.",268),
            ("Goal follows unfinished work; Loop keeps working within your brief.",313)
        ]
        original.install(rows.map{ScreenshotOCRBox(text:$0.0,
            rect:NSRect(x:0.008,y:$0.1/region.height,
                        width:0.94,height:29/region.height))},
            region:NSRect(x:0,y:0,width:1,height:1))
        let segments=ScreenshotOCRTranslationSegment.make(from:original,in:region)
        #expect(segments.count==3)
        let translated=[
            "处理真实项目。让 ChatGPT 读取并编辑文件，运行测试，保持终端打开并使用您的桌面。按照实际的工具结果进行操作。",
            "给它一个团队。将独立的任务分配给不同的工作者，然后把他们的成果带回来。工作者会保留各自的上下文，因此下一个任务可以从他们离开的地方继续。",
            "保持对长期任务的控制。在任务运行时发送更正。目标是跟随未完成的工作；循环会持续运行。紧凑与恢复会将会话和工作者历史记录带入新的对话中。"
        ]
        let overlays=zip(segments,translated).map{
            ScreenshotOCRTranslationOverlay(text:$0.1,sourceRect:$0.0.rect,
                                            sourceLineHeight:$0.0.lineHeight)
        }
        let arranged=try #require(ScreenshotOCRTranslationLayout.arrange(overlays,within:region))
        #expect(arranged.count==3)
        for (index,paragraph) in arranged.enumerated() {
            #expect(!paragraph.lines.isEmpty)
            #expect(paragraph.lines.allSatisfy{region.contains($0.rect)})
            let visible=paragraph.lines.map(\.text).joined()
            let expected=translated[index].replacingOccurrences(of:" ",with:"")
            #expect(visible.replacingOccurrences(of:" ",with:"")==expected)
            #expect(paragraph.lines.allSatisfy{$0.fontSize>=8})
            if index>0 {
                let prior=arranged[index-1]
                #expect(prior.lines.last!.rect.maxY<=paragraph.lines.first!.rect.minY)
            }
        }
        #expect(arranged.last!.lines.last!.rect.maxY <= region.maxY)
    }

    @Test func translatedLongLineWrapsWithoutDroppingCharacters() throws {
        let bounds=NSRect(x:0,y:0,width:240,height:290)
        let text="翻译后的每个字符都必须被完整显示，长句需要自动换行，不能把尾部内容裁掉或者与下一段重叠。"
        let item=ScreenshotOCRTranslationOverlay(text:text,
            sourceRect:NSRect(x:8,y:12,width:180,height:28),sourceLineHeight:28)
        let layout=try #require(ScreenshotOCRTranslationLayout.arrange([item],within:bounds))
        let lines=try #require(layout.first?.lines)
        #expect(lines.count>=3)
        #expect(lines.map(\.text).joined()==text)
        #expect(lines.allSatisfy{bounds.contains($0.rect)})
        for pair in zip(lines,lines.dropFirst()) {
            #expect(pair.0.rect.maxY<=pair.1.rect.minY)
        }
    }

    @Test func translatedTextRestoresPlainBackgroundWithoutLabelBoxes() throws {
        let width=320,height=160
        let context=try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
            bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x:40,y:70,width:130,height:20))
        let image=try #require(context.makeImage())
        let background=NSBitmapImageRep(cgImage:image)
        let overlay=ScreenshotOCRTranslationOverlay(text:"Translated content",
            sourceRect:NSRect(x:40,y:70,width:130,height:20))
            .withRestoredBackground(from:background,
                                    in:NSRect(x:0,y:0,width:width,height:height))
        let restored=try #require(overlay.restoredBackground)
        let bitmap=try #require(restored.representations.compactMap{$0 as?NSBitmapImageRep}.first)
        let center=try #require(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?
            .usingColorSpace(.deviceRGB))
        #expect(center.redComponent>0.95)
        #expect(center.greenComponent>0.95)
        #expect(center.blueComponent>0.95)
        #expect(overlay.displayRect(within:NSRect(x:0,y:0,width:width,height:height)).minX==40)
    }

    @Test func multiLineTranslationRestoresEachSourceLineWithoutCopyingOtherText() throws {
        let width=420,height=300
        let context=try #require(CGContext(data:nil,width:width,height:height,
            bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.05,green:0.07,blue:0.11,alpha:1))
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        let positions:[CGFloat]=[24,53,120,149,216,245]
        let lines=positions.map{NSRect(x:35,y:$0,width:300,height:18)}
        // Draw bright text-shaped strokes in all six rows. A sample taken
        // from any other OCR row would visibly reintroduce English glyphs.
        context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1))
        for line in lines {
            for x in stride(from:Int(line.minX),to:Int(line.maxX),by:13) {
                context.fill(CGRect(x:CGFloat(x),y:CGFloat(height)-line.maxY,
                                    width:5,height:line.height))
            }
        }
        let bitmap=NSBitmapImageRep(cgImage:try #require(context.makeImage()))
        let source=NSRect(x:0,y:0,width:width,height:height)
        let overlays=(0..<3).map { index in
            ScreenshotOCRTranslationOverlay(text:"译文第\(index+1)段",
                sourceRect:lines[index*2].union(lines[index*2+1]),
                sourceLineHeight:18,
                sourceLines:[lines[index*2],lines[index*2+1]])
                .withRestoredBackground(from:bitmap,in:source,excluding:lines)
        }
        #expect(overlays.count==3)
        for overlay in overlays {
            #expect(overlay.restoredPatches.count==2)
            for patch in overlay.restoredPatches {
                let restored=try #require(patch.image.representations
                    .compactMap{$0 as?NSBitmapImageRep}.first)
                for x in stride(from:5,to:restored.pixelsWide-5,by:17) {
                    let pixel=try #require(restored.colorAt(x:x,y:restored.pixelsHigh/2)?
                        .usingColorSpace(.deviceRGB))
                    #expect(pixel.redComponent<0.20,
                            "Original OCR glyphs must not reappear in the restored background.")
                }
            }
        }
        // The space separating source lines is deliberately left untouched.
        #expect(overlays[0].restoredPatches[0].rect.maxY <
                overlays[0].restoredPatches[1].rect.minY)
    }

    @Test func ocrTranslationDrawsOverSourceWithoutOpeningWindowAndKeepsCopy() throws {
        let canvas=NSRect(x:0,y:0,width:860,height:660)
        let source=NSRect(x:100,y:120,width:550,height:340)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:source,sourceRect:source)
        window.contentView=view
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"Hello first",rect:NSRect(x:0.1,y:0.1,width:0.5,height:0.09)),
            ScreenshotOCRBox(text:"Hello second",rect:NSRect(x:0.1,y:0.40,width:0.5,height:0.09))
        ])
        let windowsBefore=NSApp.windows.count
        let before=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:before)
        view.installOCRTranslationsForTesting(["你好一","你好二"],copyResult:true)
        #expect(NSApp.windows.count==windowsBefore)
        #expect(view.ocrTranslationOverlaysForTesting.map(\.text)==["你好一","你好二"])
        #expect(view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.allSatisfy{$0.restoredBackground != nil})
        #expect(NSPasteboard.general.string(forType:.string)=="你好一\n你好二")
        #expect(view.recognizedBoxes.map(\.text)==["Hello first","Hello second"])
        let after=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:after)
        #expect(before.representation(using:.png,properties:[:]) !=
                after.representation(using:.png,properties:[:]))
        let folder=URL(fileURLWithPath:
            "reports/screenshot-controls-2026-10-28/ocr-translation-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try #require(after.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("ocr-inline-text.png"))
        let point=NSPoint(x:source.minX+source.width*0.1+5,
                          y:source.minY+source.height*0.1+5)
        view.mouseDown(with:try event(.leftMouseDown,point,in:view))
        #expect(view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.count==2)
        #expect(view.ocrModeForTesting)
        view.performAction("ocr")
        #expect(view.ocrTranslationOverlaysForTesting.isEmpty)
        #expect(!view.ocrModeForTesting)
    }

    @Test func translatedListMarkersRemainInCopyAndOriginalOCRIsUnchanged() throws {
        let source=NSRect(x:100,y:120,width:550,height:340)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:850,height:650),
            image:try fixture(),selection:source,sourceRect:source)
        view.installOCRForTesting([
            .init(text:"• First item",rect:NSRect(x:0.1,y:0.12,width:0.6,height:0.07)),
            .init(text:"• Second item",rect:NSRect(x:0.1,y:0.38,width:0.6,height:0.07))
        ])
        view.installOCRTranslationsForTesting(["第一项","• 第二项"],copyResult:true)
        #expect(view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.map(\.text)==["• 第一项","• 第二项"])
        #expect(NSPasteboard.general.string(forType:.string)=="• 第一项\n• 第二项")
        #expect(view.recognizedBoxes.map(\.text)==["• First item","• Second item"])
    }

    @Test func translatedOCRTextSupportsDraggingCopyAndOriginalToggle() throws {
        let source=NSRect(x:100,y:120,width:550,height:340)
        let canvas=NSRect(x:0,y:0,width:850,height:650)
        let window=NSWindow(contentRect:canvas,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:source,sourceRect:source)
        window.contentView=view
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"Hello first",rect:NSRect(x:0.1,y:0.12,width:0.5,height:0.07)),
            ScreenshotOCRBox(text:"Hello second",rect:NSRect(x:0.1,y:0.38,width:0.55,height:0.07))
        ])
        view.installOCRTranslationsForTesting(["你好第一行","你好第二行"])
        let button=try #require(descendants(of:view).compactMap{$0 as?NSButton}
            .first{$0.identifier?.rawValue=="translateOCR"})
        let selected=try #require(descendants(of:view).compactMap{$0 as?NSButton}
            .first{$0.identifier?.rawValue=="copyOCRSelection"})
        let all=try #require(descendants(of:view).compactMap{$0 as?NSButton}
            .first{$0.identifier?.rawValue=="copyOCRAll"})
        #expect(button.title=="显示原文")
        let textOverlay=try #require(view.ocrTranslationOverlaysForTesting.first)
        let textRect=textOverlay.displayRect(within:source)
        let start=NSPoint(x:textRect.minX+1,y:textRect.midY)
        let end=NSPoint(x:textRect.maxX-1,y:textRect.midY)
        view.mouseDown(with:try event(.leftMouseDown,start,in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,end,in:view))
        view.mouseUp(with:try event(.leftMouseUp,end,in:view))
        #expect(view.ocrSelectionForTesting.contains("你好"))
        selected.performClick(nil)
        #expect(NSPasteboard.general.string(forType:.string)==view.ocrSelectionForTesting)
        all.performClick(nil)
        #expect(NSPasteboard.general.string(forType:.string)=="你好第一行\n你好第二行")
        button.performClick(nil)
        #expect(button.title=="显示译文")
        #expect(!view.ocrShowingTranslationForTesting)
        all.performClick(nil)
        #expect(NSPasteboard.general.string(forType:.string)=="Hello first\nHello second")
        button.performClick(nil)
        #expect(button.title=="显示原文")
        #expect(view.ocrShowingTranslationForTesting)
        #expect(view.ocrTranslationOverlaysForTesting.count==2)
        button.performClick(nil)
        let original=NSPoint(x:source.minX+source.width*0.1+2,
                             y:source.minY+source.height*0.12+5)
        view.mouseDown(with:try event(.leftMouseDown,original,in:view))
        #expect(button.title=="翻译")
        #expect(view.ocrTranslationOverlaysForTesting.isEmpty)
    }

    @Test func translatedSelectionUsesOneOpaqueBackgroundAndRestoresOriginal() throws {
        let source=NSRect(x:90.25,y:100.5,width:640,height:360)
        let selection=source.insetBy(dx:40,dy:40)
        for level:CGFloat in [0.08,0.92] {
            let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1280,pixelsHigh:720,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            let background=NSColor(deviceRed:level,green:level,blue:level,alpha:1)
            let mark=NSColor(deviceRed:1,green:0.1,blue:0.5,alpha:1)
            let outside=NSColor(deviceRed:1,green:0.6,blue:0.1,alpha:1)
            for y in 0..<720 {for x in 0..<1280 {
                let inside=(80..<1200).contains(x) && (80..<640).contains(y)
                let missedText=(520..<660).contains(x) && (340..<370).contains(y)
                bitmap.setColor(missedText ? mark:inside ? background:outside,atX:x,y:y)
            }}
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),
                styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;defer{window.close()}
            let view=ScreenshotEditingView(frame:window.contentView!.bounds,image:try #require(bitmap.cgImage),
                selection:selection,sourceRect:source)
            window.contentView=view
            view.installOCRForTesting([.init(text:"Source text",rect:
                NSRect(x:90.0/640,y:85.0/360,width:220.0/640,height:22.0/360))])
            func capture() throws ->NSBitmapImageRep {
                let image=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:image)
                return image
            }
            func sample(_ image:NSBitmapImageRep,_ x:CGFloat,_ y:CGFloat) throws ->NSColor {
                let scale=CGFloat(image.pixelsWide)/view.bounds.width
                return try #require(image.colorAt(x:Int((source.minX+x)*scale),y:Int((source.minY+y)*scale))?
                    .usingColorSpace(.deviceRGB))
            }
            let before=try capture(),expected=try sample(before,70,170)
            view.installOCRTranslationsForTesting(["译文"],copyResult:true)
            let after=try capture()
            let folder=URL(fileURLWithPath:"reports/ocr-solid-background-2026-10-29")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try #require(after.representation(using:.png,properties:[:]))
                .write(to:folder.appendingPathComponent(level<0.5 ? "dark-translated.png":"light-translated.png"))
            var error:CGFloat=0
            for y in stride(from:CGFloat(160),through:250,by:10) {
                for x in stride(from:CGFloat(70),through:560,by:10) {
                    let pixel=try sample(after,x,y)
                    error=max(error,abs(pixel.redComponent-expected.redComponent),
                        abs(pixel.greenComponent-expected.greenComponent),abs(pixel.blueComponent-expected.blueComponent),
                        abs(pixel.alphaComponent-1))
                }
            }
            #expect(error<0.015,"The entire translation selection must be solid, including text missed by OCR.")
            #expect(NSPasteboard.general.string(forType:.string)=="译文")
            let outsideBefore=try sample(before,20,200),outsideAfter=try sample(after,20,200)
            #expect(abs(outsideBefore.redComponent-outsideAfter.redComponent)<0.005)
            let toggle=try #require(descendants(of:view).compactMap{$0 as?NSButton}
                .first{$0.identifier?.rawValue=="translateOCR"})
            toggle.performClick(nil)
            let original=try capture()
            let originalMark=try sample(original,280,175),beforeMark=try sample(before,280,175)
            #expect(abs(originalMark.redComponent-beforeMark.redComponent)<0.005)
            #expect(abs(originalMark.greenComponent-beforeMark.greenComponent)<0.005)
            #expect(abs(originalMark.blueComponent-beforeMark.blueComponent)<0.005)
            #expect(!view.ocrShowingTranslationForTesting)
        }
    }

    @Test func compactOCRInspectorShowsCopyAndTranslationActions() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1120,height:890),
                                        image:try fixture(),
                                        selection:NSRect(x:100,y:110,width:510,height:260))
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"一段测试文字",rect:NSRect(x:0.2,y:0.2,width:0.4,height:0.06))
        ])
        view.layoutSubtreeIfNeeded()
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let content=try #require(scroll.documentView)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:394,height:84))
        let expected:[(String,NSRect)]=[
            ("copyOCRSelection",NSRect(x:8,y:34,width:84,height:22)),
            ("copyOCRAll",NSRect(x:100,y:34,width:84,height:22)),
            ("translateOCR",NSRect(x:192,y:34,width:88,height:22)),
            ("translateAndCopyOCR",NSRect(x:288,y:34,width:98,height:22)),
            ("ocrTranslationSettings",NSRect(x:294,y:59,width:92,height:20))
        ]
        let actions=content.subviews.compactMap{$0 as?NSButton}.filter{!$0.isHidden && !($0 is NSPopUpButton)}
        #expect(actions.count==5)
        #expect(Set(actions.map{$0.title})==Set(["复制选中","复制全部","翻译","翻译并复制","翻译设置"]))
        #expect(actions.filter{["translateOCR","translateAndCopyOCR"].contains($0.identifier?.rawValue ?? "")}
            .allSatisfy{($0.menu?.items.count ?? 0) >= 2})
        #expect(view.ocrTranslationTextForTesting=="一段测试文字")
        for (identifier,expectedFrame) in expected {
            let button=try #require(actions.first{$0.identifier?.rawValue==identifier})
            #expect(button.frame==expectedFrame)
            #expect(button.font?.pointSize==10)
            #expect(button.layer?.cornerRadius==7)
            #expect(button.action != nil && button.isEnabled)
            #expect(!(button.toolTip ?? "").isEmpty)
            #expect(content.bounds.contains(button.frame))
            #expect(scroll.documentVisibleRect.contains(button.frame))
        }
        let all=try #require(actions.first{$0.identifier?.rawValue=="copyOCRAll"})
        #expect(all.title=="复制全部")
        all.performClick(nil)
        #expect(NSPasteboard.general.string(forType:.string)=="一段测试文字")
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:394,height:84))
        #expect(content.subviews.allSatisfy{$0.isHidden || $0.toolTip != "设置分隔线"})
        let status=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{!$0.isHidden})
        #expect(status.frame==NSRect(x:8,y:62,width:278,height:14))
        #expect(status.font?.pointSize==10)
        #expect(status.lineBreakMode == .byTruncatingTail)
        #expect(!(status.toolTip ?? "").isEmpty)
        #expect(content.bounds.contains(status.frame))
        for (index,first) in actions.enumerated() {
            for second in actions.dropFirst(index+1) {
                #expect(!first.frame.intersects(second.frame))
            }
        }
        let folder=URL(fileURLWithPath:
            "reports/ocr-streaming-2026-10-28")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let host=try #require(scroll.superview)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("ocr-compact.png"))
    }

    @Test func compactOCRReflowsAndKeepsStatusVisibleDuringProcessing() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1080,height:840),
                                        image:try fixture(),
                                        selection:NSRect(x:75,y:120,width:500,height:230))
        view.installOCRForTesting([
            ScreenshotOCRBox(text:"Hello OCR",rect:NSRect(x:0.2,y:0.2,width:0.3,height:0.06))
        ])
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let content=try #require(scroll.documentView)
        for width in [1080.0,470,360,320,205] {
            view.frame.size=NSSize(width:width,height:780)
            view.needsLayout=true
            view.layoutSubtreeIfNeeded()
            let expectedSize=width>=402 ? NSSize(width:394,height:84) : NSSize(width:194,height:140)
            #expect(view.editorOptionsFrameForTesting.size==expectedSize)
            #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
            let controls=content.subviews.compactMap{$0 as?NSButton}.filter{!$0.isHidden && !($0 is NSPopUpButton)}
            #expect(controls.count==5)
            #expect(controls.allSatisfy{content.bounds.contains($0.frame)})
            #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
            for (index,a) in controls.enumerated() {
                for b in controls.dropFirst(index+1) {
                    #expect(!a.frame.intersects(b.frame))
                }
            }
            let label=try #require(content.subviews.compactMap{$0 as?NSTextField}
                .first{!$0.isHidden})
            #expect(content.bounds.contains(label.frame))
            #expect(scroll.documentVisibleRect.contains(label.frame))
            if width == 470 || width == 320 {
                let folder=URL(fileURLWithPath:
                    "reports/ocr-streaming-2026-10-28")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let host=try #require(scroll.superview)
                let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:]))
                    .write(to:folder.appendingPathComponent(width == 470 ? "ocr-medium.png" : "ocr-narrow.png"))
            }
        }
        view.setOCRProcessingForTesting(true)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:194,height:140))
        let buttons=content.subviews.compactMap{$0 as?NSButton}.filter{!$0.isHidden && !($0 is NSPopUpButton)}
        #expect(buttons.count==5)
        #expect(buttons.filter{$0.identifier?.rawValue != "ocrTranslationSettings"}.allSatisfy{!$0.isEnabled})
        #expect(buttons.first{$0.identifier?.rawValue == "ocrTranslationSettings"}?.isEnabled == true)
        let status=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{!$0.isHidden})
        #expect(status.stringValue.contains("识别"))
        view.setOCRProcessingForTesting(false)
        #expect(buttons.allSatisfy{$0.isEnabled})
        view.performAction("ocr") // Leaving OCR should restore prior tool UI.
        #expect(!view.ocrModeForTesting)
        #expect(status.font?.pointSize==12)
        #expect(status.textColor==NSColor.white)
        #expect(status.toolTip==nil)
    }

    @Test func rectangleInspectorHasLogicalSectionsAndShortControls() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1200,height:900),
                                       image:try fixture(),
                                       selection:NSRect(x:120,y:120,width:550,height:280))
        view.selectTool(.rectangle);view.layoutSubtreeIfNeeded()
        let scroll=try #require(descendants(of:view).compactMap{$0 as? NSScrollView}.first)
        let content=try #require(scroll.documentView)
        let controls=content.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
        func button(_ title:String)throws -> NSButton {
            try #require(controls.compactMap{$0 as?NSButton}.first{$0.title==title})
        }
        func slider(_ tip:String)throws -> NSSlider {
            try #require(controls.compactMap{$0 as?NSSlider}.first{$0.toolTip==tip})
        }
        let fill=try button("实心"),rounded=try button("圆角")
        let stroke=try slider("线条 / 画笔粗细")
        let opacity=try slider("不透明度")
        let corners=try slider("矩形圆角大小")
        let color=try #require(controls.compactMap{$0 as?NSColorWell}.first)
        let lines=content.subviews.filter{
            !$0.isHidden && $0.toolTip=="设置分隔线"
        }
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:460,height:52))
        #expect(lines.count==2)
        #expect(stroke.frame.width==72 && opacity.frame.width==72 &&
                corners.frame.width==72)
        #expect(stroke.frame.height==17 && opacity.frame.height==17 && corners.frame.height==17)
        #expect(stroke.frame.minX==opacity.frame.minX)
        #expect(stroke.frame.minX==60)
        let sizeLabel=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.stringValue=="大小"})
        let opacityLabel=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.stringValue=="不透明度"})
        #expect(sizeLabel.font?.pointSize==8)
        #expect(opacityLabel.font?.pointSize==8)
        // The left captions must use the same primary text colour as the
        // custom-drawn right switches, not secondaryLabelColor.
        #expect(sizeLabel.textColor == NSColor.labelColor)
        #expect(opacityLabel.textColor == NSColor.labelColor)
        // NSTextField's cell renders its baseline higher than the right
        // toggle's NSString drawing at identical frame origins.
        #expect(sizeLabel.frame.minY == fill.frame.minY+2.5)
        #expect(opacityLabel.frame.minY == rounded.frame.minY+2.5)
        #expect(opacity.frame.minX-opacityLabel.frame.maxX==5)
        #expect(opacity.frame.minY-stroke.frame.maxY==4)
        #expect(corners.frame.minX-rounded.frame.maxX <= 6)
        #expect(stroke.controlSize == .mini && opacity.controlSize == .mini &&
                corners.controlSize == .mini)
        #expect(fill.frame.minY==stroke.frame.minY)
        #expect(rounded.frame.minY==opacity.frame.minY)
        #expect(rounded.frame.maxX < corners.frame.minX)
        #expect(color.frame.size==NSSize(width:16,height:16))
        #expect(color.frame.maxX < fill.frame.minX)
        let opacityInput=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="矩形不透明度（0–100%）"})
        #expect(opacityInput.isEditable)
        #expect(opacityInput.frame.size==NSSize(width:31,height:17))
        #expect(opacityInput.frame.minX==138)
        #expect(opacityInput.frame.midY==opacity.frame.midY)
        for control in controls {
            #expect(content.bounds.contains(control.frame))
            if let target=control as? NSButton,["实心","圆角"].contains(target.title) {
                #expect(target.action != nil)
            }
        }
        #expect(scroll.documentVisibleRect.contains(content.bounds))
        let host=try #require(scroll.superview)
        let folder=URL(fileURLWithPath:"reports/screenshot-controls-2026-10-11/rectangle-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("rectangle-compact.png"))
    }

    @Test func rectanglePaletteFourPlusThreePlusOneAndEditableOpacity() throws {
        let suite="MacStateTest.RectangleThreeColumns.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1080,height:850),
                                       image:try fixture(),
                                       selection:NSRect(x:100,y:100,width:520,height:230),
                                       preferences:defaults)
        view.selectTool(.rectangle)
        let content=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first?.documentView)
        let palette=content.subviews.compactMap{$0 as?NSButton}
            .filter{$0.toolTip=="标注颜色" && !$0.isHidden}
            .sorted{$0.tag < $1.tag}
        #expect(palette.count==7)
        for (index,button) in palette.enumerated() {
            #expect(button.tag==index)
            #expect(button.frame.size==NSSize(width:16,height:16))
            #expect(button.layer?.cornerRadius==8)
            #expect(button.frame.minY == (index<4 ? 7:28))
            #expect(button.frame.minX == 191+CGFloat(index%4)*20)
        }
        let black=try #require(palette[5].layer?.backgroundColor)
        let white=try #require(palette[6].layer?.backgroundColor)
        #expect((NSColor(cgColor:black)?.usingColorSpace(.sRGB)?.redComponent ?? 1)<0.05)
        #expect((NSColor(cgColor:white)?.usingColorSpace(.sRGB)?.redComponent ?? 0)>0.95)
        let custom=try #require(content.subviews.compactMap{$0 as?NSColorWell}.first{$0.frame.width==16})
        #expect(custom.frame==NSRect(x:251,y:28,width:16,height:16))
        #expect(custom.action != nil)
        let opacityInput=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="矩形不透明度（0–100%）"})
        #expect(opacityInput.action != nil && opacityInput.isEditable)
        opacityInput.stringValue="37"
        _ = NSApp.sendAction(try #require(opacityInput.action),to:opacityInput.target,from:opacityInput)
        #expect(opacityInput.stringValue=="37")
        #expect(abs((defaults.dictionary(forKey:"screenshotEditor.annotationStyle.rectangle")?["opacity"] as? Double ?? 0)-0.37)<0.001)
        palette[5].performClick(nil)
        #expect(custom.color.usingColorSpace(.sRGB)?.redComponent == 0)
        palette[6].performClick(nil)
        #expect(custom.color.usingColorSpace(.sRGB)?.redComponent == 1)

        view.selectTool(.ellipse)
        let ellipsePalette=content.subviews.compactMap{$0 as?NSButton}.filter{$0.toolTip=="标注颜色" && !$0.isHidden}
        #expect(ellipsePalette.count==7)
        #expect(ellipsePalette.allSatisfy{$0.frame.size==NSSize(width:16,height:16)})
        // The circle shares the rectangle's compact primary-colour captions.
        let sizeCaption=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{$0.stringValue=="大小"})
        let opacityCaption=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{$0.stringValue=="不透明度"})
        #expect(sizeCaption.textColor == NSColor.labelColor)
        #expect(opacityCaption.textColor == NSColor.labelColor)
        #expect(sizeCaption.font?.pointSize==8)
        #expect(opacityCaption.font?.pointSize==8)
        view.selectTool(.number)
        #expect(sizeCaption.textColor == NSColor.labelColor)
        #expect(opacityCaption.textColor == NSColor.labelColor)
        #expect(sizeCaption.font?.pointSize==8)
        #expect(opacityCaption.font?.pointSize==8)
        view.selectTool(.highlight)
        #expect(sizeCaption.textColor == NSColor.labelColor)
        #expect(opacityCaption.textColor == NSColor.labelColor)
        #expect(sizeCaption.font?.pointSize==8)
        #expect(opacityCaption.font?.pointSize==8)
        view.selectTool(.select)
        #expect(sizeCaption.textColor == NSColor.secondaryLabelColor)
        #expect(opacityCaption.textColor == NSColor.secondaryLabelColor)
        #expect(sizeCaption.font?.pointSize==11)
        #expect(opacityCaption.font?.pointSize==11)
    }

    @Test func ellipseInspectorMatchesRectangleExceptCornerRadius() throws {
        let canvas=NSRect(x:0,y:0,width:1180,height:850)
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),
                                       selection:NSRect(x:100,y:100,width:530,height:230))
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let document=try #require(scroll.documentView)
        func visible(_ id:String)->NSControl? {
            document.subviews.compactMap{$0 as?NSControl}
                .first{$0.toolTip==id && !$0.isHidden}
        }
        view.selectTool(.rectangle)
        let rectangleFrames=Dictionary(uniqueKeysWithValues:document.subviews
            .compactMap{$0 as?NSControl}.filter{!$0.isHidden}
            .map{(ObjectIdentifier($0),$0.frame)})
        let rectanglePalette=try #require(visible("矩形不透明度（0–100%）"))
        #expect(rectanglePalette.frame==NSRect(x:138,y:28,width:31,height:17))

        view.selectTool(.ellipse);view.layoutSubtreeIfNeeded()
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:344,height:52))
        let controls=document.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
        let common:[String]=["大小","不透明度","实心"]
        for title in common {
            let match=try #require(controls.first{($0 as?NSTextField)?.stringValue==title ||
                                                ($0 as?NSButton)?.title==title})
            #expect(match.frame==rectangleFrames[ObjectIdentifier(match)])
        }
        let opacity=try #require(visible("圆形不透明度（0–100%）") as? NSTextField)
        #expect(opacity.isEditable)
        #expect(opacity.frame==rectanglePalette.frame)
        let sliders=controls.compactMap{$0 as?NSSlider}
        #expect(sliders.count==2) // line width + opacity, no corner-radius slider
        #expect(sliders.allSatisfy{$0.frame.width==72 && $0.frame.height==17})
        let lineField=try #require(controls.compactMap{$0 as?NSTextField}.first{$0.frame.minX==138 && $0.frame.minY==7})
        #expect(lineField.frame.size==opacity.frame.size)
        let fill=try #require(controls.compactMap{$0 as?NSButton}.first{$0.title=="实心"})
        #expect(fill.frame==NSRect(x:290,y:7,width:43,height:17))
        #expect(fill.action != nil)
        #expect(!controls.contains{($0 as?NSButton)?.title=="圆角"})
        #expect(!controls.contains{($0 as?NSSlider)?.toolTip=="矩形圆角大小"})
        #expect(controls.compactMap{$0 as?NSColorWell}.first?.frame ==
                NSRect(x:251,y:28,width:16,height:16))
        let palette=controls.compactMap{$0 as?NSButton}.filter{$0.toolTip=="标注颜色"}.sorted{$0.tag<$1.tag}
        #expect(palette.count==7)
        for (index,button) in palette.enumerated() {
            #expect(button.frame==NSRect(x:191+CGFloat(index%4)*20,
                                        y:7+CGFloat(index/4)*21,width:16,height:16))
            #expect(button.layer?.cornerRadius==8)
        }
        let black=try #require(palette[5].layer?.backgroundColor)
        let white=try #require(palette[6].layer?.backgroundColor)
        #expect((NSColor(cgColor:black)?.usingColorSpace(.sRGB)?.redComponent ?? 1)<0.05)
        #expect((NSColor(cgColor:white)?.usingColorSpace(.sRGB)?.redComponent ?? 0)>0.95)
        let labels=controls.compactMap{$0 as?NSTextField}
        for name in ["大小","不透明度"] {
            let label=try #require(labels.first{$0.stringValue==name})
            #expect(label.textColor==NSColor.labelColor)
            #expect(label.font?.pointSize==8)
        }
        #expect(controls.allSatisfy{document.bounds.contains($0.frame)})
        #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
        #expect(document.subviews.filter{!$0.isHidden && $0.toolTip=="设置分隔线"}.count==2)

        let folder=URL(fileURLWithPath:
            "reports/screenshot-controls-2026-10-11/ellipse-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let host=try #require(scroll.superview)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("ellipse-compact.png"))
    }

    @Test func ellipseShapeSettingsRemainIndependentFromRectangle() throws {
        let suite="MacStateTest.EllipseCompact.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:790),
                                       image:try fixture(),
                                       selection:NSRect(x:80,y:90,width:430,height:200),
                                       preferences:defaults)
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let doc=try #require(scroll.documentView)
        view.selectTool(.ellipse)
        let input=try #require(doc.subviews.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="圆形不透明度（0–100%）" && !$0.isHidden})
        input.stringValue="46"
        _=NSApp.sendAction(try #require(input.action),to:input.target,from:input)
        #expect(input.stringValue=="46")
        let fill=try #require(doc.subviews.compactMap{$0 as?NSButton}.first{$0.title=="实心" && !$0.isHidden})
        fill.performClick(nil)
        let palette=doc.subviews.compactMap{$0 as?NSButton}
            .filter{$0.toolTip=="标注颜色" && !$0.isHidden}.sorted{$0.tag<$1.tag}
        #expect(palette.count==7)
        palette[5].performClick(nil)
        let persisted=try #require(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.ellipse"))
        #expect(abs((persisted["opacity"] as? Double ?? 0)-0.46)<0.001)
        #expect(persisted["filled"] as? Bool == (fill.state == .on))
        let savedColor=try #require(persisted["color"] as? [Double])
        #expect(savedColor[0]<0.05 && savedColor[1]<0.05 && savedColor[2]<0.05)
        #expect(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.rectangle")==nil)

        view.selectTool(.rectangle)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:460,height:52))
        let rectangleRounded=doc.subviews.compactMap{$0 as?NSButton}
            .first{$0.title=="圆角" && !$0.isHidden}
        #expect(rectangleRounded != nil)
        view.selectTool(.ellipse)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:344,height:52))
        let currentInput=try #require(doc.subviews.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="圆形不透明度（0–100%）" && !$0.isHidden})
        #expect(currentInput.stringValue=="46")
    }

    @Test func compactStrokeToolsMatchShapesAndKeepEffectSelectorShort() throws {
        let canvas=NSRect(x:0,y:0,width:1170,height:850)
        let view=ScreenshotEditingView(frame:canvas,image:try fixture(),
                                       selection:NSRect(x:90,y:100,width:510,height:220))
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let document=try #require(scroll.documentView)
        let tools:[ScreenshotEditTool]=[.line,.arrow,.pen,.mask]
        for tool in tools {
            view.selectTool(tool)
            view.layoutSubtreeIfNeeded()
            let isEffect=[ScreenshotEditTool.pen,.mask].contains(tool)
            let expectedSize=NSSize(width:isEffect ? 424:280,height:52)
            #expect(view.editorOptionsFrameForTesting.size==expectedSize,
                    "\(tool) inspector should not use old long option rows")
            let controls=document.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
            func slider(_ tip:String)throws ->NSSlider {
                try #require(controls.compactMap{$0 as?NSSlider}.first{$0.toolTip==tip})
            }
            let width=try slider("线条 / 画笔粗细")
            let opacity=try slider("不透明度")
            #expect(width.frame==NSRect(x:60,y:7,width:72,height:17))
            #expect(opacity.frame==NSRect(x:60,y:28,width:72,height:17))
            #expect(width.controlSize == .mini && opacity.controlSize == .mini)
            let fields=controls.compactMap{$0 as?NSTextField}
            let widthField=try #require(fields.first{$0.frame.minX==138 && $0.frame.minY==7})
            let opacityField=try #require(fields.first{$0.toolTip=="不透明度（0–100%）"})
            #expect(widthField.frame.size==NSSize(width:31,height:17))
            #expect(opacityField.frame==NSRect(x:138,y:28,width:31,height:17))
            #expect(opacityField.isEditable)
            for name in ["大小","不透明度"] {
                let label=try #require(fields.first{$0.stringValue==name})
                #expect(label.font?.pointSize==8)
                #expect(label.textColor==NSColor.labelColor)
            }
            let colors=controls.compactMap{$0 as?NSButton}
                .filter{$0.toolTip=="标注颜色"}.sorted{$0.tag<$1.tag}
            #expect(colors.count==7)
            for (index,button) in colors.enumerated() {
                #expect(button.frame==NSRect(x:191+CGFloat(index%4)*20,
                                            y:7+CGFloat(index/4)*21,width:16,height:16))
                #expect(button.layer?.cornerRadius==8)
            }
            let black=try #require(colors[5].layer?.backgroundColor)
            let white=try #require(colors[6].layer?.backgroundColor)
            #expect((NSColor(cgColor:black)?.usingColorSpace(.sRGB)?.redComponent ?? 1)<0.05)
            #expect((NSColor(cgColor:white)?.usingColorSpace(.sRGB)?.redComponent ?? 0)>0.95)
            let custom=try #require(controls.compactMap{$0 as?NSColorWell}.first)
            #expect(custom.frame==NSRect(x:251,y:28,width:16,height:16))
            #expect(custom.action != nil)
            #expect(!controls.contains{($0 as?NSButton)?.title=="实心" || ($0 as?NSButton)?.title=="圆角"})
            let popup=controls.compactMap{$0 as?NSPopUpButton}
            #expect(popup.count==(isEffect ? 1:0))
            if isEffect {
                let effect=try #require(popup.first)
                #expect(effect.frame==NSRect(x:317,y:16,width:94,height:21))
                #expect(effect.numberOfItems==ScreenshotPaintMode.allCases.count)
                #expect(effect.action != nil)
            }
            let lines=document.subviews.filter{!$0.isHidden && $0.toolTip=="设置分隔线"}
            #expect(lines.count==(isEffect ? 2:1))
            #expect(controls.allSatisfy{document.bounds.contains($0.frame)})
            #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
            // Export all four native control snapshots for visual inspection.
            do {
                let folder=URL(fileURLWithPath:
                    "reports/screenshot-controls-2026-10-12/stroke-review")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let host=try #require(scroll.superview)
                let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try #require(bitmap.representation(using:.png,properties:[:]))
                    .write(to:folder.appendingPathComponent("\(tool.rawValue)-compact.png"))
            }
        }
    }

    @Test func strokeToolSettingsPersistIndependentlyAcrossToolChanges() throws {
        let suite="MacStateTest.StrokeCompact.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1100,height:830),
                                       image:try fixture(),
                                       selection:NSRect(x:100,y:110,width:520,height:240),
                                       preferences:defaults)
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let content=try #require(scroll.documentView)
        let tools:[ScreenshotEditTool]=[.line,.arrow,.pen,.mask]
        for (index,tool) in tools.enumerated() {
            view.selectTool(tool)
            let field=try #require(content.subviews.compactMap{$0 as?NSTextField}
                .first{$0.toolTip=="不透明度（0–100%）" && !$0.isHidden})
            let amount=37+index*11
            field.stringValue=String(amount)
            _=NSApp.sendAction(try #require(field.action),to:field.target,from:field)
            let presets=content.subviews.compactMap{$0 as?NSButton}
                .filter{$0.toolTip=="标注颜色" && !$0.isHidden}
                .sorted{$0.tag<$1.tag}
            #expect(presets.count==7)
            presets[5].performClick(nil) // black, shared shape palette
            if [ScreenshotEditTool.pen,.mask].contains(tool) {
                let effect=try #require(content.subviews.compactMap{$0 as?NSPopUpButton}
                    .first{$0.toolTip=="画笔 / 打码方式" && !$0.isHidden})
                effect.selectItem(at:tool == .pen ? 2:3)
                _=NSApp.sendAction(try #require(effect.action),to:effect.target,from:effect)
            }
            let saved=try #require(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.\(tool.rawValue)"))
            #expect(abs((saved["opacity"] as? Double ?? 0)-Double(amount)/100)<0.001)
            let rgb=try #require(saved["color"] as? [Double])
            #expect(rgb[0]<0.05 && rgb[1]<0.05 && rgb[2]<0.05)
            if tool == .pen {#expect(saved["mode"] as? String=="frosted")}
            if tool == .mask {#expect(saved["mode"] as? String=="mosaic")}
        }
        for (index,tool) in tools.enumerated() {
            view.selectTool(tool)
            let field=try #require(content.subviews.compactMap{$0 as?NSTextField}
                .first{$0.toolTip=="不透明度（0–100%）" && !$0.isHidden})
            #expect(field.stringValue==String(37+index*11))
        }
        view.selectTool(.text)
        let custom=try #require(content.subviews.compactMap{$0 as?NSColorWell}
            .first{$0.toolTip=="标注颜色"})
        #expect(custom.frame.width==16)
        view.selectTool(.number)
        #expect(custom.frame.width==16)
        view.selectTool(.highlight)
        // Highlight uses opacity and rounded-corner controls rather than a
        // foreground colour picker; the shared colour well stays hidden.
        #expect(custom.isHidden)
    }

    @Test func highlightInspectorUsesRectangleStyleWithoutDeadControls() throws {
        let suite="MacStateTest.CompactHighlight.\(UUID().uuidString)"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(
            frame:NSRect(x:0,y:0,width:1120,height:880),
            image:try fixture(),selection:NSRect(x:100,y:110,width:540,height:290),
            preferences:defaults)
        view.selectTool(.highlight);view.layoutSubtreeIfNeeded()
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let content=try #require(scroll.documentView)
        let controls=content.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:182,height:52))

        let opacityLabel=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.stringValue=="不透明度"})
        let opacity=try #require(controls.compactMap{$0 as?NSSlider}
            .first{$0.toolTip=="不透明度"})
        let opacityInput=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="高亮不透明度（0–100%）"})
        let rounded=try #require(controls.compactMap{$0 as?NSButton}
            .first{$0.title=="圆角"})
        let radius=try #require(controls.compactMap{$0 as?NSSlider}
            .first{$0.toolTip=="矩形圆角大小"})
        let radiusInput=try #require(controls.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="圆角大小（0–100）"})

        // Two 17pt rows with equal-length 72pt slider tracks, identical
        // editable 31pt values, and no duplicate corner-radius caption.
        #expect(opacityLabel.frame==NSRect(x:12,y:9.5,width:43,height:17))
        #expect(opacityLabel.font?.pointSize==8)
        #expect(opacityLabel.textColor==NSColor.labelColor)
        #expect(opacity.frame==NSRect(x:60,y:7,width:72,height:17))
        #expect(opacityInput.frame==NSRect(x:138,y:7,width:31,height:17))
        #expect(rounded.frame==NSRect(x:12,y:28,width:43,height:17))
        #expect(radius.frame==NSRect(x:60,y:28,width:72,height:17))
        #expect(radiusInput.frame==NSRect(x:138,y:28,width:31,height:17))
        #expect(opacity.controlSize == .mini && radius.controlSize == .mini)
        #expect(opacityInput.isEditable && radiusInput.isEditable)
        #expect(opacityInput.action != nil && radiusInput.action != nil)
        #expect(rounded.action != nil)
        #expect(controls.count==6)
        #expect(!controls.contains{$0 is NSColorWell})
        #expect(!controls.contains{($0 as?NSButton)?.toolTip=="标注颜色"})
        #expect(controls.allSatisfy{content.bounds.contains($0.frame)})
        #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
        for (index,first) in controls.enumerated() {
            for next in controls.dropFirst(index+1) {
                #expect(!first.frame.intersects(next.frame))
            }
        }

        // Verify actual settings, not just layout. Highlighter intensity
        // and rounded-corner radius must still persist independently.
        opacityInput.stringValue="43"
        _=NSApp.sendAction(try #require(opacityInput.action),
                           to:opacityInput.target,from:opacityInput)
        radiusInput.stringValue="18"
        _=NSApp.sendAction(try #require(radiusInput.action),
                           to:radiusInput.target,from:radiusInput)
        rounded.performClick(nil)
        let saved=try #require(defaults.dictionary(
            forKey:"screenshotEditor.annotationStyle.highlight"))
        #expect(abs((saved["opacity"] as? Double ?? 0)-0.43)<0.001)
        #expect(saved["cornerRadius"] as? Double == 18)
        #expect(saved["textRounded"] as? Bool == (rounded.state == .on))
        #expect(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.rectangle")==nil)

        view.selectTool(.rectangle)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:460,height:52))
        view.selectTool(.highlight)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:182,height:52))
        let restoredOpacity=try #require(content.subviews.compactMap{$0 as?NSTextField}
            .first{!$0.isHidden && $0.toolTip=="高亮不透明度（0–100%）"})
        #expect(restoredOpacity.stringValue=="43")

        let folder=URL(fileURLWithPath:
            "reports/screenshot-controls-2026-10-24/highlight-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let host=try #require(scroll.superview)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("highlight-compact.png"))
    }

    @Test func highlightCompactInspectorStaysUsableOnNarrowCanvas() throws {
        let view=ScreenshotEditingView(
            frame:NSRect(x:0,y:0,width:980,height:820),
            image:try fixture(),selection:NSRect(x:75,y:105,width:430,height:260))
        view.selectTool(.highlight)
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        let document=try #require(scroll.documentView)
        for width in [980.0,380,230,205] {
            view.frame.size=NSSize(width:width,height:780)
            view.needsLayout=true;view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
            #expect(document.frame.size==NSSize(width:182,height:52))
            let visible=document.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
            #expect(visible.count==6)
            #expect(visible.allSatisfy{document.bounds.contains($0.frame)})
            #expect(visible.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
        }
    }

    @Test func compactOptionsKeepOriginalControlSizesWhenCanvasNarrows() throws {
        let view=ScreenshotEditingView(
            frame:NSRect(x:0,y:0,width:1250,height:930),
            image:try fixture(),
            selection:NSRect(x:80,y:80,width:420,height:290))
        let tools:[ScreenshotEditTool]=[.rectangle,.ellipse,.line,.arrow,.pen,
                                         .mask,.text,.number,.highlight]
        let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
        for tool in tools {
            view.frame.size=NSSize(width:1250,height:930)
            view.selectTool(tool);view.layoutSubtreeIfNeeded()
            let content=try #require(scroll.documentView)
            let originals=Dictionary(uniqueKeysWithValues:content.subviews
                .compactMap{$0 as?NSControl}.filter{!$0.isHidden}
                .map{(ObjectIdentifier($0),$0.frame.size)})
            for width in [640.0,360.0] {
                view.frame.size=NSSize(width:width,height:650)
                view.needsLayout=true;view.layoutSubtreeIfNeeded()
                let document=try #require(scroll.documentView)
                let controls=document.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
                #expect(!controls.isEmpty)
                #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
                for control in controls {
                    #expect(document.bounds.contains(control.frame))
                    #expect(originals[ObjectIdentifier(control)] == control.frame.size,
                            "\(tool) changed the size of a control on width \(width)")
                }
                // When a large original control cannot fit a 360pt window,
                // horizontal scrolling preserves its full click target.
                if document.frame.width>scroll.contentView.bounds.width+1 {
                    #expect(scroll.hasHorizontalScroller)
                    let farRight=max(0,document.frame.width-scroll.contentView.bounds.width)
                    scroll.contentView.scroll(to:NSPoint(x:farRight,y:0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    #expect(scroll.documentVisibleRect.maxX >= document.frame.width-3)
                }
            }
        }
    }

    @Test func groupedStylePanelsPreserveControlsAndScrollToAllSettings() throws {
        let folder=URL(fileURLWithPath:"reports/screenshot-controls-2026-10-11/grouped")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for canvas in [NSRect(x:0,y:0,width:640,height:480),NSRect(x:0,y:0,width:1100,height:900)] {
            let view=ScreenshotEditingView(frame:canvas,image:try fixture(),selection:NSRect(x:80,y:80,width:400,height:180))
            for tool in [ScreenshotEditTool.rectangle,.ellipse,.line,.arrow,.pen,.mask,.text,.number,.highlight] {
                view.selectTool(tool);view.layoutSubtreeIfNeeded()
                let scroll=try #require(descendants(of:view).compactMap{$0 as?NSScrollView}.first)
                let content=try #require(scroll.documentView)
                #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
                for control in content.subviews.compactMap({$0 as?NSControl}) where !control.isHidden {
                    #expect(content.bounds.contains(control.frame))
                    #expect(control.frame.width>0 && control.frame.height>0)
                    if let value=control as?NSColorWell {#expect(value.target === view && value.action != nil)}
                    if let field=control as?NSTextField,field.isEditable {
                        let drawing=try #require(field.cell).drawingRect(forBounds:field.bounds)
                        #expect(abs(drawing.midY-field.bounds.midY)<1)
                        #expect(drawing.height<field.bounds.height)
                    }
                }
                if tool == .number {
                    let last=try #require(content.subviews.compactMap{$0 as?NSColorWell}.filter{!$0.isHidden}.max{$0.frame.maxY<$1.frame.maxY})
                    scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,content.frame.height-scroll.contentView.bounds.height)))
                    #expect(scroll.documentVisibleRect.intersects(last.frame))
                }
                if canvas.width>1000 && [.rectangle,.pen,.text,.number].contains(tool) {
                    let host=try #require(scroll.superview)
                    let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds));host.cacheDisplay(in:host.bounds,to:bitmap)
                    try #require(bitmap.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("\(tool.rawValue).png"))
                }
            }
        }
    }

    @Test func compactTopHeaderMatchesInspectorControlStyleAndHasRadiusLabel() throws {
        let suite="ScreenshotHeaderCompact.\(UUID().uuidString)"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:850),
            image:try fixture(),selection:NSRect(x:130,y:110,width:550,height:290),
            preferences:defaults)
        view.layoutSubtreeIfNeeded()
        let header=try #require(descendants(of:view).first{$0.frame == view.editorHeaderFrameForTesting && $0 !== view})
        let label=try #require(header.subviews.compactMap{$0 as?NSButton}
            .first{$0.title=="圆角"})
        let radius=try #require(header.subviews.compactMap{$0 as?NSSlider}.first)
        let input=try #require(header.subviews.compactMap{$0 as?NSTextField}
            .first{$0.toolTip=="圆角像素"})
        let shadow=try #require(header.subviews.compactMap{$0 as?NSButton}.first{$0.title=="阴影"})
        #expect(header.frame.size==NSSize(width:318,height:32))
        #expect(label.frame==NSRect(x:106,y:7,width:25,height:17))
        #expect(label.frame.midY==radius.frame.midY)
        #expect(label.frame.midY==input.frame.midY)
        #expect(label.frame.midY==shadow.frame.midY)
        #expect(label.font?.pointSize==8 && !label.isBordered && label.action==nil)
        #expect(radius.frame==NSRect(x:135,y:7,width:72,height:17))
        #expect(radius.controlSize == .mini)
        #expect(input.frame==NSRect(x:214,y:7,width:31,height:17))
        #expect(input.font?.pointSize==8 && input.isEditable && input.action != nil)
        #expect(!input.isBezeled && !input.drawsBackground)
        #expect(input.layer?.cornerRadius==8)
        #expect(input.layer?.borderWidth==0.5)
        #expect(shadow.frame==NSRect(x:260,y:7,width:43,height:17))
        #expect(shadow.action != nil)
        #expect(header.subviews.compactMap{$0 as?NSControl}.allSatisfy{header.bounds.contains($0.frame)})
        #expect(view.bounds.contains(header.frame))
        input.stringValue="27"
        _=NSApp.sendAction(try #require(input.action),to:input.target,from:input)
        #expect(abs(view.document.cornerRadius-27*view.document.sourceRect.width/640)<0.01)
        #expect(ScreenshotEditPreferences.restore(defaults:defaults).radiusPixels==27)
        shadow.performClick(nil)
        #expect(view.document.shadow)
        #expect(ScreenshotEditPreferences.restore(defaults:defaults).shadow)
        let folder=URL(fileURLWithPath:
            "reports/screenshot-controls-2026-10-12/header-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let bitmap=try #require(header.bitmapImageRepForCachingDisplay(in:header.bounds))
        header.cacheDisplay(in:header.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("header-compact.png"))
    }

    @Test func topHeaderRadiusAndShadowGlyphsAreOpticallyAligned() throws {
        // NSTextField's native cell and the custom toggle can have matching
        // frames while painting glyphs at different baselines. Measure the
        // actual rendered white text pixels, not just NSView geometry.
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1050,height:850),
            image:try fixture(),selection:NSRect(x:130,y:110,width:550,height:290))
        view.layoutSubtreeIfNeeded()
        let header=try #require(descendants(of:view).first{
            $0.frame==view.editorHeaderFrameForTesting && $0 !== view
        })
        let label=try #require(header.subviews.compactMap{$0 as?NSButton}
            .first{$0.title=="圆角"})
        let shadow=try #require(header.subviews.compactMap{$0 as?NSButton}
            .first{$0.title=="阴影"})
        // The non-wrapped header has isolated text columns. The wrapped
        // header overlaps the size caption's x range, so its geometry is
        // tested separately instead of mixing pixels from two rows.
        for width in [1050.0] {
            view.frame.size.width=width
            view.needsLayout=true
            view.layoutSubtreeIfNeeded()
            let bitmap=try #require(header.bitmapImageRepForCachingDisplay(in:header.bounds))
            header.cacheDisplay(in:header.bounds,to:bitmap)
            let scale=CGFloat(bitmap.pixelsWide)/header.bounds.width
            func glyphCenter(_ rect:NSRect) throws ->CGFloat {
                // Limit the crop to the CJK characters; avoid the toggle track.
                let minX=Int(ceil((rect.minX+1)*scale))
                let maxX=Int(floor((rect.minX+min(22,rect.width-2))*scale))
                var weighted=0.0,total=0.0
                for y in 0..<bitmap.pixelsHigh {
                    for x in minX..<maxX {
                        guard let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
                              color.redComponent>0.65,
                              color.greenComponent>0.65,
                              color.blueComponent>0.65 else {continue}
                        let intensity=Double((color.redComponent+color.greenComponent+color.blueComponent)/3)
                        total+=intensity;weighted+=Double(y)*intensity
                    }
                }
                #expect(total>10,"The rendered CJK label must be visible")
                return CGFloat(weighted/max(total,1))
            }
            let labelY=try glyphCenter(label.frame)
            let shadowY=try glyphCenter(shadow.frame)
            print("HEADER_GLYPH_CENTERS width=\(width) round=\(labelY) shadow=\(shadowY) delta=\(abs(labelY-shadowY)) px")
            #expect(abs(labelY-shadowY)<=1.25,
                    "Rendered glyphs must align within 1.25 pixels at width \(width)")
        }
    }

    @Test func topHeaderReflowsOnNarrowCanvasWithoutMissingControls() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:680),
            image:try fixture(),selection:NSRect(x:90,y:125,width:360,height:230))
        let header=try #require(descendants(of:view).first{$0.frame == view.editorHeaderFrameForTesting && $0 !== view})
        for width in [900.0,320,230,205] {
            view.frame.size=NSSize(width:width,height:680)
            view.needsLayout=true;view.layoutSubtreeIfNeeded()
            let expectedHeight:CGFloat=width>=326 ? 32:52
            #expect(header.frame.height==expectedHeight)
            #expect(view.bounds.contains(view.editorHeaderFrameForTesting))
            let controls=header.subviews.compactMap{$0 as?NSControl}
            #expect(controls.count==5)
            #expect(controls.allSatisfy{header.bounds.contains($0.frame)})
            for (index,first) in controls.enumerated() {
                for second in controls.dropFirst(index+1) {
                    #expect(!first.frame.intersects(second.frame))
                }
            }
            let radius=try #require(controls.compactMap{$0 as?NSSlider}.first)
            let input=try #require(controls.compactMap{$0 as?NSTextField}
                .first{$0.toolTip=="圆角像素"})
            #expect(radius.frame.size==NSSize(width:72,height:17))
            #expect(input.frame.size==NSSize(width:31,height:17))
            let radiusLabel=try #require(controls.compactMap{$0 as?NSButton}.first{$0.title=="圆角"})
            #expect(radiusLabel.frame.midY==radius.frame.midY)
            let shadow=try #require(controls.compactMap{$0 as?NSButton}.first{$0.title=="阴影"})
            #expect(input.frame.midY==shadow.frame.midY)
        }
    }

    @Test func radiusShadowPreferencesRestoreAndControlLayoutFits() throws {
        let suite="ScreenshotEditPreferences-\(UUID().uuidString)"
        let defaults=try #require(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        ScreenshotEditPreferences.save(radiusPixels:24,shadow:true,defaults:defaults)
        let restored=ScreenshotEditPreferences.restore(defaults:defaults)
        #expect(restored.radiusPixels==24)
        #expect(restored.shadow)
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try fixture(),selection:NSRect(x:100,y:100,width:500,height:300),preferences:defaults)
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.document.cornerRadius-24*900/640)<0.01)
        #expect(view.document.shadow)
        let valueBeforeResize=view.radiusSliderValueForTesting
        let maximumBeforeResize=view.radiusSliderMaximumForTesting
        view.document.selection=NSRect(x:100,y:100,width:300,height:200)
        view.layoutSubtreeIfNeeded()
        #expect(view.radiusSliderValueForTesting==valueBeforeResize)
        #expect(view.radiusSliderMaximumForTesting==maximumBeforeResize)
        let textRect=view.radiusInputCellTitleRectForTesting
        let bounds=view.radiusInputBoundsForTesting
        #expect(abs(textRect.midY-bounds.midY)<2)
        #expect(view.shadowLabelFrameForTesting.maxX<=view.editorHeaderFrameForTesting.width)
        view.selectTool(.number);view.layoutSubtreeIfNeeded()
        #expect(view.numberStyleControlsFitForTesting)
        view.selectTool(.text);view.layoutSubtreeIfNeeded()
        #expect(view.textStyleControlsFitForTesting)
    }
    @Test func everyDrawingAndMaskModeChangesOnlyImageOutput() throws {
        let doc=ScreenshotEditDocument(image:try fixture(),viewSize:NSSize(width:640,height:480),selection:NSRect(x:100,y:100,width:300,height:220))
        let baseline=try #require(doc.render())
        for tool in ScreenshotEditTool.allCases where tool != .select {
            var item=ScreenshotAnnotation(tool:tool,start:NSPoint(x:125,y:125),end:NSPoint(x:220,y:180));item.text="Test 文本";item.points=[item.start,NSPoint(x:190,y:165),item.end];item.width=12;item.color = .red
            if tool == .number {item.end=NSPoint(x:160,y:150)}
            doc.annotations=[item]
            let output=try #require(doc.render());#expect(output.width==baseline.width && output.height==baseline.height)
            #expect(output.dataProvider?.data != baseline.dataProvider?.data)
        }
        for mode in [ScreenshotPaintMode.gaussian,.frosted,.mosaic] {
            for tool in [ScreenshotEditTool.mask,.pen] {
                var item=ScreenshotAnnotation(tool:tool,start:NSPoint(x:120,y:120),end:NSPoint(x:250,y:190));item.mode=mode;item.width=20;item.points=[item.start,item.end];doc.annotations=[item]
                let output=try #require(doc.render());#expect(output.dataProvider?.data != baseline.dataProvider?.data)
                let sampled=ScreenshotRaster(output),base=ScreenshotRaster(baseline)
                #expect(ScreenshotRaster.hex(try #require(sampled.colorAtPixel(x:280,y:200))) == ScreenshotRaster.hex(try #require(base.colorAtPixel(x:280,y:200))))
            }
        }
    }

    @Test func arrowHeadEndsAtTipWithoutRoundedShaftOvershoot() {
        let end=NSPoint(x:300,y:180)
        let arrow=ScreenshotArrowGeometry(start:NSPoint(x:100,y:100),end:end,width:18)
        #expect(arrow.tip==end)
        #expect(arrow.shaftEnd.x<end.x && arrow.shaftEnd.y<end.y)
        #expect(hypot(arrow.tip.x-arrow.shaftEnd.x,arrow.tip.y-arrow.shaftEnd.y)<=18*3.2+0.01)
        #expect(hypot(arrow.leftBase.x-arrow.rightBase.x,arrow.leftBase.y-arrow.rightBase.y)<18*2.7)
    }

    @Test func clickingAnnotationColorWellPresentsColorPanel() throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.close();NSColorPanel.shared.orderOut(nil)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try fixture(),selection:NSRect(x:200,y:170,width:300,height:220))
        window.contentView=view
        let well=view.annotationColorWellForTesting
        well.mouseDown(with:try event(.leftMouseDown,NSPoint(x:0,y:0),in:view))
        #expect(NSColorPanel.shared.isVisible)
    }
    @Test func initialMouseReleaseEntersEditorWithoutSaving() throws {
        let window=NSWindow(contentRect:NSRect(x:50,y:50,width:640,height:480),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotSelectionView(frame:NSRect(x:0,y:0,width:640,height:480),image:try fixture());window.contentView=view
        var completed=false;view.onFinish={_ in completed=true}
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:150,y:130),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:450,y:350),in:view))
        let editor=try #require(view.subviews.compactMap{$0 as? ScreenshotEditingView}.first)
        #expect(!completed && editor.document.selection==NSRect(x:150,y:130,width:300,height:220))
        editor.performAction("cancel");#expect(completed)
    }
    @Test func editorDraggingShapesSelectionAndUndo() throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try fixture(),selection:NSRect(x:200,y:170,width:300,height:220));window.contentView=view
        view.selectTool(.rectangle)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:230,y:200),in:view));view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:310,y:260),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:310,y:260),in:view))
        #expect(view.document.annotations.count==1 && view.document.annotations[0].rect.width==80)
        view.selectTool(.select)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:470,y:350),in:view));view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:495,y:380),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:495,y:380),in:view))
        #expect(view.document.selection.minX==225 && view.document.selection.minY==200)
        view.performAction("undo");#expect(view.document.selection.minX==200)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:500,y:390),in:view));view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:540,y:420),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:540,y:420),in:view))
        #expect(view.document.selection.width==340 && view.document.selection.height==250)
    }

    @Test func resizedTextAndNumberFillTheirBoxesThenTrimMargins() throws {
        let text="这是一段用于验证文本框缩放后自动换行并收紧左右上下边距的中文长文本内容"
        for tool in [ScreenshotEditTool.text,.number] {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;defer{window.close()}
            let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:700),image:try fixture(),selection:NSRect(x:100,y:100,width:700,height:500));window.contentView=view
            var item=ScreenshotAnnotation(tool:tool,start:NSPoint(x:220,y:220),end:NSPoint(x:340,y:260));item.text=text;item.textBoxWidthIsUserSet=true
            if tool == .number {item.end=NSPoint(x:220,y:220);item.labelSize=NSSize(width:120,height:40)}
            view.document.annotations=[item]
            let oldFrame=tool == .number ? item.textRect:item.rect
            let from=NSPoint(x:oldFrame.maxX,y:oldFrame.maxY),to=NSPoint(x:from.x+320,y:from.y+200)
            view.mouseDown(with:try event(.leftMouseDown,from,in:view))
            view.mouseDragged(with:try event(.leftMouseDragged,to,in:view))
            view.mouseUp(with:try event(.leftMouseUp,to,in:view))
            let resized=try #require(view.document.annotations.first)
            let finalFrame=tool == .number ? resized.textRect:resized.rect
            #expect(resized.text==text)
            #expect(resized.fontSize>item.fontSize)
            #expect(finalFrame.width<440)
            #expect(finalFrame.height<=240)
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
            let textBounds=(text as NSString).boundingRect(with:NSSize(width:finalFrame.width-12,height:finalFrame.height-8),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:resized.font,.paragraphStyle:paragraph])
            #expect(textBounds.height>resized.font.ascender-resized.font.descender+resized.font.leading+8)
            #expect(view.document.render() != nil)
        }
    }

    @Test func draggingCropUsesStableFrozenFrameUntilRelease() async throws {
        let window=NSWindow(contentRect:NSRect(x:50,y:50,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try fixture(),selection:NSRect(x:180,y:160,width:320,height:240));window.contentView=view
        for _ in 0..<100 {if view.previewReady {break};try await Task.sleep(nanoseconds:10_000_000)}
        #expect(view.previewReady)
        let token=view.renderTokenForTesting
        let oldSelection=view.document.selection
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:oldSelection.midX,y:oldSelection.midY),in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:oldSelection.midX+18,y:oldSelection.midY+12),in:view))
        view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:oldSelection.midX+42,y:oldSelection.midY+28),in:view))
        #expect(view.document.selection.origin != oldSelection.origin)
        #expect(view.renderTokenForTesting==token)
        view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:oldSelection.midX+42,y:oldSelection.midY+28),in:view))
        #expect(view.renderTokenForTesting != token)
        for _ in 0..<100 {if view.previewReady {break};try await Task.sleep(nanoseconds:10_000_000)}
        #expect(view.previewReady)
    }
    @Test func numberTextMovesSeparatelyAndCopyFinishesOnce() async throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try fixture(),selection:NSRect(x:180,y:150,width:500,height:350));window.contentView=view
        view.selectTool(.number);view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:250,y:230),in:view))
        let field=try #require(view.subviews.compactMap{$0 as? NSTextField}.first);field.stringValue="连接说明"
        view.selectTool(.select)
        let before=try #require(view.document.annotations.first)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:before.end.x+25,y:before.end.y+12),in:view));view.mouseDragged(with:try event(.leftMouseDragged,NSPoint(x:before.end.x+55,y:before.end.y+32),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:before.end.x+55,y:before.end.y+32),in:view))
        let moved=try #require(view.document.annotations.first);#expect(moved.start==before.start && moved.end.x==before.end.x+30 && moved.end.y==before.end.y+20)
        var count=0,action="",result:CGImage?;view.onFinish={image,kind in count+=1;action=kind;result=image}
        view.performAction("copy")
        for _ in 0..<300 {if count>0{break};try await Task.sleep(nanoseconds:10_000_000)}
        #expect(count==1 && action=="copy" && result != nil)
        view.performAction("copy");#expect(count==1)
    }
    @Test func pinnedWindowIsFloatingAndCloses() throws {
        let pin=ScreenshotPinnedWindow(image:try fixture(),frame:NSRect(x:50,y:50,width:320,height:240));var closed=false;pin.onClosed={closed=true};defer{pin.close()}
        #expect(pin.level == .floating && pin.isMovableByWindowBackground)
        pin.close();#expect(closed)
    }
    @Test func ocrOverlayAndFrozenFixtureVisualEvidence() async throws {
        let bitmap=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:900,pixelsHigh:650,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:900,height:650).fill()
        ("MACSTATE EDITOR 2026" as NSString).draw(at:NSPoint(x:200,y:280),withAttributes:[.font:NSFont.systemFont(ofSize:28),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;defer{window.close()}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:900,height:650),image:try #require(bitmap.cgImage),selection:NSRect(x:150,y:120,width:580,height:380));window.contentView=view
        view.performAction("ocr")
        for _ in 0..<6500 {if !view.isProcessing{break};try await Task.sleep(nanoseconds:10_000_000)}
        #expect(!view.isProcessing)
        #expect(view.recognizedBoxes.map(\.text).joined().contains("MACSTATE"))
        #expect(view.recognizedBoxes.allSatisfy{$0.rect.minX>=0 && $0.rect.minY>=0 && $0.rect.maxX<=1 && $0.rect.maxY<=1})
        view.selectTool(.number)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:235,y:235),in:view))
        let field=try #require(view.subviews.compactMap{$0 as? NSTextField}.first);field.stringValue="连接说明"
        view.selectTool(.select)
        let item=try #require(view.document.annotations.first)
        view.mouseDown(with:try event(.leftMouseDown,NSPoint(x:item.end.x+40,y:item.end.y+15),in:view));view.mouseUp(with:try event(.leftMouseUp,NSPoint(x:item.end.x+40,y:item.end.y+15),in:view))
        for _ in 0..<200 {if view.previewReady{break};try await Task.sleep(nanoseconds:10_000_000)}
        #expect(view.previewReady)
        view.layoutSubtreeIfNeeded()
        let cached=try #require(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:cached)
        let folder=URL(fileURLWithPath:"reports/screenshot-capture-editor-2026-10-09")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try #require(cached.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent("fixture-editor.png"))
        view.performAction("cancel")
    }

}
