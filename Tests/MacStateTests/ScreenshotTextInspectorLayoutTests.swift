import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor
struct ScreenshotTextInspectorLayoutTests {
    private func image() throws -> CGImage {
        let ctx=try #require(CGContext(data:nil,width:640,height:480,
                           bitsPerComponent:8,bytesPerRow:0,
                           space:CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.darkGray.cgColor)
        ctx.fill(CGRect(x:0,y:0,width:640,height:480))
        return try #require(ctx.makeImage())
    }

    private func content(_ view:ScreenshotEditingView) throws -> (NSScrollView,NSView) {
        let scroll=try #require(view.subviews.flatMap{descendants($0)}.compactMap{$0 as?NSScrollView}.first)
        return (scroll,try #require(scroll.documentView))
    }
    private func descendants(_ view:NSView)->[NSView] {
        [view]+view.subviews.flatMap{descendants($0)}
    }
    private func visible<T:NSView>(_ source:NSView,_ type:T.Type,_ matches:(T)->Bool) throws ->T {
        try #require(source.subviews.compactMap{$0 as?T}.first{!$0.isHidden && matches($0)})
    }

    @Test func textToolHasThreeColumnsAndSeparatedReorderedEffects() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1250,height:940),
                                       image:try image(),
                                       selection:NSRect(x:100,y:110,width:570,height:260))
        view.selectTool(.text);view.layoutSubtreeIfNeeded()
        let (scroll,doc)=try content(view)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:468,height:114))
        let opacity=try visible(doc,NSSlider.self,{$0.toolTip=="不透明度"})
        let size=try visible(doc,NSSlider.self,{$0.toolTip=="字号"})
        #expect(opacity.frame==NSRect(x:60,y:7,width:72,height:17))
        #expect(size.frame==NSRect(x:60,y:28,width:72,height:17))
        #expect(opacity.controlSize == .mini && size.controlSize == .mini)
        let labelOpacity=try visible(doc,NSTextField.self,{$0.stringValue=="不透明度"})
        let labelSize=try visible(doc,NSTextField.self,{$0.stringValue=="大小"})
        #expect(labelOpacity.frame==NSRect(x:12,y:9.5,width:43,height:17))
        #expect(labelSize.frame==NSRect(x:12,y:30.5,width:42,height:17))
        #expect(labelOpacity.font?.pointSize==8 && labelOpacity.textColor==NSColor.labelColor)
        #expect(labelSize.font?.pointSize==8 && labelSize.textColor==NSColor.labelColor)
        let opacityInput=try visible(doc,NSTextField.self,{$0.toolTip=="文字不透明度（0–100%）"})
        let sizeInput=try visible(doc,NSTextField.self,{$0.toolTip=="字号（8–144）"})
        #expect(opacityInput.frame==NSRect(x:138,y:7,width:31,height:17))
        #expect(sizeInput.frame==NSRect(x:138,y:28,width:31,height:17))
        #expect(opacityInput.isEditable && sizeInput.isEditable)
        let palette=doc.subviews.compactMap{$0 as?NSButton}
            .filter{!$0.isHidden && $0.toolTip=="标注颜色"}.sorted{$0.tag<$1.tag}
        #expect(palette.count==7)
        for (index,swatch) in palette.enumerated() {
            #expect(swatch.frame==NSRect(x:191+CGFloat(index%4)*20,
                                        y:7+CGFloat(index/4)*21,width:16,height:16))
            #expect(swatch.layer?.cornerRadius==8)
        }
        let custom=try visible(doc,NSColorWell.self,{$0.toolTip=="标注颜色"})
        #expect(custom.frame==NSRect(x:251,y:28,width:16,height:16))
        let font=try visible(doc,NSPopUpButton.self,{$0.toolTip=="字体"})
        #expect(font.frame==NSRect(x:318,y:6,width:136,height:21))
        #expect(font.action != nil && font.numberOfItems>1)
        let fontLabel=try visible(doc,NSTextField.self,{$0.stringValue=="字体"})
        #expect(fontLabel.frame==NSRect(x:291,y:9.5,width:23,height:17))
        let formats=[("format-bold",291),("format-underline",345),("format-italic",399)]
        for (id,x) in formats {
            let button=try visible(doc,NSButton.self,{$0.identifier?.rawValue==id})
            #expect(button.frame==NSRect(x:x,y:29,width:46,height:17))
            #expect(button.action != nil)
        }
        let bg=try visible(doc,NSButton.self,{$0.title=="底色"})
        let rounded=try visible(doc,NSButton.self,{$0.title=="圆角"})
        let outline=try visible(doc,NSButton.self,{$0.title=="描边"})
        let shadow=try visible(doc,NSButton.self,{$0.title=="阴影"})
        #expect(bg.frame==NSRect(x:12,y:65,width:45,height:17))
        #expect(rounded.frame==NSRect(x:103,y:65,width:45,height:17))
        #expect(outline.frame==NSRect(x:12,y:88,width:45,height:17))
        #expect(shadow.frame==NSRect(x:103,y:88,width:45,height:17))
        #expect(rounded.frame.minX==shadow.frame.minX)
        #expect(rounded.frame.width==shadow.frame.width)
        let bgColor=try visible(doc,NSColorWell.self,{$0.toolTip=="文本底色"})
        let outlineColor=try visible(doc,NSColorWell.self,{$0.toolTip=="手动选择文字描边颜色"})
        #expect(bgColor.frame==NSRect(x:62,y:65,width:18,height:18))
        #expect(outlineColor.frame==NSRect(x:62,y:88,width:18,height:18))
        let radius=try visible(doc,NSSlider.self,{$0.toolTip=="文本框底色圆角半径"})
        // Same rounded-switch → slider → numeric-input arrangement as the
        // rectangle inspector: no second "圆角" caption in between.
        #expect(radius.frame==NSRect(x:153,y:65,width:72,height:17))
        #expect(radius.frame.minX-rounded.frame.maxX==5)
        #expect(doc.subviews.compactMap{$0 as?NSTextField}
            .filter{!$0.isHidden && $0.stringValue=="圆角"}.isEmpty)
        #expect(doc.subviews.compactMap{$0 as?NSButton}
            .filter{!$0.isHidden && $0.title=="圆角"}.count==1)
        let radiusValue=try visible(doc,NSTextField.self,{$0.toolTip=="底色圆角半径（0–60）"})
        #expect(radiusValue.frame==NSRect(x:231,y:65,width:31,height:17))
        #expect(radiusValue.frame.minX-radius.frame.maxX==6)
        let separators=doc.subviews.filter{!$0.isHidden && $0.toolTip=="设置分隔线"}
        #expect(separators.count==3)
        #expect(separators.contains{$0.frame==NSRect(x:12,y:55,width:444,height:1)})
        let controls=doc.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
        #expect(controls.allSatisfy{doc.bounds.contains($0.frame)})
        #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
        for (index,one) in controls.enumerated() {
            for two in controls.dropFirst(index+1) {
                #expect(!one.frame.intersects(two.frame))
            }
        }
        let folder=URL(fileURLWithPath:"reports/screenshot-controls-2026-10-12/text-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let host=try #require(scroll.superview)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("text-compact.png"))
    }

    @Test func compactTextControlsKeepStylePersistence() throws {
        let suite="MacStateTest.TextCompact.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1150,height:900),
                                       image:try image(),
                                       selection:NSRect(x:110,y:130,width:500,height:260),
                                       preferences:defaults)
        view.selectTool(.text)
        let (_,doc)=try content(view)
        let opacity=try visible(doc,NSTextField.self,{$0.toolTip=="文字不透明度（0–100%）"})
        opacity.stringValue="43"
        _=NSApp.sendAction(try #require(opacity.action),to:opacity.target,from:opacity)
        let size=try visible(doc,NSTextField.self,{$0.toolTip=="字号（8–144）"})
        size.stringValue="36"
        _=NSApp.sendAction(try #require(size.action),to:size.target,from:size)
        let black=try visible(doc,NSButton.self,{$0.toolTip=="标注颜色" && $0.tag==5})
        black.performClick(nil)
        for id in ["format-bold","format-underline","format-italic"] {
            try visible(doc,NSButton.self,{$0.identifier?.rawValue==id}).performClick(nil)
        }
        for title in ["底色","圆角","描边","阴影"] {
            try visible(doc,NSButton.self,{$0.title==title}).performClick(nil)
        }
        let radius=try visible(doc,NSTextField.self,{$0.toolTip=="底色圆角半径（0–60）"})
        radius.stringValue="24"
        _=NSApp.sendAction(try #require(radius.action),to:radius.target,from:radius)
        let values=try #require(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.text"))
        #expect(abs((values["opacity"] as? Double ?? 0)-0.43)<0.001)
        #expect(values["fontSize"] as? Double==36)
        #expect(values["bold"] as? Bool==true)
        #expect(values["underline"] as? Bool==true)
        #expect(values["italic"] as? Bool==true)
        #expect(values["textOutline"] as? Bool==true)
        #expect(values["textShadow"] as? Bool==true)
        #expect(values["background"] as? Bool==true)
        #expect(values["textRounded"] as? Bool==true)
        #expect(values["cornerRadius"] as? Double==24)
        let rgb=try #require(values["color"] as? [Double])
        #expect(rgb[0]<0.05 && rgb[1]<0.05 && rgb[2]<0.05)

        view.selectTool(.number)
        #expect(try visible(doc,NSColorWell.self,{$0.toolTip=="标注颜色"}).frame.width==16)
        // Number shares the same concise rounded switch, but exposes two
        // additional badge controls only within its own inspector.
        #expect(try visible(doc,NSButton.self,{$0.title=="圆角"}).frame.width==45)
        #expect(try visible(doc,NSColorWell.self,{$0.toolTip=="序号圆点与连接线颜色"}).frame.width==18)
        view.selectTool(.text)
        #expect(try visible(doc,NSButton.self,{$0.title=="圆角"}).frame.width==45)
        #expect(doc.subviews.compactMap{$0 as?NSTextField}
            .filter{!$0.isHidden && $0.stringValue=="圆角"}.isEmpty)
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:468,height:114))
        #expect(try visible(doc,NSTextField.self,{$0.toolTip=="文字不透明度（0–100%）"}).stringValue=="43")
        #expect(try visible(doc,NSTextField.self,{$0.toolTip=="字号（8–144）"}).stringValue=="36")
    }

    @Test func compactTextInspectorScrollsOnNarrowCanvasWithoutAffectingRectangle() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1000,height:840),
                                       image:try image(),
                                       selection:NSRect(x:60,y:70,width:480,height:180))
        view.selectTool(.text)
        let (scroll,doc)=try content(view)
        for width in [1000.0,540,360] {
            view.frame.size=NSSize(width:width,height:780)
            view.needsLayout=true;view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
            #expect(doc.frame.size==NSSize(width:468,height:114))
            let controls=doc.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
            #expect(controls.allSatisfy{doc.bounds.contains($0.frame)})
            if doc.frame.width>scroll.contentView.bounds.width+1 {
                #expect(scroll.hasHorizontalScroller)
                let right=max(0,doc.frame.width-scroll.contentView.bounds.width)
                scroll.contentView.scroll(to:NSPoint(x:right,y:0))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.documentVisibleRect.maxX >= doc.frame.width-3)
            } else {
                #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
            }
        }
        view.selectTool(.rectangle)
        #expect(doc.frame.size==NSSize(width:460,height:52))
        #expect(view.editorOptionsFrameForTesting.width==min(460,view.bounds.width-8))
        #expect(view.editorOptionsFrameForTesting.height==52)
    }
}
