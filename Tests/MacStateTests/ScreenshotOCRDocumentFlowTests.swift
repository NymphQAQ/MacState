import AppKit
import Testing
@testable import MacState

final class OCRDocumentProof:NSView {
    var overlays:[ScreenshotOCRTranslationOverlay]=[]
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        (overlays.first?.backgroundColor ?? .white).setFill();bounds.fill()
        for overlay in overlays {overlay.draw(in:bounds)}
    }
}

@Suite(.serialized) @MainActor struct ScreenshotOCRDocumentFlowTests {
    nonisolated private static let fixturePath = "reports/ocr-document-layout-2026-10-29"
    private let output=URL(fileURLWithPath:"reports/ocr-adaptive-anchors-2026-10-29")

    @Test func sameStyleUsesStableFontDuringStreaming() throws {
        let area=NSRect(x:0,y:0,width:800,height:500)
        let words=["HELLO WORLD", "iiiiiiii", "gggggggg"]
        let overlays=words.enumerated().map { index,text in
            ScreenshotOCRTranslationOverlay(text:text,sourceRect:NSRect(x:20,y:20+index*100,width:720,height:30),sourceLineHeight:24)
        } + [ScreenshotOCRTranslationOverlay(text:"Title",sourceRect:NSRect(x:20,y:340,width:720,height:50),sourceLineHeight:45)]
        let full=try #require(ScreenshotOCRTranslationLayout.arrange(overlays,within:area,streamingTarget:"en"))
        var partial=overlays
        for index in 1..<partial.count {partial[index].text=""}
        let early=try #require(ScreenshotOCRTranslationLayout.arrange(partial,within:area,streamingTarget:"en"))
        let sizes=full.prefix(3).compactMap{$0.lines.first?.fontSize}
        #expect(sizes.count==3 && (sizes.max() ?? 0)-(sizes.min() ?? 0)<0.01)
        #expect((full.last?.lines.first?.fontSize ?? 0)>(sizes.max() ?? 0)*1.4)
        #expect(early[0].lines.first?.fontSize==full[0].lines.first?.fontSize)
        #expect(early[0].lines.first?.rect==full[0].lines.first?.rect)
    }

    @Test func adaptiveFontsKeepEachParagraphAtItsOriginalStart() throws {
        let area=NSRect(x:0,y:0,width:480,height:360)
        let short=[20,140,260].map { y in
            ScreenshotOCRTranslationOverlay(text:"A short paragraph.",sourceRect:NSRect(x:20,y:y,width:360,height:60),sourceLineHeight:24)
        }
        var long=short;long[0].text=String(repeating:"An expanded English paragraph needs a smaller font to stay inside its own area. ",count:3)
        let compact=try #require(ScreenshotOCRTranslationLayout.arrange(short,within:area,streamingTarget:"en"))
        let expanded=try #require(ScreenshotOCRTranslationLayout.arrange(long,within:area,streamingTarget:"en"))
        #expect(expanded[0].lines.first?.fontSize==compact[0].lines.first?.fontSize)
        #expect((expanded.last?.lines.last?.rect.maxY ?? 0)>area.maxY)
        for result in [compact,expanded] {
            for (source,paragraph) in zip(short,result) {
                #expect(paragraph.lines.first?.rect.minX==source.sourceRect.minX)
                #expect((paragraph.lines.first?.rect.minY ?? 0)>=source.sourceRect.minY)
                #expect(paragraph.lines.map(\.text).joined().filter{!$0.isWhitespace}==paragraph.text.filter{!$0.isWhitespace})
            }
            #expect((result[1].lines.first?.rect.minY ?? 0)-(result[0].lines.last?.rect.maxY ?? 0)>=60-0.01)
        }
    }

