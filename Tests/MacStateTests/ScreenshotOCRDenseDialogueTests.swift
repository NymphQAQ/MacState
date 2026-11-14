import AppKit
import Testing
@testable import MacState

@Suite(.serialized) @MainActor struct ScreenshotOCRDenseDialogueTests {
    private static let fixturePath = "reports/ocr-dense-dialogue-2026-10-29"

    @Test func shortRowsEndParagraphsAndSoftWrapsKeepLanguageSpacing() {
        for (rows,expected) in [
            (["ビタミンB1が含まれ","ているから元気だよ。","次の段落も","独立している。"],
             ["ビタミンB1が含まれているから元気だよ。","次の段落も独立している。"]),
            (["这种换行不会拆","散中文词语。","下一段内容","也独立保留。"],
             ["这种换行不会拆散中文词语。","下一段内容也独立保留。"]),
            (["A sentence continues","on its second row.","A different paragraph","with another wrapped row."],
             ["A sentence continues on its second row.","A different paragraph with another wrapped row."]),
            (["비타민을","먹으면 건강해요.","다음 문장을","계속 읽어요."],
             ["비타민을 먹으면 건강해요.","다음 문장을 계속 읽어요."])
        ] {
            var selection=ScreenshotOCRTextSelection()
            selection.install(rows.enumerated().map { index,text in
                .init(text:text,rect:NSRect(x:0.02,y:0.05+CGFloat(index)*0.08,width:index%2==0 ? 0.9:0.3,height:0.06))
            },region:NSRect(x:0,y:0,width:1,height:1))
            #expect(ScreenshotOCRTranslationSegment.make(from:selection,in:NSRect(x:0,y:0,width:1000,height:400)).map(\.text)==expected)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fixturePath + "/original.png"),
                   "Requires the local OCR dialogue screenshot"))
    func realDialogueKeepsShortLineParagraphBoundariesAndReadingOrder() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: Self.fixturePath)
        let phase=ProcessInfo.processInfo.environment["MACSTATE_DIALOGUE_PHASE"] ?? "after"
        let bitmap=try #require(NSBitmapImageRep(data:Data(contentsOf:folder.appendingPathComponent("original.png"))))
        bitmap.size=NSSize(width:bitmap.pixelsWide,height:bitmap.pixelsHigh)
        let area=NSRect(origin:.zero,size:bitmap.size),sourceImage=try #require(bitmap.cgImage)
        let boxes=try await Task.detached(priority:.userInitiated) {try ScreenshotEditDocument.recognize(sourceImage)}.value
        var selection=ScreenshotOCRTextSelection();selection.install(boxes,region:NSRect(x:0,y:0,width:1,height:1))
        let segments=ScreenshotOCRTranslationSegment.make(from:selection,in:area)
        let translations:[ScreenshotOCRTranslationOverlay]
        if ProcessInfo.processInfo.environment["MACSTATE_REAL_DIALOGUE_TRANSLATION"]=="1" {
            let model=try #require(ScreenshotOCRLocalModels.discover(in:ScreenshotOCRLocalModels.roots())
                .first{$0.format == .mlx && $0.name.contains("HY-MT1.5")})
            let settings=ScreenshotOCRTranslationSettings(localModelPath:model.path,localPython:ScreenshotOCRLocalRuntime.python.path)
            let session=ScreenshotOCRLocalSession();defer{session.shutdown()}
            translations=try await ScreenshotOCRLocalTranslationService(session:session).translate(segments,target:"zh-Hans",settings:settings,source:"ja")
            let values=zip(segments,translations).map{["source":$0.0.text,"translation":$0.1.text]}
            try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys])
                .write(to:folder.appendingPathComponent(phase+"-translation.json"))
        } else {
            let cached=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("after-translation.json"))) as? [[String:String]])
            #expect(cached.map{$0["source"] ?? ""}==segments.map(\.text))
            translations=zip(segments,cached).map {segment,value in
                .init(text:value["translation"] ?? "",sourceRect:segment.rect,sourceLineHeight:segment.lineHeight,
                    sourceLines:segment.sourceLines,sourceLineTexts:segment.sourceLineTexts,sourceText:segment.text)
            }
        }
        let prepared=await Task.detached(priority:.userInitiated) {
            let recognized=segments.flatMap(\.sourceLines)
            let color=ScreenshotOCRTranslationBackground.color(from:bitmap,in:area,within:area,excluding:recognized)
            return translations.map { value in
                var overlay=value.withRestoredBackground(from:bitmap,in:area,excluding:recognized)
                overlay.backgroundColor=color;return overlay
            }
        }.value
        let layout=try #require(ScreenshotOCRTranslationLayout.arrange(prepared,within:area,streamingTarget:"zh-Hans"))
        let evidence:[String:Any]=["ocrRows":selection.boxes.map{["text":$0.text,"rect":NSStringFromRect($0.rect)]},
            "segments":segments.map{["text":$0.text,"rect":NSStringFromRect($0.rect),"sourceRows":$0.sourceLines.map(NSStringFromRect)]},
            "translated":layout.map{["text":$0.text,"rows":$0.lines.map{["text":$0.text,"rect":NSStringFromRect($0.rect),"font":$0.fontSize]}]}]
        try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent(phase+"-layout.json"))
        let content=NSRect(origin:.zero,size:NSSize(width:area.width,height:max(area.height,(layout.flatMap(\.lines).map{$0.rect.maxY}.max() ?? 0)+4)))
        let proof=OCRDocumentProof(frame:content);proof.overlays=layout
        let rendered=try #require(proof.bitmapImageRepForCachingDisplay(in:content));proof.cacheDisplay(in:content,to:rendered)
        try #require(rendered.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(phase+"-translated.png"))
        let comparable=[0,3,4,5,7,8].compactMap{layout[$0].lines.first?.fontSize}
        #expect((comparable.max() ?? 0)<=(comparable.min() ?? 0)*1.15,
            "Same-style dialogue should keep a common readable font when space permits.")
        #expect(selection.boxes.count==17)
        #expect(segments.map{$0.sourceLines.count}==[2,3,2,1,1,2,3,1,2],"Short final rows must end their source paragraph while full wrapped rows remain together.")
        #expect(segments.map(\.text).joined().filter{!$0.isWhitespace}==selection.boxes.map(\.text).joined().filter{!$0.isWhitespace})
        for (original,paragraph) in zip(prepared,layout) {
            #expect(paragraph.lines.map(\.text).joined().filter{!$0.isWhitespace}==paragraph.text.filter{!$0.isWhitespace})
            let row=try #require(original.sourceLines.first)
            #expect(abs((paragraph.lines.first?.rect.minY ?? 0)-row.minY)<=max(4,row.height*0.35),
                "Dense OCR may have a few pixels of padding, but translated paragraphs must not be displaced by an entire row.")
        }
        for (first,second) in zip(layout,layout.dropFirst()) {
            #expect((first.lines.last?.rect.maxY ?? 0)<(second.lines.first?.rect.minY ?? 0))
        }
    }
}
