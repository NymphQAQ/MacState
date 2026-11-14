import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor
struct ScreenshotNumberInspectorLayoutTests {
    private func image() throws -> CGImage {
        let ctx=try #require(CGContext(data:nil,width:640,height:480,
                            bitsPerComponent:8,bytesPerRow:0,
                            space:CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.darkGray.cgColor)
        ctx.fill(CGRect(x:0,y:0,width:640,height:480))
        return try #require(ctx.makeImage())
    }
    private func allViews(_ view:NSView)->[NSView] {
        [view]+view.subviews.flatMap{allViews($0)}
    }
    private func document(_ view:ScreenshotEditingView)throws->(NSScrollView,NSView) {
        let scroll=try #require(allViews(view).compactMap{$0 as?NSScrollView}.first)
        return (scroll,try #require(scroll.documentView))
    }
    private func visible<T:NSView>(_ doc:NSView,_ matching:(T)->Bool)throws->T {
        try #require(doc.subviews.compactMap{$0 as?T}.first{!$0.isHidden && matching($0)})
    }

    @Test func numberSharesTextInspectorAndAddsTwoRowsAtLowerRight() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1200,height:950),
                                       image:try image(),
                                       selection:NSRect(x:110,y:130,width:600,height:280))
        let (scroll,doc)=try document(view)
        view.selectTool(.text)
        let textFrames=Dictionary(uniqueKeysWithValues:
            doc.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
                .map{(ObjectIdentifier($0),$0.frame)})
        view.selectTool(.number)
        view.layoutSubtreeIfNeeded()
        #expect(view.editorOptionsFrameForTesting.size==NSSize(width:468,height:114))
        #expect(view.bounds.contains(view.editorOptionsFrameForTesting))

        // The top section must use the identical compact controls and
        // alignment as Text, including both tooltips and formatting buttons.
        for label in ["不透明度","大小","字体"] {
            let control:NSTextField=try visible(doc,{$0.stringValue==label})
            #expect(control.font?.pointSize==8)
            #expect(control.textColor==NSColor.labelColor)
            #expect(control.frame==textFrames[ObjectIdentifier(control)])
        }
        for tooltip in ["不透明度","字号"] {
            let control:NSSlider=try visible(doc,{$0.toolTip==tooltip})
            #expect(control.controlSize == .mini)
            #expect(control.frame==textFrames[ObjectIdentifier(control)])
        }
        let opacity:NSTextField=try visible(doc,{$0.toolTip=="序号不透明度（0–100%）"})
        let fontSize:NSTextField=try visible(doc,{$0.toolTip=="字号（8–144）"})
        #expect(opacity.frame==NSRect(x:138,y:7,width:31,height:17))
        #expect(fontSize.frame==NSRect(x:138,y:28,width:31,height:17))
        #expect(opacity.isEditable && fontSize.isEditable)
        let swatches=doc.subviews.compactMap{$0 as?NSButton}
            .filter{!$0.isHidden && $0.toolTip=="标注颜色"}
            .sorted{$0.tag<$1.tag}
        #expect(swatches.count==7)
        for (index,button) in swatches.enumerated() {
            #expect(button.frame==NSRect(x:191+CGFloat(index%4)*20,
                                        y:7+CGFloat(index/4)*21,width:16,height:16))
            #expect(button.layer?.cornerRadius==8)
        }
        let foreground:NSColorWell=try visible(doc,{$0.toolTip=="标注颜色"})
        #expect(foreground.frame==NSRect(x:251,y:28,width:16,height:16))
        let font:NSPopUpButton=try visible(doc,{$0.toolTip=="字体"})
        #expect(font.frame==NSRect(x:318,y:6,width:136,height:21))
        for (id,x) in [("format-bold",291),("format-underline",345),("format-italic",399)] {
            let button:NSButton=try visible(doc,{$0.identifier?.rawValue==id})
            #expect(button.frame==NSRect(x:x,y:29,width:46,height:17))
            #expect(button.action != nil)
        }

        // The lower-left text effects are identical to the text tool.
        for name in ["底色","圆角","描边","阴影"] {
            let control:NSButton=try visible(doc,{$0.title==name})
            #expect(control.frame==textFrames[ObjectIdentifier(control)])
        }
        for tooltip in ["文本底色","手动选择文字描边颜色"] {
            let well:NSColorWell=try visible(doc,{$0.toolTip==tooltip})
            #expect(well.frame==textFrames[ObjectIdentifier(well)])
        }
        let radius:NSSlider=try visible(doc,{$0.toolTip=="文本框底色圆角半径"})
        #expect(radius.frame==NSRect(x:153,y:65,width:72,height:17))
        let radiusInput:NSTextField=try visible(doc,{$0.toolTip=="底色圆角半径（0–60）"})
        #expect(radiusInput.frame==NSRect(x:231,y:65,width:31,height:17))

        // Two unique number controls fill only the red-marked lower-right
        // space, with exactly the same short slider/input visual language.
        let numberColorLabel:NSTextField=try visible(doc,{$0.stringValue=="序号颜色"})
        let numberSizeLabel:NSTextField=try visible(doc,{$0.stringValue=="序号大小"})
        #expect(numberColorLabel.frame==NSRect(x:292,y:67.5,width:46,height:17))
        #expect(numberSizeLabel.frame==NSRect(x:292,y:90.5,width:46,height:17))
        #expect(numberColorLabel.font?.pointSize==8 && numberColorLabel.textColor==NSColor.labelColor)
        #expect(numberSizeLabel.font?.pointSize==8 && numberSizeLabel.textColor==NSColor.labelColor)
        let numberColor:NSColorWell=try visible(doc,{$0.toolTip=="序号圆点与连接线颜色"})
        #expect(numberColor.frame==NSRect(x:342,y:65,width:18,height:18))
        #expect(numberColor.action != nil)
        let numberSize:NSSlider=try visible(doc,{$0.toolTip=="序号圆点大小"})
        #expect(numberSize.frame==NSRect(x:342,y:88,width:72,height:17))
        #expect(numberSize.controlSize == .mini)
        let numberInput:NSTextField=try visible(doc,{$0.toolTip=="序号大小（8–80）"})
        #expect(numberInput.frame==NSRect(x:422,y:88,width:31,height:17))
        #expect(numberInput.isEditable && numberInput.action != nil)

        let rules=doc.subviews.filter{!$0.isHidden && $0.toolTip=="设置分隔线"}
        #expect(rules.count==4)
        #expect(rules.contains{$0.frame==NSRect(x:12,y:55,width:444,height:1)})
        #expect(rules.contains{$0.frame==NSRect(x:279,y:63,width:1,height:43)})
        let controls=doc.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
        #expect(controls.allSatisfy{doc.bounds.contains($0.frame)})
        #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
        for (index,first) in controls.enumerated() {
            for other in controls.dropFirst(index+1) {
                #expect(!first.frame.intersects(other.frame))
            }
        }

        let folder=URL(fileURLWithPath:
            "reports/screenshot-controls-2026-10-12/number-review")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let host=try #require(scroll.superview)
        let bitmap=try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:]))
            .write(to:folder.appendingPathComponent("number-compact.png"))
    }

    @Test func numberColorsSizesAndTypographyPersistSeparatelyFromText() throws {
        let suite="MacStateTest.NumberCompact.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:1150,height:900),
                                       image:try image(),
                                       selection:NSRect(x:110,y:130,width:500,height:260),
                                       preferences:defaults)
        view.selectTool(.number)
        let (_,doc)=try document(view)
        let opacity:NSTextField=try visible(doc,{$0.toolTip=="序号不透明度（0–100%）"})
        opacity.stringValue="41"
        _=NSApp.sendAction(try #require(opacity.action),to:opacity.target,from:opacity)
        let fontSize:NSTextField=try visible(doc,{$0.toolTip=="字号（8–144）"})
        fontSize.stringValue="35"
        _=NSApp.sendAction(try #require(fontSize.action),to:fontSize.target,from:fontSize)
        let numberSize:NSTextField=try visible(doc,{$0.toolTip=="序号大小（8–80）"})
        numberSize.stringValue="29"
        _=NSApp.sendAction(try #require(numberSize.action),to:numberSize.target,from:numberSize)
        let well:NSColorWell=try visible(doc,{$0.toolTip=="序号圆点与连接线颜色"})
        well.color = .systemGreen
        _=NSApp.sendAction(try #require(well.action),to:well.target,from:well)
        let preset:NSButton=try visible(doc,{$0.toolTip=="标注颜色" && $0.tag==5})
        preset.performClick(nil)
        for id in ["format-bold","format-underline","format-italic"] {
            try visible(doc,{$0.identifier?.rawValue==id} as (NSButton)->Bool).performClick(nil)
        }
        for title in ["底色","圆角","描边","阴影"] {
            try visible(doc,{$0.title==title} as (NSButton)->Bool).performClick(nil)
        }
        let saved=try #require(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.number"))
        #expect(abs((saved["opacity"] as? Double ?? 0)-0.41)<0.001)
        #expect(saved["fontSize"] as? Double==35)
        #expect(saved["numberSize"] as? Double==29)
        #expect(saved["bold"] as? Bool==true)
        #expect(saved["underline"] as? Bool==true)
        #expect(saved["italic"] as? Bool==true)
        #expect(saved["background"] as? Bool==true)
        #expect(saved["textRounded"] as? Bool==true)
        #expect(saved["textOutline"] as? Bool==true)
        #expect(saved["textShadow"] as? Bool==true)
        let foreground=try #require(saved["color"] as? [Double])
        #expect(foreground[0]<0.05 && foreground[1]<0.05 && foreground[2]<0.05)
        let badge=try #require(saved["numberColor"] as? [Double])
        #expect(badge[1]>0.35 && badge[0]<0.5)
        #expect(defaults.dictionary(forKey:"screenshotEditor.annotationStyle.text")==nil)
        view.selectTool(.text)
        view.selectTool(.number)
        let restoredSize:NSTextField=try visible(doc,{$0.toolTip=="序号大小（8–80）"})
        let restoredOpacity:NSTextField=try visible(doc,{$0.toolTip=="序号不透明度（0–100%）"})
        #expect(restoredSize.stringValue=="29")
        #expect(restoredOpacity.stringValue=="41")
    }

    @Test func compactNumberInspectorScrollsOnNarrowCanvases() throws {
        let view=ScreenshotEditingView(frame:NSRect(x:0,y:0,width:980,height:810),
                                       image:try image(),
                                       selection:NSRect(x:50,y:65,width:420,height:190))
        view.selectTool(.number)
        let (scroll,doc)=try document(view)
        for width in [980.0,510,360] {
            view.frame.size=NSSize(width:width,height:740)
            view.needsLayout=true;view.layoutSubtreeIfNeeded()
            #expect(view.bounds.contains(view.editorOptionsFrameForTesting))
            #expect(doc.frame.size==NSSize(width:468,height:114))
            let controls=doc.subviews.compactMap{$0 as?NSControl}.filter{!$0.isHidden}
            #expect(controls.allSatisfy{doc.bounds.contains($0.frame)})
            if doc.frame.width>scroll.contentView.bounds.width+1 {
                #expect(scroll.hasHorizontalScroller)
                let farRight=max(0,doc.frame.width-scroll.contentView.bounds.width)
                scroll.contentView.scroll(to:NSPoint(x:farRight,y:0))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.documentVisibleRect.maxX>=doc.frame.width-3)
            } else {
                #expect(controls.allSatisfy{scroll.documentVisibleRect.contains($0.frame)})
            }
        }
        view.selectTool(.text)
        #expect(doc.frame.size==NSSize(width:468,height:114))
        let numberColor=try #require(doc.subviews.compactMap{$0 as?NSColorWell}
            .first{$0.toolTip=="序号圆点与连接线颜色"})
        #expect(numberColor.isHidden) // Number-only control must not leak into Text.
    }
}