    @Test(.enabled(if: ["chinese", "japanese"].allSatisfy {
        FileManager.default.fileExists(atPath: fixturePath + "/" + $0 + "-original.png")
    }, "Requires local OCR document screenshots"))
    func suppliedDocumentsKeepParagraphsAndCompleteEnglish() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: Self.fixturePath)
        let real=ProcessInfo.processInfo.environment["MACSTATE_REAL_DOCUMENT_TRANSLATION"]=="1"
        let phase=ProcessInfo.processInfo.environment["MACSTATE_DOCUMENT_PHASE"] ?? "adaptive"
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let session=ScreenshotOCRLocalSession();defer{session.shutdown()}
        var settings:ScreenshotOCRTranslationSettings?
        if real {
            let models=ScreenshotOCRLocalModels.discover(in:ScreenshotOCRLocalModels.roots())
            let model=try #require(models.first{$0.format == .mlx && $0.name.contains("HY-MT1.5")})
            settings=ScreenshotOCRTranslationSettings(localModelPath:model.path,localPython:ScreenshotOCRLocalRuntime.python.path)
        }
        for (name,source,expected) in [("chinese","zh-Hans",3),("japanese","ja",9)] {
            let bitmap=try #require(NSBitmapImageRep(data:Data(contentsOf:folder.appendingPathComponent(name+"-original.png"))))
            bitmap.size=NSSize(width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
            let area=NSRect(origin:.zero,size:bitmap.size)
            let sourceImage=try #require(bitmap.cgImage)
            let boxes=try await Task.detached(priority:.userInitiated) {
                try ScreenshotEditDocument.recognize(sourceImage)
            }.value
            var selection=ScreenshotOCRTextSelection()
            selection.install(boxes,region:NSRect(x:0,y:0,width:1,height:1))
            let segments=ScreenshotOCRTranslationSegment.make(from:selection,in:area)
            let translations:[ScreenshotOCRTranslationOverlay]
            if let settings {
                translations=try await ScreenshotOCRLocalTranslationService(session:session).translate(segments,target:"en",settings:settings,source:source)
                let cached=zip(segments,translations).map{["source":$0.0.text,"translation":$0.1.text]}
                try JSONSerialization.data(withJSONObject:cached,options:[.prettyPrinted,.sortedKeys])
                    .write(to:folder.appendingPathComponent(name+"-english.json"))
            } else {
                let cached=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent(name+"-english.json"))) as? [[String:String]])
                #expect(cached.map{($0["source"] ?? "").filter{!$0.isWhitespace}}==segments.map{$0.text.filter{!$0.isWhitespace}})
                translations=zip(segments,cached).map { segment,value in
                    .init(text:value["translation"] ?? "",sourceRect:segment.rect,sourceLineHeight:segment.lineHeight,
                        sourceLines:segment.sourceLines,sourceLineTexts:segment.sourceLineTexts,sourceText:segment.text)
                }
            }
            let prepared=await Task.detached(priority:.userInitiated) {
                let color=ScreenshotOCRTranslationBackground.color(from:bitmap,in:area,within:area,excluding:segments.flatMap(\.sourceLines))
                return translations.map { value in
                    var overlay=value.withRestoredBackground(from:bitmap,in:area,excluding:segments.flatMap(\.sourceLines))
                    overlay.backgroundColor=color;return overlay
                }
            }.value
            let layout=try #require(ScreenshotOCRTranslationLayout.arrange(prepared,within:area,streamingTarget:"en"))
            let evidence:[String:Any]=["boxes":selection.boxes.map{["text":$0.text,"rect":NSStringFromRect($0.rect)]},
                "paragraphs":segments.map{["text":$0.text,"rect":NSStringFromRect($0.rect),"rows":$0.sourceLines.map(NSStringFromRect)]},
                "translated":layout.map{["text":$0.text,"truncated":$0.isTruncated,"font":$0.lines.first?.fontSize ?? 0,
                    "rows":$0.lines.map{["text":$0.text,"rect":NSStringFromRect($0.rect)]}]}]
            try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])
                .write(to:output.appendingPathComponent(phase+"-"+name+".json"))
            let content=NSRect(origin:area.origin,size:NSSize(width:area.width,
                height:max(area.height,(layout.flatMap(\.lines).map{$0.rect.maxY}.max() ?? 0)+4)))
            let proof=OCRDocumentProof(frame:content);proof.overlays=layout
            let rendered=try #require(proof.bitmapImageRepForCachingDisplay(in:content))
            proof.cacheDisplay(in:content,to:rendered)
            try #require(rendered.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(phase+"-"+name+".png"))
            if name=="chinese" {#expect(layout.first?.lines.first?.style == ScreenshotOCRFontStyle())}
            if name=="japanese" {#expect(layout.dropFirst().first?.lines.first?.style == ScreenshotOCRFontStyle())}
            #expect(segments.count==expected,"Keep the source's paragraphs/list items instead of splitting inline code or merging adjacent bullets.")
            #expect(layout.allSatisfy{!$0.isTruncated},"The English translation must remain fully readable.")
            var previousBottom:CGFloat = -.greatestFiniteMagnitude
            for (original,paragraph) in zip(prepared,layout) {
                let row=original.sourceLines.first ?? original.sourceRect
                let ink=original.restoredPatches.first(where:{$0.rect.contains(NSPoint(x:row.midX,y:row.midY))})?.inkRect ?? row
                #expect((paragraph.lines.first?.rect.minY ?? 0)>=max(4,ink.minY,previousBottom+4)-0.01,"Paragraphs keep source positions unless earlier translated text needs the space.")
                previousBottom=paragraph.lines.last?.rect.maxY ?? previousBottom
                #expect(paragraph.lines.map(\.text).joined().filter{!$0.isWhitespace}==paragraph.text.filter{!$0.isWhitespace})
                #expect(paragraph.lines.allSatisfy{$0.rect.maxX<=area.maxX-12 && content.contains($0.rect)})
            }
            for (first,second) in zip(layout,layout.dropFirst()) {
                #expect((first.lines.last?.rect.maxY ?? 0)<(second.lines.first?.rect.minY ?? 0))
            }
            let sizes=layout.compactMap{$0.lines.first?.fontSize}
            if name=="japanese" {
                #expect((sizes.first ?? 0)>(sizes.dropFirst().max() ?? 0)*1.2)
            }
        }
    }
}
