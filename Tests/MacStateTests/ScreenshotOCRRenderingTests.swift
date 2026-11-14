import AppKit
import CoreText
import Testing
@testable import MacState

private final class OCRRenderingProof: NSView {
    let original: NSBitmapImageRep
    var overlays: [ScreenshotOCRTranslationOverlay]
    override var isFlipped: Bool { true }
    init(original: NSBitmapImageRep, overlays: [ScreenshotOCRTranslationOverlay]) {
        self.original = original; self.overlays = overlays
        super.init(frame: NSRect(origin: .zero, size: original.size))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = original.cgImage else { return }
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for overlay in overlays { for patch in overlay.restoredPatches {
            patch.image.draw(in: patch.rect, from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
        } }
        for overlay in overlays { overlay.draw(in: bounds) }
    }
}

@Suite(.serialized) @MainActor struct ScreenshotOCRRenderingTests {
    nonisolated private static let fixturePath = "reports/ocr-typography-2026-10-28"
    private let folder = URL(fileURLWithPath: "reports/ocr-rendering-2026-10-28")

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    }
    private func write(_ image: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(image.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name))
    }
    private func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    @Test(.enabled(if: ["chinese", "english"].allSatisfy {
        FileManager.default.fileExists(atPath: fixturePath + "/" + $0 + "-original.png")
    }, "Requires local OCR typography screenshots"))
    func suppliedScreenshotsKeepListsBodySizeAndOriginalRows() throws {
        _ = NSApplication.shared
        let proofFolder = URL(fileURLWithPath: Self.fixturePath)
        let examples: [(String, [String])] = [
            ("chinese", [
                "Fixed the issue where the original text reappeared after OCR translation.",
                "Two causes were confirmed: background patching could mistake other English lines for texture samples, and patching an entire rectangular block could affect the removal of multiple lines of text.",
                "It now works as follows:",
                "Remove the original glyphs line by line, restoring each line’s background separately.",
                "Exclude all recognized text from background samples to prevent English from reappearing.",
                "Keep the three separate paragraphs, complete translations, drag selection and copying.",
                "Keep the “Show Original / Show Translation” toggle."
            ]),
            ("english", [
                "在真实项目中工作。让 ChatGPT 读取和编辑文件、运行测试、保持终端打开并使用你的桌面。按照实际到达的工具结果操作。",
                "给它一个团队。将独立任务分给各位工作者，再把他们的结果汇总回来。工作者会保留各自的上下文，让下一个任务可以从上次停下的地方继续。",
                "始终掌控长期任务。在工作进行时发送更正。Goal 跟进未完成的工作；Loop 会在你的任务范围内持续运行。Compact & Resume 会把会话和工作历史带入新的聊天。"
            ])
        ]
        for (name, translations) in examples {
            let data = try Data(contentsOf: proofFolder.appendingPathComponent("\(name)-original.png"))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            bitmap.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            let cgImage = try #require(bitmap.cgImage)
            let area = NSRect(origin: .zero, size: bitmap.size)
            var selection = ScreenshotOCRTextSelection()
            selection.install(try ScreenshotEditDocument.recognize(cgImage), region: NSRect(x: 0, y: 0, width: 1, height: 1))
            let segments = ScreenshotOCRTranslationSegment.make(from: selection, in: area)
            #expect(segments.count == translations.count, "Each bullet must remain its own paragraph.")
            guard segments.count == translations.count else { continue }
            let overlays = zip(segments, translations).map { segment, text in
                ScreenshotOCRTranslationOverlay(text: text, sourceRect: segment.rect,
                    sourceLineHeight: segment.lineHeight, sourceLines: segment.sourceLines, sourceText: segment.text)
                    .withRestoredBackground(from: bitmap, in: area, excluding: segments.flatMap(\.sourceLines))
            }
            let arranged = try #require(ScreenshotOCRTranslationLayout.arrange(overlays, within: area))
            let sizes = arranged.flatMap(\.lines).map(\.fontSize)
            #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) < 0.5, "The source uses one body size.")
            #expect(arranged.flatMap(\.lines).allSatisfy { $0.rect.height <= 34 }, "Translated glyphs must not exceed the source’s ~31px ink height.")
            for (index, paragraph) in arranged.enumerated() {
                #expect(paragraph.lines.map(\.text).joined().filter { !$0.isWhitespace && $0 != "•" } ==
                    translations[index].filter { !$0.isWhitespace })
                #expect(abs(paragraph.lines[0].rect.minY - segments[index].rect.minY) <= 11)
                if name == "english" {
                    #expect(paragraph.lines.count == segments[index].sourceLines.count)
                    for (line, source) in zip(paragraph.lines, segments[index].sourceLines) {
                        #expect(abs(line.rect.minY - source.minY) <= 11)
                    }
                } else if index >= 3 {
                    #expect(paragraph.text.hasPrefix("• "))
                    #expect(paragraph.lines.count == 1)
                }
                for other in arranged.dropFirst(index + 1) {
                    #expect(!paragraph.displayRect(within: area).intersects(other.displayRect(within: area)))
                }
            }
            let proof = OCRRenderingProof(original: bitmap, overlays: arranged)
            let rendered = try #require(proof.bitmapImageRepForCachingDisplay(in: area))
            proof.cacheDisplay(in: area, to: rendered)
            let originalProof = OCRRenderingProof(original: bitmap, overlays: [])
            let originalRendered = try #require(originalProof.bitmapImageRepForCachingDisplay(in: area))
            originalProof.cacheDisplay(in: area, to: originalRendered)
            let scale = CGFloat(rendered.pixelsWide) / area.width
            for patch in arranged.flatMap(\.restoredPatches) {
                let x = Int((patch.rect.minX + 0.5) * scale), y = Int((patch.rect.minY + 0.5) * scale)
                let before = try color(originalRendered, x, y), after = try color(rendered, x, y)
                #expect(max(abs(before.redComponent - after.redComponent), abs(before.greenComponent - after.greenComponent),
                    abs(before.blueComponent - after.blueComponent)) < 0.012, "Monitor ICC profiles must not introduce visible background strips.")
            }
            let png = try #require(rendered.representation(using: .png, properties: [:]))
            try png.write(to: proofFolder.appendingPathComponent("\(name)-translated.png"))
        }
    }

    @Test func streamedPrefixesKeepGlyphPositionsAndUnicodeClusters() throws {
        let area=NSRect(x:0,y:0,width:280,height:900)
        let rows=[NSRect(x:20,y:20,width:220,height:22),NSRect(x:20,y:53,width:190,height:22),
                  NSRect(x:20,y:86,width:70,height:22)]
        let text="iii WWW office ffi e\u{301} 中文逐字输出 👩🏽‍💻 🏳️‍🌈 🧑‍🤝‍🧑 继续追加文字，保持已经显示的文字位置，整行填满以后再自然换行。"
        let overlay=ScreenshotOCRTranslationOverlay(text:text,sourceRect:rows[0].union(rows[2]),
            sourceLineHeight:22,sourceLines:rows,sourceText:"Three source rows")
        let planned=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"zh-Hans")?.first)
        var previous:[NSPoint]=[],previousSize:CGFloat?
        for count in 1...text.count {
            let prefix=String(text.prefix(count))
            let result=planned.revealingPrefix(count)
            #expect(!result.isTruncated)
            #expect(result.lines.map(\.text).joined().filter{!$0.isWhitespace}==prefix.filter{!$0.isWhitespace})
            var positions:[NSPoint]=[]
            for line in result.lines {
                let shaped=line.shaped(),baseline=try #require(line.baselineOffset)
                var offset=0
                for character in line.text {
                    if !character.isWhitespace {
                        positions.append(NSPoint(x:line.rect.minX+CTLineGetOffsetForStringIndex(shaped,offset,nil),
                            y:line.rect.minY+baseline))
                    }
                    offset+=String(character).utf16.count
                }
                if let previousSize {#expect(abs(previousSize-line.fontSize)<0.001)}
                previousSize=line.fontSize
            }
            #expect(Array(positions.prefix(previous.count))==previous,"Earlier glyph origins must not move as the prefix grows.")
            previous=positions
        }
        let explicit=ScreenshotOCRTranslationOverlay(text:"第一行\n第二行",sourceRect:rows[0],sourceLineHeight:22)
        let layout=try #require(ScreenshotOCRTranslationLayout.arrange([explicit],within:area,streamingTarget:"zh-Hans")?.first)
        #expect(layout.lines.map(\.text)==["第一行","第二行"])
    }

    @Test func streamedListPrefixesNeverDuplicateOrMoveTheMarker() throws {
        let area=NSRect(x:0,y:0,width:500,height:160),source=NSRect(x:20,y:20,width:450,height:24)
        for (original,text) in [("• Original","• 你好"),("1. Original","1. Hello"),("• Original","- 你好")] {
            let overlay=ScreenshotOCRTranslationOverlay(text:text,sourceRect:source,sourceLineHeight:24,sourceText:original)
            let planned=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"zh-Hans")?.first)
            var origin:NSPoint?
            for count in 1...planned.text.count {
                let result=planned.revealingPrefix(count)
                let first=try #require(result.lines.first)
                #expect(!first.text.contains("• •") && !first.text.contains("1. 1"))
                #expect(!first.text.contains("• -"))
                if let origin {#expect(first.rect.origin==origin)}
                origin=first.rect.origin
            }
        }
    }

    @Test func incrementalChunksNeverReflowPreviouslyDisplayedCharacters() throws {
        let area=NSRect(x:0,y:0,width:200,height:400),row=NSRect(x:20,y:20,width:150,height:25)
        let text="The extraordinary translation grows through several lines, without moving earlier letters."
        var previous:[ScreenshotOCRTranslationLine]=[]
        for count in 1...text.count {
            let overlay=ScreenshotOCRTranslationOverlay(text:String(text.prefix(count)),sourceRect:row,sourceLineHeight:22)
            let current=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"en")?.first).lines
            for (old,new) in zip(previous,current) {
                #expect(new.text.hasPrefix(old.text))
                #expect(new.rect.origin==old.rect.origin && new.fontSize==old.fontSize)
            }
            previous=current
        }
        #expect(previous.count>1)
    }

    @Test func partialListMarkerIsNotDuplicated() throws {
        let area=NSRect(x:0,y:0,width:400,height:100),row=NSRect(x:20,y:20,width:350,height:25)
        for (prefix,expected) in [("•","•"),("• ","•"),("• 标","• 标"),("• 标题","• 标题")] {
            let overlay=ScreenshotOCRTranslationOverlay(text:prefix,sourceRect:row,sourceLineHeight:22,sourceText:"• Original")
            let result=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"zh-Hans")?.first)
            #expect(result.text==expected)
        }
    }

    @Test func replacementCoversOnlyVisibleTextUntilParagraphFinishes() throws {
        let source=NSRect(x:20,y:20,width:350,height:25),next=NSRect(x:20,y:43,width:350,height:25)
        var overlay=ScreenshotOCRTranslationOverlay(text:"译",sourceRect:source,sourceLineHeight:22,sourceLines:[source])
        overlay=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:NSRect(x:0,y:0,width:400,height:100),streamingTarget:"zh-Hans")?.first)
        let partial=overlay.replacementRects(sourceRows:[source,next])
        #expect(partial.count==1 && partial[0].maxX<source.maxX)
        overlay.sourceFullyReplaced=true
        let complete=overlay.replacementRects(sourceRows:[source,next])
        #expect(complete.contains{$0.maxX>=source.maxX})
        #expect(complete.allSatisfy{$0.maxY<next.midY},"Covering one source paragraph must not erase the next OCR row.")
    }

    @Test func ocrTypographyReconstructsParagraphFontTraits() throws {
        let text="Hello original typography",area=NSRect(x:0,y:0,width:600,height:100)
        for expected in [ScreenshotOCRFontStyle(),.init(bold:true),.init(italic:true),.init(bold:true,italic:true)] {
            let context=try #require(CGContext(data:nil,width:600,height:100,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor);context.fill(area)
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[
                .font:expected.font(36),.foregroundColor:NSColor.black]))
            context.textPosition=CGPoint(x:20,y:35);CTLineDraw(line,context)
            let image=NSBitmapImageRep(cgImage:try #require(context.makeImage()))
            let row=NSRect(x:15,y:25,width:500,height:50)
            let overlay=ScreenshotOCRTranslationOverlay(text:"Translated text",sourceRect:row,sourceLineHeight:36,
                sourceLines:[row],sourceLineTexts:[text]).withRestoredBackground(from:image,in:area,excluding:[row])
            let detected=try #require(overlay.restoredPatches.first?.style)
            #expect(detected==expected,"Font traits should be estimated from original pixels: \(expected) → \(detected).")
            let result=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"en")?.first)
            #expect(result.lines.first?.style==expected)
            #expect(result.revealingPrefix(4).lines.first?.style==expected)
        }
    }

    @Test func adaptiveOverflowPreservesCompleteTextAtAReadableMinimum() throws {
        let source=NSRect(x:10,y:10,width:90,height:22),area=NSRect(x:0,y:0,width:120,height:55)
        let prefix=ScreenshotOCRTranslationOverlay(text:"先显示",sourceRect:source,sourceLineHeight:22)
        let first=try #require(ScreenshotOCRTranslationLayout.arrange([prefix],within:area,streamingTarget:"zh-Hans")?.first)
        var long=prefix;long.text=String(repeating:"完整译文不能被静默丢弃。",count:8)
        let result=try #require(ScreenshotOCRTranslationLayout.arrange([long],within:area,streamingTarget:"zh-Hans")?.first)
        #expect(result.text==long.text && !result.isTruncated)
        #expect((result.lines.last?.rect.maxY ?? 0)>area.maxY)
        #expect(result.lines.map(\.text).joined()==long.text)
        #expect(result.lines.first?.fontSize==first.lines.first?.fontSize)
        #expect((result.lines.first?.fontSize ?? 0)>=10)
        #expect(result.lines.first?.rect.origin==first.lines.first?.rect.origin)
    }

    @Test func adaptiveShortLabelsCannotInflatePunctuationIntoOversizedText() throws {
        let area=NSRect(x:0,y:0,width:240,height:110),source=NSRect(x:10,y:10,width:200,height:30)
        for text in [".","i","👩🏽‍💻"] {
            let overlay=ScreenshotOCRTranslationOverlay(text:text,sourceRect:source,sourceLineHeight:24)
            let result=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"en")?.first)
            #expect(result.lines.allSatisfy{area.contains($0.rect) && $0.fontSize<=24*1.6})
        }
    }

    @Test func punctuationArrivingAfterAFullRowCannotMovePublishedCJK() throws {
        let area=NSRect(x:0,y:0,width:120,height:55),source=NSRect(x:10,y:10,width:90,height:22)
        let text="一二三四五，六七八九十。接着继续显示（标点也不能让前面的字跳到下一行）。"
        let overlay=ScreenshotOCRTranslationOverlay(text:text,sourceRect:source,sourceLineHeight:22)
        let planned=try #require(ScreenshotOCRTranslationLayout.arrange([overlay],within:area,streamingTarget:"zh-Hans")?.first)
        var previous:[ScreenshotOCRTranslationLine]=[]
        for count in 1...text.count {
            let current=planned.revealingPrefix(count)
            for (old,new) in zip(previous,current.lines) {
                #expect(new.text.hasPrefix(old.text),"Published punctuation must stay on its planned row.")
                #expect(new.rect.origin==old.rect.origin && new.fontSize==old.fontSize)
            }
            previous=current.lines
        }
        #expect(previous.map(\.text).joined()==text)
    }

    @Test func solidBackgroundSamplingExcludesTextAndMakesTransparencyOpaque() throws {
        let original=try bitmap(width:64,height:32)
        let background=NSColor(deviceRed:0.12,green:0.16,blue:0.20,alpha:1)
        let foreground=NSColor(deviceRed:1,green:1,blue:1,alpha:1)
        for y in 0..<32 {for x in 0..<64 {
            original.setColor(x<50 ? foreground:background,atX:x,y:y)
        }}
        let source=NSRect(x:37.25,y:28.5,width:32,height:16)
        let text=NSRect(x:source.minX,y:source.minY,width:25,height:16)
        let result=ScreenshotOCRTranslationBackground.color(from:original,in:source,within:source,excluding:[text])
        #expect(abs(result.redComponent-0.12)<0.01)
        #expect(abs(result.greenComponent-0.16)<0.01)
        #expect(abs(result.blueComponent-0.20)<0.01)
        #expect(result.alphaComponent==1)
        let lightText=try #require(ScreenshotOCRTranslationBackground.textColor(on:result).usingColorSpace(.deviceRGB))
        #expect(lightText.redComponent>0.9)
        let transparent=NSColor(deviceRed:0,green:0,blue:0,alpha:0)
        for y in 0..<32 {for x in 0..<64 {original.setColor(transparent,atX:x,y:y)}}
        let opaque=ScreenshotOCRTranslationBackground.color(from:original,in:source,within:source,excluding:[source])
        #expect(opaque.alphaComponent==1 && opaque.redComponent>0.99 && opaque.greenComponent>0.99 && opaque.blueComponent>0.99)
        let darkText=try #require(ScreenshotOCRTranslationBackground.textColor(on:opaque).usingColorSpace(.deviceRGB))
        #expect(darkText.redComponent<0.2)
    }

    @Test func backgroundDoesNotCopyUnrelatedColoredDecoration() throws {
        let original = try bitmap(width: 440, height: 240)
        let background = NSColor(deviceRed: 0.09, green: 0.12, blue: 0.16, alpha: 1)
        let decoration = NSColor(deviceRed: 0.95, green: 0.14, blue: 0.50, alpha: 1)
        for y in 0..<240 { for x in 0..<440 {
            original.setColor((48..<62).contains(y) ? decoration : background, atX: x, y: y)
        } }
        for y in 78..<101 { for x in 46..<332 where (x - 46) % 18 < 5 {
            original.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: x, y: y)
        } }
        let source = NSRect(x: 0, y: 0, width: 440, height: 240)
        let line = NSRect(x: 32, y: 76, width: 320, height: 28)
        let overlay = ScreenshotOCRTranslationOverlay(text: "译文", sourceRect: line,
            sourceLineHeight: 28, sourceLines: [line])
            .withRestoredBackground(from: original, in: source, excluding: [line])
        let patch = try #require(overlay.restoredPatches.first)
        let restored = try #require(patch.image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        var maximumError: CGFloat = 0
        for y in 0..<restored.pixelsHigh { for x in 0..<restored.pixelsWide {
            let pixel = try color(restored, x, y)
            maximumError = max(maximumError, abs(pixel.redComponent - 0.09),
                abs(pixel.greenComponent - 0.12), abs(pixel.blueComponent - 0.16))
        } }
        try write(original, name: "decorated-source.png")
        try write(restored, name: "decorated-restored.png")
        #expect(maximumError < 0.025, "A pink band outside the OCR line must not be cloned into its background.")
    }

    @Test func otherTargetScriptsKeepVisualSizeAndSourcePitch() throws {
        let area = NSRect(x: 0, y: 0, width: 1200, height: 290)
        let targets = [
            "実際のプロジェクトで作業します。ファイルの読み取りと編集、テストの実行、ターミナルの維持に対応し、届いたツールの結果に従います。",
            "실제 프로젝트에서 작업합니다. 파일을 읽고 편집하고 테스트를 실행하며 터미널을 열어 두세요. 도구에서 실제로 도착한 결과에 따라 진행합니다.",
            "Travaillez sur le projet réel. Lisez et modifiez les fichiers, exécutez les tests et gardez les terminaux ouverts. Suivez les résultats des outils à leur arrivée.",
            "Arbeiten Sie am tatsächlichen Projekt. Lesen und bearbeiten Sie Dateien, führen Sie Tests aus und halten Sie Terminals offen. Folgen Sie den tatsächlichen Werkzeugergebnissen.",
            "Trabaja en el proyecto real. Lee y edita archivos, ejecuta pruebas y mantén las terminales abiertas. Sigue los resultados reales de las herramientas cuando lleguen."
        ]
        for text in targets {
            let overlays = [CGFloat(12), CGFloat(152)].map { y in
                ScreenshotOCRTranslationOverlay(text: text,
                    sourceRect: NSRect(x: 8, y: y, width: 1150, height: 79), sourceLineHeight: 31,
                    sourceLines: [NSRect(x: 8, y: y, width: 1150, height: 31),
                                  NSRect(x: 8, y: y + 48, width: 850, height: 31)])
            }
            let result = try #require(ScreenshotOCRTranslationLayout.arrange(overlays, within: area))
            #expect(abs(result[0].lines[0].fontSize - result[1].lines[0].fontSize) < 0.01)
            for paragraph in result {
                // Longer scripts may need a third row at the original size.
                #expect((2...3).contains(paragraph.lines.count))
                #expect(paragraph.lines.allSatisfy { $0.rect.height <= 31.1 })
                #expect(paragraph.lines.allSatisfy { area.contains($0.rect) })
                #expect(paragraph.lines.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
                #expect(abs(paragraph.lines[1].rect.minY - paragraph.lines[0].rect.minY - 48) < 0.01)
            }
            #expect(result[0].lines.last!.rect.maxY < result[1].lines[0].rect.minY)
        }
    }

    @Test func numberedAndRoundListItemsKeepHangingIndentsWhenWrapped() throws {
        let area = NSRect(x: 0, y: 0, width: 420, height: 300)
        var selection = ScreenshotOCRTextSelection()
        let rows: [(String, CGFloat, CGFloat)] = [
            ("1. First item", 20, 20), ("continued on this line", 45, 42),
            ("2. Second item", 125, 20), ("。第三项", 195, 20)
        ]
        selection.install(rows.map { text, y, x in
            .init(text: text, rect: NSRect(x: x / 420, y: y / 300, width: 360 / 420, height: 22 / 300))
        }, region: NSRect(x: 0, y: 0, width: 1, height: 1))
        let segments = ScreenshotOCRTranslationSegment.make(from: selection, in: area)
        #expect(segments.map(\.text) == ["1. First item continued on this line", "2. Second item", "• 第三项"])
        let translations = ["Keep this longer translated item together, wrapping its body below the text instead of below the number.",
                            "2. Retain the second item.", "Keep the round bullet."]
        let overlays = zip(segments, translations).map { segment, text in
            ScreenshotOCRTranslationOverlay(text: text, sourceRect: segment.rect,
                sourceLineHeight: segment.lineHeight, sourceLines: segment.sourceLines, sourceText: segment.text)
        }
        let result = try #require(ScreenshotOCRTranslationLayout.arrange(overlays, within: area))
        #expect(result.map(\.text) == ["1. " + translations[0], translations[1], "• " + translations[2]])
        let first = try #require(result[0].lines.first)
        #expect(result[0].lines.count > 1)
        for continuation in result[0].lines.dropFirst() {
            #expect(abs(continuation.rect.minX - first.rect.minX - first.prefixIndent) < 0.01)
        }
        for (index, paragraph) in result.enumerated() {
            #expect(paragraph.lines.map(\.text).joined().filter { !$0.isWhitespace } ==
                result[index].text.filter { !$0.isWhitespace })
        }
        let wideMarker = ScreenshotOCRTranslationOverlay(text: "译文正文不能与全角编号重叠，换行后也要与正文左侧对齐。",
            sourceRect: NSRect(x: 20, y: 20, width: 360, height: 22), sourceLineHeight: 22, sourceText: "（1） Original item")
        let wide = try #require(ScreenshotOCRTranslationLayout.arrange([wideMarker], within: area))
        let line = try #require(wide[0].lines.first)
        let markerWidth = ("（1） " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: line.fontSize)]).width
        #expect(line.prefixIndent >= markerWidth)
    }

    @Test func backgroundRepairPreservesGradientAndThinSeparatorOutsideGlyphs() throws {
        let original = try bitmap(width: 360, height: 160)
        func background(_ x: Int, _ y: Int) -> NSColor {
            x == 179 || x == 180 ? NSColor(deviceRed: 0.10, green: 0.55, blue: 0.75, alpha: 1) :
                NSColor(deviceRed: 0.10 + CGFloat(x) * 0.0004,
                        green: 0.12 + CGFloat(y) * 0.0006,
                        blue: 0.18 + CGFloat(x + y) * 0.0003, alpha: 1)
        }
        for y in 0..<160 { for x in 0..<360 { original.setColor(background(x, y), atX: x, y: y) } }
        let strokes = stride(from: 45, to: 315, by: 21).map { NSRect(x: $0, y: 64, width: 5, height: 20) }
        for stroke in strokes {
            for y in Int(stroke.minY)..<Int(stroke.maxY) { for x in Int(stroke.minX)..<Int(stroke.maxX) {
                original.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: x, y: y)
            } }
        }
        let source = NSRect(x: 0, y: 0, width: 360, height: 160)
        let line = NSRect(x: 32, y: 62, width: 290, height: 24)
        let overlay = ScreenshotOCRTranslationOverlay(text: "渐变与分隔线", sourceRect: line,
            sourceLineHeight: 24, sourceLines: [line])
            .withRestoredBackground(from: original, in: source, excluding: [line])
        let patch = try #require(overlay.restoredPatches.first)
        let restored = try #require(patch.image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        var unchangedError: CGFloat = 0, glyphError: CGFloat = 0
        let originX = Int(patch.rect.minX), originY = Int(patch.rect.minY)
        for y in 0..<restored.pixelsHigh { for x in 0..<restored.pixelsWide {
            let px = originX + x, py = originY + y
            let point = NSPoint(x: px, y: py)
            let expected = background(px, py)
            let pixel = try color(restored, x, y)
            let error = max(abs(pixel.redComponent - expected.redComponent),
                abs(pixel.greenComponent - expected.greenComponent), abs(pixel.blueComponent - expected.blueComponent))
            if strokes.contains(where: { $0.contains(point) }) { glyphError = max(glyphError, error) }
            else if !strokes.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                unchangedError = max(unchangedError, error)
            }
        } }
        #expect(unchangedError < 0.012, "Existing background and separators outside the glyphs must remain unchanged.")
        #expect(glyphError < 0.08, "Repair should follow the local background instead of introducing new colors.")
        try write(restored, name: "gradient-restored.png")
    }

    @Test func paragraphOriginsColumnsAndSharedBodySizeArePreserved() throws {
        let area = NSRect(x: 0, y: 0, width: 450, height: 330)
        let overlays: [ScreenshotOCRTranslationOverlay] = [
            .init(text: String(repeating: "第一段较长的译文需要在原列内缩小字号。", count: 4),
                  sourceRect: NSRect(x: 20, y: 20, width: 150, height: 60), sourceLineHeight: 24),
            .init(text: "右侧独立段落。", sourceRect: NSRect(x: 260, y: 20, width: 160, height: 60), sourceLineHeight: 24),
            .init(text: "第二段保持原位。", sourceRect: NSRect(x: 20, y: 130, width: 150, height: 48), sourceLineHeight: 24),
            .init(text: "原来的大标题", sourceRect: NSRect(x: 20, y: 245, width: 400, height: 48), sourceLineHeight: 48)
        ]
        let arranged = try #require(ScreenshotOCRTranslationLayout.arrange(overlays, within: area))
        #expect(arranged.count == overlays.count)
        for original in overlays {
            let paragraph = try #require(arranged.first { $0.text == original.text })
            let first = try #require(paragraph.lines.first)
            #expect(abs(first.rect.minX - original.sourceRect.minX) < 0.5)
            #expect(abs(first.rect.minY - original.sourceRect.minY) < 0.5)
            #expect(paragraph.lines.allSatisfy { $0.rect.maxX <= original.sourceRect.maxX + 0.5 })
            #expect(paragraph.lines.map(\.text).joined() == original.text)
        }
        let long = try #require(arranged.first { $0.text == overlays[0].text }?.lines.first)
        let short = try #require(arranged.first { $0.text == overlays[2].text }?.lines.first)
        let heading = try #require(arranged.first { $0.text == overlays[3].text }?.lines.first)
        #expect(abs(long.fontSize - short.fontSize) < 0.01)
        #expect(heading.fontSize > short.fontSize * 1.6)
        for (index, first) in arranged.enumerated() {
            for second in arranged.dropFirst(index + 1) {
                #expect(!first.displayRect(within: area).intersects(second.displayRect(within: area)))
            }
        }
    }

    @Test func columnParagraphsStaySeparateWhenOCRRowsAreInterleaved() {
        let source = NSRect(x: 0, y: 0, width: 600, height: 300)
        var selection = ScreenshotOCRTextSelection()
        selection.install([
            .init(text: "Left first", rect: NSRect(x: 0.05, y: 0.1, width: 0.35, height: 0.06)),
            .init(text: "Right first", rect: NSRect(x: 0.55, y: 0.1, width: 0.35, height: 0.06)),
            .init(text: "Left second", rect: NSRect(x: 0.05, y: 0.19, width: 0.35, height: 0.06)),
            .init(text: "Right second", rect: NSRect(x: 0.55, y: 0.19, width: 0.35, height: 0.06))
        ], region: NSRect(x: 0, y: 0, width: 1, height: 1))
        let paragraphs = ScreenshotOCRTranslationSegment.make(from: selection, in: source)
        #expect(paragraphs.map(\.text) == ["Left first Left second", "Right first Right second"])
    }

    @Test func selectingAcrossParagraphsKeepsTheirTranslationMapping() throws {
        let source = NSRect(x: 0, y: 0, width: 600, height: 300)
        var selection = ScreenshotOCRTextSelection()
        selection.install([
            .init(text: "First paragraph", rect: NSRect(x: 0.05, y: 0.1, width: 0.7, height: 0.06)),
            .init(text: "Second paragraph", rect: NSRect(x: 0.05, y: 0.5, width: 0.7, height: 0.06))
        ], region: NSRect(x: 0, y: 0, width: 1, height: 1))
        let first = selection.frame(for: 0, in: source), last = selection.frame(for: 1, in: source)
        let began = selection.begin(at: NSPoint(x: first.minX, y: first.midY), in: source)
        #expect(began)
        selection.extend(to: NSPoint(x: last.maxX, y: last.midY), in: source)
        let paragraphs = ScreenshotOCRTranslationSegment.make(from: selection, in: source)
        #expect(paragraphs.count == 2)
        #expect(paragraphs.map(\.text) == ["First paragraph", "Second paragraph"])
        #expect(paragraphs.map(\.rect) == [first, last])
    }

    @Test func adaptiveFontUsesSourceGlyphMetricsAndDoesNotDropUnicode() throws {
        let source = "Original typography"
        let sample = CTLineCreateWithAttributedString(NSAttributedString(string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 32)]))
        let ink = CTLineGetBoundsWithOptions(sample, .useGlyphPathBounds)
        let short = ScreenshotOCRTranslationOverlay(text: "原位译文", sourceRect:
            NSRect(x: 10, y: 10, width: 300, height: ink.height),
            sourceLineHeight: ink.height, sourceText: source)
        let area = NSRect(x: 0, y: 0, width: 500, height: 200)
        let result = try #require(ScreenshotOCRTranslationLayout.arrange([short], within: area))
        let first = try #require(result.first?.lines.first)
        #expect(abs(first.fontSize - 32) < 1.5)
        let text = "Unicode 👩🏽‍💻 e\u{301} 中文 emoji 🧑‍🤝‍🧑 office ffi 都不能丢失。"
        let item = ScreenshotOCRTranslationOverlay(text: text,
            sourceRect: NSRect(x: 10, y: 10, width: 130, height: 30), sourceLineHeight: 24)
        let unicode = try #require(ScreenshotOCRTranslationLayout.arrange([item], within: area))
        #expect(unicode[0].lines.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        #expect(unicode[0].lines.allSatisfy { $0.rect.maxX <= 140.01 })
    }

    @Test func retinaTextureAndScreenshotEdgeRemainStable() throws {
        let original = try bitmap(width: 480, height: 180)
        let dark = NSColor(deviceRed: 0.10, green: 0.12, blue: 0.18, alpha: 1)
        let light = NSColor(deviceRed: 0.18, green: 0.23, blue: 0.30, alpha: 1)
        for y in 0..<180 { for x in 0..<480 {
            original.setColor((x / 8 + y / 8) % 2 == 0 ? dark : light, atX: x, y: y)
        } }
        let source = NSRect(x: 47.25, y: 31.5, width: 240, height: 90)
        let line = NSRect(x: 77.75, y: 56.25, width: 180, height: 18)
        let restored = ScreenshotOCRTranslationOverlay(text: "", sourceRect: line, sourceLines: [line])
            .withRestoredBackground(from: original, in: source, excluding: [line])
        let patch = try #require(restored.restoredPatches.first)
        let bitmap = try #require(patch.image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let x0 = Int(round((patch.rect.minX - source.minX) * 2))
        let y0 = Int(round((patch.rect.minY - source.minY) * 2))
        var difference: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            let a = try color(bitmap, x, y), b = try color(original, x0 + x, y0 + y)
            difference = max(difference, abs(a.redComponent - b.redComponent),
                abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        } }
        #expect(difference < 0.005, "A text-free texture must remain intact at Retina scale and fractional origins.")

        let edge = try self.bitmap(width: 140, height: 70)
        for y in 0..<70 { for x in 0..<140 { edge.setColor(dark, atX: x, y: y) } }
        for y in 0..<19 { for x in 0..<110 where x % 13 < 4 {
            edge.setColor(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), atX: x, y: y)
        } }
        let box = NSRect(x: 0, y: 0, width: 110, height: 19)
        let repaired = ScreenshotOCRTranslationOverlay(text: "边缘", sourceRect: box, sourceLines: [box])
            .withRestoredBackground(from: edge, in: NSRect(x: 0, y: 0, width: 140, height: 70), excluding: [box])
        let output = try #require(repaired.restoredBackground?.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(try color(output, 0, 0).redComponent < 0.15)
    }

    @Test func nativePagePreviewKeepsParagraphsAtTheirOriginalPositions() throws {
        _ = NSApplication.shared
        let background = try bitmap(width: 1280, height: 460)
        for y in 0..<460 { for x in 0..<1280 {
            let color: NSColor
            if (20..<30).contains(y) { color = NSColor(deviceRed: 0.82, green: 0.14, blue: 0.42, alpha: 1) }
            else if x == 628 || x == 629 { color = NSColor(deviceRed: 0.24, green: 0.48, blue: 0.66, alpha: 1) }
            else { color = NSColor(deviceRed: 0.07 + CGFloat(y) * 0.00008,
                                   green: 0.09 + CGFloat(x) * 0.00002, blue: 0.14, alpha: 1) }
            background.setColor(color, atX: x, y: y)
        } }
        let rows: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("Work on the real project.", 32, 40, 58),
            ("A separate column.", 28, 680, 58),
            ("Let ChatGPT read and edit files, run tests,", 24, 40, 130),
            ("No copied color bands behind translations.", 22, 680, 130),
            ("Keep the original background and separators.", 22, 680, 164),
            ("and follow the actual tool results.", 24, 40, 166),
            ("Keep paragraphs in place.", 24, 40, 270),
            ("Resize only the text that needs more room.", 24, 40, 306)
        ]
        let canvas = OCRRenderingProof(original: background, overlays: [])
        let storage = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: storage)
        let context = try #require(NSGraphicsContext(bitmapImageRep: storage))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        var boxes: [ScreenshotOCRBox] = []
        for (text, size, x, y) in rows {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(deviceRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
            ]))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.cgContext.textMatrix = .identity
            context.cgContext.textPosition = CGPoint(x: x - ink.minX, y: 460 - y - ink.maxY)
            CTLineDraw(line, context.cgContext)
            boxes.append(.init(text: text, rect: NSRect(x: x / 1280, y: y / 460,
                width: ink.width / 1280, height: ink.height / 460)))
        }
        NSGraphicsContext.restoreGraphicsState()
        try write(storage, name: "page-original.png")
        var selection = ScreenshotOCRTextSelection()
        selection.install(boxes, region: NSRect(x: 0, y: 0, width: 1, height: 1))
        let segments = ScreenshotOCRTranslationSegment.make(from: selection, in: canvas.bounds)
        #expect(segments.count == 5)
        let overlays = segments.map { segment -> ScreenshotOCRTranslationOverlay in
            let text: String
            if segment.text.hasPrefix("Work") { text = "在真实项目中工作。" }
            else if segment.text.hasPrefix("A separate") { text = "独立的文字列" }
            else if segment.text.hasPrefix("Let") {
                text = "让 ChatGPT 读取和编辑文件、运行测试，并跟随实际工具结果。较长的译文会在原有列宽内自动换行和调整字号，保持段落位置，不把下一段往下挤。"
            } else if segment.text.hasPrefix("No copied") {
                text = "译文背景不再复制其他区域的色条，保留原图的渐变和分隔线。右侧内容始终保持在这一列。"
            } else { text = "让段落保持原位，仅对需要更多空间的译文自适应字号。" }
            return .init(text: text, sourceRect: segment.rect, sourceLineHeight: segment.lineHeight,
                         sourceLines: segment.sourceLines, sourceText: segment.text)
        }
        let layout = try #require(ScreenshotOCRTranslationLayout.arrange(overlays, within: canvas.bounds))
        canvas.overlays = layout.map { $0.withRestoredBackground(from: storage, in: canvas.bounds,
            excluding: segments.flatMap(\.sourceLines)) }
        for paragraph in canvas.overlays {
            #expect(abs(paragraph.lines[0].rect.minY - paragraph.sourceRect.minY) < 0.01)
            var remainingInk = 0
            for patch in paragraph.restoredPatches {
                let repaired = try #require(patch.image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
                for y in 0..<repaired.pixelsHigh { for x in 0..<repaired.pixelsWide {
                    let pixel = try color(repaired, x, y)
                    if min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.4 { remainingInk += 1 }
                } }
            }
            #expect(remainingInk == 0, "Original English glyphs must be cleared before drawing the translation.")
        }
        let proof = OCRRenderingProof(original: storage, overlays: canvas.overlays)
        #expect(proof.bounds.size == canvas.bounds.size)
        let translated = try #require(proof.bitmapImageRepForCachingDisplay(in: proof.bounds))
        proof.cacheDisplay(in: proof.bounds, to: translated)
        try write(translated, name: "page-translated.png")
    }

    @Test func repairingBlackGlyphsKeepsTransparentBackgroundTransparent() throws {
        let original = try bitmap(width: 150, height: 70)
        let transparent = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        for y in 0..<70 { for x in 0..<150 { original.setColor(transparent, atX: x, y: y) } }
        for y in 22..<39 { for x in 22..<122 where x % 13 < 5 {
            original.setColor(black, atX: x, y: y)
        } }
        let line = NSRect(x: 20, y: 20, width: 105, height: 21)
        let result = ScreenshotOCRTranslationOverlay(text: "透明", sourceRect: line, sourceLines: [line])
            .withRestoredBackground(from: original, in: NSRect(x: 0, y: 0, width: 150, height: 70), excluding: [line])
        let patch = try #require(result.restoredPatches.first)
        let image = try #require(patch.image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        var alpha: CGFloat = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            alpha = max(alpha, try color(image, x, y).alphaComponent)
        } }
        #expect(alpha < 0.01)
    }
}
