import AppKit
import CoreText
import NaturalLanguage
import Translation

enum ScreenshotOCRTranslationLanguage {
    static let supported: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("en", "英语"), ("ja", "日语"),
        ("ko", "韩语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"),
        ("zh-Hant", "繁体中文"), ("pt", "葡萄牙语"), ("ru", "俄语"),
        ("it", "意大利语"), ("ar", "阿拉伯语"), ("hi", "印地语"),
        ("bn", "孟加拉语"), ("ur", "乌尔都语"), ("id", "印度尼西亚语"),
        ("ms", "马来语"), ("vi", "越南语"), ("th", "泰语"), ("tr", "土耳其语"),
        ("fa", "波斯语"), ("he", "希伯来语"), ("pl", "波兰语"), ("nl", "荷兰语"),
        ("uk", "乌克兰语"), ("sv", "瑞典语"), ("da", "丹麦语"), ("fi", "芬兰语"),
        ("no", "挪威语"), ("el", "希腊语"), ("cs", "捷克语"), ("ro", "罗马尼亚语"),
        ("hu", "匈牙利语"), ("sw", "斯瓦希里语"), ("ta", "泰米尔语"),
        ("te", "泰卢固语"), ("fil", "菲律宾语")
    ]

    static func source(for text: String) -> String {
        let recognizer=NLLanguageRecognizer()
        recognizer.processString(text)
        let confidence=recognizer.languageHypotheses(withMaximum:1).values.first ?? 0
        // Very short ASCII labels often produce a low-confidence guess.
        let code=confidence<0.3 && text.unicodeScalars.allSatisfy(\.isASCII) ? "en":
            recognizer.dominantLanguage?.rawValue ?? "en"
        if code.hasPrefix("zh") {return code.contains("Hant") ? "zh-Hant":"zh-Hans"}
        return ["nb":"no","nn":"no","tl":"fil"][code] ?? code
    }

    static func defaultTarget(for text: String) -> String {
        defaultTarget(source:source(for:text))
    }

    static func defaultTarget(source:String)->String {source.hasPrefix("zh") ? "en":"zh-Hans"}
    static func name(_ code:String)->String {
        supported.first{$0.code==code}?.name ?? Locale(identifier:"zh-Hans").localizedString(forIdentifier:code) ?? code
    }
}

/// The OCR's source rectangles remain immutable so highlighting and copying
/// still use the recognized original text, even while translations are visible.
struct ScreenshotOCRTranslationSegment {
    let text: String
    let rect: NSRect
    let lineHeight: CGFloat
    var sourceLines:[NSRect]=[]
    var sourceLineTexts:[String]=[]

    static func listItem(_ text:String)->(prefix:String,body:String)? {
        // Vision sometimes reads a small round bullet as Chinese punctuation.
        guard let range=text.range(of:"^(?:[•●◦▪‣⁃·。・]|[-*]\\s+|(?:\\d{1,3}|[a-zA-Z])[.)、]\\s+|[（(]\\d{1,3}[）)]\\s*)\\s*",
                                   options:.regularExpression) else{return nil}
        let marker=String(text[range]).trimmingCharacters(in:.whitespacesAndNewlines)
        let body=String(text[range.upperBound...])
        guard !body.isEmpty else{return nil}
        let prefix="•●◦▪‣⁃·。・".contains(marker) ? "•":marker
        return (prefix,body)
    }

    static func make(from selection: ScreenshotOCRTextSelection,in source:NSRect)->[Self] {
        var fragments:[(text:String,frame:NSRect)]=[]
        if selection.hasSelection,let anchor=selection.anchor,let focus=selection.focus {
            let start=min(anchor,focus),end=max(anchor,focus)
            var frames=selection.selectedRects(in:source).makeIterator()
            for index in start.line...end.line {
                let chars=Array(selection.boxes[index].text)
                let lo=index == start.line ? start.offset:0
                let hi=index == end.line ? end.offset:chars.count
                guard lo<hi,let frame=frames.next() else{continue}
                fragments.append((String(chars[lo..<hi]),frame))
            }
        } else {
            fragments=selection.boxes.indices.map {
                (selection.boxes[$0].text,selection.frame(for:$0,in:source))
            }
        }
        // Vision often returns multiple recognized lines for one paragraph.
        // Translate them together so a sentence cannot be cut off at a line
        // boundary. Paragraph gaps are larger than their normal line spacing.
        let steps=zip(fragments,fragments.dropFirst()).compactMap { first,second -> CGFloat? in
            let distance=second.frame.midY-first.frame.midY
            return distance>max(first.frame.height,second.frame.height)*0.5 ? distance:nil
        }.sorted()
        let typicalPitch=steps.isEmpty ? CGFloat.greatestFiniteMagnitude:steps[steps.count/2]
        let denselyPacked=steps.count>=2 && (steps.last ?? 0)<=typicalPitch*1.35
        var paragraphs:[(texts:[String],frames:[NSRect])]=[]
        for fragment in fragments {
            var text=fragment.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else{continue}
            let item=listItem(text)
            if let item {text=item.prefix+" "+item.body}
            let frame=fragment.frame
            let columnRight=fragments.lazy.map(\.frame).filter { other in
                let height=min(frame.height,other.height)
                let overlap=min(frame.maxX,other.maxX)-max(frame.minX,other.minX)
                return abs(frame.minX-other.minX)<=max(28,height*2.5) &&
                    max(frame.height,other.height)<=height*1.4 && overlap>min(frame.width,other.width)*0.45
            }.map(\.maxX).max() ?? frame.maxX
            // Rows from neighboring columns can be interleaved by Vision.
            let last=paragraphs.indices.reversed().first { index in
                guard item == nil else{return false}
                guard let previous=paragraphs[index].frames.last else{return false}
                let gap=frame.minY-previous.maxY
                let lineHeight=min(frame.height,previous.height)
                let horizontalOverlap=max(0,min(frame.maxX,previous.maxX) -
                    max(frame.minX,previous.minX))
                let overlapRatio=horizontalOverlap/max(1,min(frame.width,previous.width))
                // Normal wrapped lines have modest leading and share a text
                // column. The former 1.15-line-height threshold joined nearby
                // *paragraphs* into one request, erasing their blank space.
                return gap >= -lineHeight*0.35 &&
                    frame.midY-previous.midY <= typicalPitch*1.45 &&
                    gap <= max(frame.height,previous.height)*0.80 &&
                    max(frame.height,previous.height) <= lineHeight*1.4 &&
                    overlapRatio >= 0.45 &&
                    // Dense text needs ragged endings; documents with blank lines keep their prose blocks.
                    (!denselyPacked || columnRight-previous.maxX <= max(lineHeight*2,(columnRight-previous.minX)*0.15)) &&
                    abs(frame.minX-previous.minX) <= max(28,lineHeight*2.5)
            }
            if let last {
                paragraphs[last].texts.append(text)
                paragraphs[last].frames.append(frame)
                continue
            }
            paragraphs.append(([text],[frame]))
        }
        return paragraphs.map { paragraph in
            let first=paragraph.frames[0]
            let text=paragraph.texts.reduce(into:"") { result,row in
                if !result.isEmpty {
                    let boundary=String(result.suffix(1))+String(row.prefix(1))
                    if boundary.range(of:"[\\p{Han}\\p{Hiragana}\\p{Katakana}]",options:.regularExpression) == nil {result+=" "}
                }
                result+=row
            }
            return Self(text:text,
                        rect:paragraph.frames.dropFirst().reduce(first){$0.union($1)},
                        lineHeight:paragraph.frames.map(\.height).reduce(0,+) /
                            CGFloat(paragraph.frames.count),sourceLines:paragraph.frames,sourceLineTexts:paragraph.texts)
        }
    }
}

struct ScreenshotOCRFontStyle:Equatable {
    var bold=false,italic=false

    func font(_ size:CGFloat)->NSFont {
        let base=NSFont.systemFont(ofSize:size,weight:bold ? .bold:.regular)
        guard italic else{return base}
        return NSFont(descriptor:base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic)),size:size) ?? base
    }
}

struct ScreenshotOCRTranslationLine {
    let text:String
    let rect:NSRect
    let fontSize:CGFloat
    var prefixIndent:CGFloat=0
    var baselineOffset:CGFloat?=nil
    var style=ScreenshotOCRFontStyle()

    func shaped(color:NSColor = .labelColor)->CTLine {
        let font=style.font(fontSize)
        let value=NSMutableAttributedString(string:text,attributes:[.font:font,.foregroundColor:color])
        if baselineOffset != nil {
            // Later characters must not reshape the positions of published glyphs.
            value.addAttributes([.ligature:0,.kern:0],range:NSRange(location:0,length:value.length))
        }
        if prefixIndent>0,let item=ScreenshotOCRTranslationSegment.listItem(text) {
            let prefix=item.prefix+" "
            let width=(prefix as NSString).size(withAttributes:[.font:font]).width
            value.addAttribute(.kern,value:prefixIndent-width,
                               range:NSRange(location:(prefix as NSString).length-1,length:1))
        }
        return CTLineCreateWithAttributedString(value)
    }
}

struct ScreenshotOCRBackgroundPatch {
    let image:NSImage
    let rect:NSRect
    var inkRect:NSRect?=nil
    var style=ScreenshotOCRFontStyle()
}

enum ScreenshotOCRTranslationBackground {
    static func color(from image:NSBitmapImageRep,in source:NSRect,within area:NSRect,
                      excluding recognizedLines:[NSRect])->NSColor {
        let region=area.intersection(source)
        guard source.width>0,source.height>0,region.width>0,region.height>0 else{return .white}
        let sx=CGFloat(image.pixelsWide)/source.width,sy=CGFloat(image.pixelsHigh)/source.height
        let left=max(0,Int(floor((region.minX-source.minX)*sx)))
        let top=max(0,Int(floor((region.minY-source.minY)*sy)))
        let right=min(image.pixelsWide,Int(ceil((region.maxX-source.minX)*sx)))
        let bottom=min(image.pixelsHigh,Int(ceil((region.maxY-source.minY)*sy)))
        let excluded=recognizedLines.map{$0.insetBy(dx:-1,dy:-1)}
        var points:[NSPoint]=[],clean:[NSPoint]=[]
        // A bounded grid estimates the dominant background without scanning every pixel.
        for y in stride(from:top,to:bottom,by:max(1,(bottom-top+63)/64)) {
            for x in stride(from:left,to:right,by:max(1,(right-left+63)/64)) {
                let pixel=NSPoint(x:x,y:y)
                points.append(pixel)
                let point=NSPoint(x:source.minX+(CGFloat(x)+0.5)/sx,y:source.minY+(CGFloat(y)+0.5)/sy)
                if !excluded.contains(where:{$0.contains(point)}) {clean.append(pixel)}
            }
        }
        var bins:[Int:(count:Int,sum:SIMD3<Double>)]=[:],winner=0,largest=0
        for point in clean.isEmpty ? points:clean {
            guard let color=image.ocrColorAt(x:Int(point.x),y:Int(point.y)) else{continue}
            let alpha=Double(color.alphaComponent)
            let rgb=SIMD3(Double(color.redComponent),Double(color.greenComponent),Double(color.blueComponent))*alpha +
                SIMD3<Double>(repeating:1-alpha)
            let key=Int(min(15,max(0,rgb.x*15)))<<8 | Int(min(15,max(0,rgb.y*15)))<<4 | Int(min(15,max(0,rgb.z*15)))
            var bin=bins[key] ?? (0,.zero)
            bin.count+=1;bin.sum+=rgb;bins[key]=bin
            if bin.count>largest {winner=key;largest=bin.count}
        }
        guard let bin=bins[winner] else{return .white}
        let rgb=bin.sum/Double(bin.count)
        return NSColor(deviceRed:CGFloat(rgb.x),green:CGFloat(rgb.y),blue:CGFloat(rgb.z),alpha:1)
    }

    static func textColor(on color:NSColor)->NSColor {
        let color=color.usingColorSpace(.deviceRGB) ?? .white
        let luminance=0.2126*color.redComponent + 0.7152*color.greenComponent + 0.0722*color.blueComponent
        return luminance>0.52 ? NSColor(calibratedWhite:0.12,alpha:1):NSColor(calibratedWhite:0.96,alpha:1)
    }
}

struct ScreenshotOCRTranslationOverlay {
    var text:String
    let sourceRect:NSRect
    var sourceLineHeight:CGFloat?=nil
    var sourceLines:[NSRect]=[]
    var sourceLineTexts:[String]=[]
    var sourceText:String?=nil
    var segmentIndex:Int?=nil
    var backgroundColor:NSColor?=nil
    var isTruncated=false
    var sourceFullyReplaced=false
    var restoredPatches:[ScreenshotOCRBackgroundPatch]=[]
    var restoredBackground:NSImage? {restoredPatches.first?.image}
    var backgroundRect:NSRect? {restoredPatches.first?.rect}
    var lines:[ScreenshotOCRTranslationLine]=[]

    func revealingPrefix(_ count:Int)->Self {
        var result=self;result.text=String(text.prefix(max(0,count)))
        let source=text as NSString
        var cursor=0
        result.lines=lines.compactMap { line in
            let range=source.range(of:line.text,range:NSRange(location:cursor,length:source.length-cursor))
            guard range.location != NSNotFound else{return nil}
            cursor=NSMaxRange(range)
            let visible=max(0,count-source.substring(to:range.location).count)
            guard visible>0 else{return nil}
            return ScreenshotOCRTranslationLine(text:String(line.text.prefix(visible)),rect:line.rect,
                fontSize:line.fontSize,prefixIndent:line.prefixIndent,baselineOffset:line.baselineOffset,style:line.style)
        }
        return result
    }

    func replacementRects(sourceRows:[NSRect])->[NSRect] {
        var rects=lines.map { line in
            let width=CGFloat(CTLineGetTypographicBounds(line.shaped(),nil,nil,nil))
            return NSRect(x:line.rect.minX-1,y:line.rect.minY-2,width:max(1,width)+3,height:line.rect.height+4)
        }
        if sourceFullyReplaced {
            for row in (sourceLines.isEmpty ? [sourceRect]:sourceLines) {
                let neighbors=sourceRows.filter { other in
                    let overlap=min(row.maxX,other.maxX)-max(row.minX,other.minX)
                    return overlap>min(row.width,other.width)*0.45 &&
                        abs(other.midY-row.midY)>min(row.height,other.height)*0.45
                }
                let top=max(row.minY-2,neighbors.filter{$0.midY<row.midY}.map{($0.midY+row.midY)/2}.max() ?? row.minY-2)
                let bottom=min(row.maxY+2,neighbors.filter{$0.midY>row.midY}.map{($0.midY+row.midY)/2}.min() ?? row.maxY+2)
                rects.append(NSRect(x:row.minX-2,y:top,width:row.width+4,height:max(0,bottom-top)))
            }
        }
        return rects
    }

    var displayText:String {
        text.replacingOccurrences(of:"\n",with:" ")
    }

    func fontSize(within area:NSRect)->CGFloat {
        if let line=lines.first{return line.fontSize}
        let available=max(1,area.maxX-max(area.minX,sourceRect.minX))
        let desired=min(28,max(8,(sourceLineHeight ?? sourceRect.height)*0.84))
        let candidate=displayText as NSString
        var fontSize=desired
        while fontSize>8 && candidate.size(withAttributes:[
            .font:NSFont.systemFont(ofSize:fontSize)]).width>available {
            fontSize-=0.5
        }
        return fontSize
    }

    func displayRect(within area:NSRect)->NSRect {
        if let first=lines.first {
            return lines.dropFirst().reduce(first.rect){$0.union($1.rect)}
        }
        let x=max(area.minX,min(sourceRect.minX,area.maxX-1))
        let font=NSFont.systemFont(ofSize:fontSize(within:area))
        let measured=(displayText as NSString).size(withAttributes:[.font:font])
        let width=min(area.maxX-x,max(sourceRect.width,measured.width+2))
        let height=min(area.height,max(sourceRect.height,ceil(measured.height)))
        let y=max(area.minY,min(sourceRect.minY,area.maxY-height))
        return NSRect(x:x,y:y,width:max(1,width),height:max(1,height))
    }

    func withRestoredBackground(from image:NSBitmapImageRep,in source:NSRect,
                                excluding recognizedLines:[NSRect]=[])->Self {
        var result=self
        guard source.width>0,source.height>0 else{return result}
        let sx=CGFloat(image.pixelsWide)/source.width,sy=CGFloat(image.pixelsHigh)/source.height
        let regions=sourceLines.isEmpty ? [sourceRect]:sourceLines
        result.restoredPatches=regions.enumerated().compactMap { index,line in
            let paddingX=max(2,min(3,line.height*0.10))
            let paddingY=paddingX
            let expanded=line.insetBy(dx:-paddingX,dy:-paddingY).intersection(source)
            let left=floor((expanded.minX-source.minX)*sx),top=floor((expanded.minY-source.minY)*sy)
            let right=ceil((expanded.maxX-source.minX)*sx),bottom=ceil((expanded.maxY-source.minY)*sy)
            let padded=NSRect(x:source.minX+left/sx,y:source.minY+top/sy,
                              width:(right-left)/sx,height:(bottom-top)/sy)
            guard padded.width>0,padded.height>0,
                let patch=ScreenshotOCRBackgroundRestoration.make(
                    from:image,source:source,region:padded,line:line,
                    excluding:recognizedLines.isEmpty ? regions:recognizedLines,
                    text:sourceLineTexts.indices.contains(index) ? sourceLineTexts[index]:"") else{return nil}
            return ScreenshotOCRBackgroundPatch(image:patch.image,rect:padded,inkRect:patch.inkRect,style:patch.style)
        }
        return result
    }

    func draw(in area:NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:area).addClip()
        let color=backgroundColor.map{ScreenshotOCRTranslationBackground.textColor(on:$0)} ??
            restoredBackground?.suggestedTextColor ?? .labelColor
        for line in lines {
            let shaped=line.shaped(color:color)
            guard let context=NSGraphicsContext.current?.cgContext else{continue}
            let ink=CTLineGetBoundsWithOptions(shaped,.useGlyphPathBounds)
            context.saveGState()
            context.translateBy(x:line.rect.minX-(line.baselineOffset == nil ? ink.minX:0),
                                y:line.rect.minY+(line.baselineOffset ?? ink.maxY))
            context.scaleBy(x:1,y:-1)
            context.textMatrix = .identity;context.textPosition = .zero
            CTLineDraw(shaped,context)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum ScreenshotOCRTranslationLayout {
    /// Fit complete paragraphs to source anchors before revealing their characters.
    static func arrange(_ overlays:[ScreenshotOCRTranslationOverlay],within area:NSRect,
                        streamingTarget:String?=nil)->[ScreenshotOCRTranslationOverlay]? {
        guard !overlays.isEmpty else{return []}
        var ordered=overlays.sorted {
            $0.sourceRect.minY == $1.sourceRect.minY ?
                $0.sourceRect.minX<$1.sourceRect.minX : $0.sourceRect.minY<$1.sourceRect.minY
        }
        for index in ordered.indices {
            if !ordered[index].text.isEmpty,let item=ScreenshotOCRTranslationSegment.listItem(ordered[index].sourceText ?? "") {
                let text=ordered[index].text
                let stripped=text.trimmingCharacters(in:.whitespacesAndNewlines)
                let body=item.prefix.hasPrefix(stripped) ? "":(ScreenshotOCRTranslationSegment.listItem(text)?.body ?? text)
                ordered[index].text=item.prefix+(body.isEmpty ? "":" "+body)
            }
        }
        let recognizedRows=ordered.flatMap{$0.sourceLines.isEmpty ? [$0.sourceRect]:$0.sourceLines}
        let sources=ordered.map { overlay -> [NSRect] in
            let rows=overlay.sourceLines.isEmpty ? [overlay.sourceRect]:overlay.sourceLines
            return rows.map { row in
                let ink=overlay.restoredPatches.first(where:{$0.rect.contains(NSPoint(x:row.midX,y:row.midY))})?.inkRect ?? row
                let neighbors=recognizedRows.filter { other in
                    let overlap=min(row.maxX,other.maxX)-max(row.minX,other.minX)
                    return overlap>min(row.width,other.width)*0.45 &&
                        abs(other.midY-row.midY)>min(row.height,other.height)*0.45
                }
                // Overlapping OCR boxes can include neighboring glyphs; each row owns its center band.
                let top=neighbors.filter{$0.midY<row.midY}.map(\.midY).max().map{($0+row.midY)/2} ?? ink.minY
                let bottom=neighbors.filter{$0.midY>row.midY}.map(\.midY).min().map{($0+row.midY)/2} ?? ink.maxY
                let band=NSRect(x:ink.minX,y:top,width:ink.width,height:max(1,bottom-top))
                let clipped=ink.intersection(band)
                return clipped.isEmpty ? row.intersection(band):clipped
            }
        }
        func median(_ values:[CGFloat])->CGFloat {values.sorted()[values.count/2]}
        let heights=ordered.indices.map { index in
            ordered[index].restoredPatches.contains(where:{$0.inkRect != nil}) ?
                median(sources[index].map(\.height)) :
                (ordered[index].sourceLineHeight ?? median(sources[index].map(\.height)))
        }
        var groups:[[Int]]=[]
        for index in ordered.indices {
            if let group=groups.firstIndex(where:{ members in
                let height=median(members.map{heights[$0]})
                return max(height,heights[index])<=min(height,heights[index])*1.22
            }) {groups[group].append(index)} else {groups.append([index])}
        }
        if let target=streamingTarget {
            let sample=Locale(identifier:target).localizedString(forIdentifier:target) ?? target
            let shaped=CTLineCreateWithAttributedString(NSAttributedString(string:sample,
                attributes:[.font:NSFont.systemFont(ofSize:100)]))
            let glyphHeight=max(NSFont.systemFont(ofSize:100).capHeight,
                CTLineGetBoundsWithOptions(shaped,.useGlyphPathBounds).height)
            var preferred=[CGFloat](repeating:4,count:ordered.count)
            for members in groups {
                var size=max(4,median(members.map{heights[$0]})*100/max(1,glyphHeight))
                let font=NSFont.systemFont(ofSize:100)
                let singleRowSlots=members.filter{sources[$0].count==1}.compactMap { index -> CGFloat? in
                    let row=sources[index][0],box=ordered[index].sourceRect
                    let next=ordered.indices.filter {
                        sources[$0][0].minY>row.minY+0.5 &&
                            ordered[$0].sourceRect.maxX>box.minX && ordered[$0].sourceRect.minX<box.maxX
                    }.map{sources[$0][0].minY}.min()
                    guard let next else{return nil}
                    return max(4,(next-max(area.minY+4,row.minY)-4)*100/(font.ascender-font.descender))
                }
                if singleRowSlots.count>=2 {size=min(size,median(singleRowSlots))}
                for index in members {preferred[index]=size}
            }
            return anchored(ordered,sources:sources,heights:heights,preferred:preferred,within:area)
        }
        for members in groups {
            let sample=members.map{ordered[$0].text}.joined(separator:" ")
            let shaped=CTLineCreateWithAttributedString(NSAttributedString(string:sample,
                attributes:[.font:NSFont.systemFont(ofSize:100)]))
            let glyphHeight=CTLineGetBoundsWithOptions(shaped,.useGlyphPathBounds).height
            let desired=max(4,median(members.map{heights[$0]})*100/max(1,glyphHeight))
            func layout(_ size:CGFloat)->[[ScreenshotOCRTranslationLine]]? {
                var result:[[ScreenshotOCRTranslationLine]]=[]
                for index in members {
                    let original=ordered[index],rows=sources[index]
                    let origin=NSPoint(x:max(area.minX,rows[0].minX),y:max(area.minY,rows[0].minY))
                    // A short source line occupies its column, not a tiny box
                    // that forces a longer target language to shrink needlessly.
                    let peers=members.filter {
                        let peer=ordered[$0].sourceRect,box=original.sourceRect
                        let overlap=min(peer.maxX,box.maxX)-max(peer.minX,box.minX)
                        return abs(peer.minX-box.minX)<=heights[index]*2 &&
                            overlap>min(peer.width,box.width)*0.45
                    }
                    let right=min(area.maxX,peers.map{ordered[$0].sourceRect.maxX}.max() ?? original.sourceRect.maxX)
                    let next=ordered.indices.filter {
                        $0 != index && sources[$0][0].minY>rows[0].minY+0.5 &&
                        ordered[$0].sourceRect.maxX>origin.x && ordered[$0].sourceRect.minX<right
                    }.map{sources[$0][0].minY}.min() ?? area.maxY
                    let bottom=min(area.maxY,next<area.maxY ? next-2:next)
                    let lines=wrap(original.text,width:right-origin.x,fontSize:size,origin:origin,
                        sourceLines:rows,bottom:bottom,sourceLineHeight:original.sourceLineHeight ?? heights[index],
                        streaming:false)
                    guard !lines.isEmpty,lines.allSatisfy({$0.rect.maxX<=right+0.01 && $0.rect.maxY<=bottom+0.01}),
                        zip(lines,lines.dropFirst()).allSatisfy({$0.0.rect.maxY<=$0.1.rect.minY+0.01}) else{return nil}
                    result.append(lines)
                }
                return result
            }
            var lines=layout(desired)
            if lines == nil {
                var low=min(4,desired),high=desired
                guard let smallest=layout(low) else{return nil}
                lines=smallest
                for _ in 0..<10 {
                    let size=(low+high)/2
                    if let fitted=layout(size) {low=size;lines=fitted} else{high=size}
                }
            }
            guard let lines else{return nil}
            for (index,value) in zip(members,lines) {
                ordered[index].lines=value
            }
        }
        return ordered
    }

    private static func anchored(_ overlays:[ScreenshotOCRTranslationOverlay],sources:[[NSRect]],
                                heights:[CGFloat],preferred:[CGFloat],within area:NSRect)->[ScreenshotOCRTranslationOverlay] {
        var result=overlays
        for index in result.indices {
            guard !overlays[index].text.isEmpty else{result[index].lines=[];continue}
            let rows=sources[index]
            let desired=preferred[index]
            let box=overlays[index].sourceRect
            let peers=overlays.indices.filter {
                let other=overlays[$0].sourceRect
                let overlap=min(other.maxX,box.maxX)-max(other.minX,box.minX)
                return abs(other.minX-box.minX)<=max(heights[index],heights[$0])*2 &&
                    overlap>min(other.width,box.width)*0.45
            }
            let left=max(area.minX+4,rows[0].minX)
            let right=min(area.maxX-19,peers.map{overlays[$0].sourceRect.maxX}.max() ?? box.maxX)
            let previous=peers.filter{$0<index && !result[$0].lines.isEmpty}.max {
                (result[$0].lines.last?.rect.maxY ?? 0)<(result[$1].lines.last?.rect.maxY ?? 0)
            }
            let previousBottom=previous.flatMap{result[$0].lines.last?.rect.maxY}
            let gap=previous.map{max(4,rows[0].minY-(sources[$0].last?.maxY ?? rows[0].minY))} ?? 4
            let top=max(area.minY+4,rows[0].minY,(previousBottom ?? -gap)+gap)
            let next=overlays.indices.filter {
                sources[$0][0].minY>rows[0].minY+0.5 &&
                    overlays[$0].sourceRect.maxX>left && overlays[$0].sourceRect.minX<right
            }.map{sources[$0][0].minY}.min() ?? area.maxY
            let bottom=min(area.maxY,next)-4
            // shortcut: mixed inline styles fall back to plain until source and translated spans can be aligned reliably.
            let styles=overlays[index].restoredPatches.map(\.style)
            let style=styles.first.flatMap { first in styles.allSatisfy{$0==first} ? first:nil } ?? .init()
            func layout(_ size:CGFloat)->[ScreenshotOCRTranslationLine] {
                wrap(overlays[index].text,width:max(1,right-left),fontSize:size,
                    origin:NSPoint(x:left,y:top),sourceLines:rows,bottom:bottom,
                    sourceLineHeight:overlays[index].sourceLineHeight ?? heights[index],streaming:true,
                    style:style)
            }
            let lines=layout(desired)
            result[index].lines=lines
            result[index].isTruncated=false
        }
        return result
    }

    private static func wrap(_ text:String,width:CGFloat,fontSize:CGFloat,origin:NSPoint,
                             sourceLines:[NSRect],bottom:CGFloat,sourceLineHeight:CGFloat,
                             streaming:Bool,style:ScreenshotOCRFontStyle = .init())->[ScreenshotOCRTranslationLine] {
        guard width>0 else{return []}
        let item=ScreenshotOCRTranslationSegment.listItem(text)
        let prefix=item.map{$0.prefix+" "} ?? ""
        let content=(item?.body ?? text) as NSString
        let font=style.font(fontSize)
        let prefixWidth=(prefix as NSString).size(withAttributes:[.font:font]).width
        let indent=item.map{max(prefixWidth,sourceLineHeight*CGFloat($0.prefix.count+1)*0.43)} ?? 0
        var attributes:[NSAttributedString.Key:Any]=[.font:font]
        if streaming {attributes[.ligature]=0;attributes[.kern]=0}
        let typesetter=CTTypesetterCreateWithAttributedString(NSAttributedString(string:content as String,attributes:attributes))
        let advance=CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
            NSAttributedString(string:content as String,attributes:[.font:font])),nil,nil,nil))
        let sourceWidth=max(1,sourceLines.map(\.width).reduce(0,+))
        func breaks(_ available:CGFloat,proportional:Bool=false)->[String] {
            var rows:[String]=[],start=0
            while start<content.length {
                let limit=proportional && rows.count<sourceLines.count-1 ?
                    min(available,advance*sourceLines[rows.count].width/sourceWidth):available
                let length=streaming ? CTTypesetterSuggestClusterBreak(typesetter,start,Double(max(1,limit))):
                    CTTypesetterSuggestLineBreak(typesetter,start,Double(max(1,limit)))
                var count=length>0 ? length:CTTypesetterSuggestClusterBreak(typesetter,start,Double(max(1,limit)))
                guard count>0 else{return []}
                if streaming {
                    let newline=content.rangeOfCharacter(from:.newlines,range:NSRange(location:start,length:count))
                    if newline.location != NSNotFound {count=newline.location+newline.length-start}
                }
                let row=content.substring(with:NSRange(location:start,length:count)).trimmingCharacters(in:.whitespacesAndNewlines)
                if !row.isEmpty {rows.append(row)}
                start+=count
            }
            return rows
        }
        let available=width-indent
        var rows=breaks(available)
        // Keep the relative amount of text on each source row when it fits.
        if !streaming,!rows.isEmpty,sourceLines.count>1,rows.count<=sourceLines.count {
            let proportional=breaks(available,proportional:true)
            if proportional.count<=sourceLines.count {rows=proportional}
        }
        var lines=rows.enumerated().map { index,row -> ScreenshotOCRTranslationLine in
            var line=ScreenshotOCRTranslationLine(text:index == 0 ? prefix+row:row,
                rect:.zero,fontSize:fontSize,prefixIndent:index == 0 ? indent:0,
                baselineOffset:streaming ? font.ascender:nil,style:style)
            let ink=CTLineGetBoundsWithOptions(line.shaped(),.useGlyphPathBounds)
            line=ScreenshotOCRTranslationLine(text:line.text,rect:NSRect(x:origin.x+(index == 0 ? 0:indent),
                y:origin.y,width:max(1,streaming ? CGFloat(CTLineGetTypographicBounds(line.shaped(),nil,nil,nil)):ink.width),
                height:max(1,streaming ? font.ascender-font.descender:ink.height)),fontSize:fontSize,
                prefixIndent:line.prefixIndent,baselineOffset:line.baselineOffset,style:style)
            return line
        }
        let maxHeight=lines.map{$0.rect.height}.max() ?? 0
        let originalPitch=zip(sourceLines,sourceLines.dropFirst()).map{$0.1.minY-$0.0.minY}
        let naturalPitch=max(font.ascender-font.descender+font.leading,maxHeight+fontSize*0.15)
        let desiredPitch=originalPitch.isEmpty ? naturalPitch:originalPitch.sorted()[originalPitch.count/2]
        let pitch=streaming ? (originalPitch.isEmpty ? naturalPitch:max(maxHeight+1,desiredPitch)):
            max(maxHeight+fontSize*0.12,min(desiredPitch,(bottom-origin.y-maxHeight)/CGFloat(max(1,lines.count-1))))
        for index in lines.indices {
            lines[index]=ScreenshotOCRTranslationLine(text:lines[index].text,rect:NSRect(
                x:lines[index].rect.minX,
                y:!streaming && rows.count == sourceLines.count ? max(origin.y,sourceLines[index].minY):origin.y+CGFloat(index)*pitch,
                width:lines[index].rect.width,height:lines[index].rect.height),
                fontSize:fontSize,prefixIndent:lines[index].prefixIndent,baselineOffset:lines[index].baselineOffset,style:style)
        }
        return lines
    }
}

private enum ScreenshotOCRTypography {
    static func estimate(text:String,pixels:[Int],width:Int)->ScreenshotOCRFontStyle {
        guard text.count>=4,pixels.count>=20,width>0,
              let left=pixels.map({$0%width}).min(),let right=pixels.map({$0%width}).max(),
              let top=pixels.map({$0/width}).min(),let bottom=pixels.map({$0/width}).max(),bottom>top else{return .init()}
        let height=32,columns=min(512,max(32,(right-left+1)*height/(bottom-top+1)))
        var original=[Bool](repeating:false,count:columns*height)
        for pixel in pixels {
            let x=min(columns-1,(pixel%width-left)*columns/(right-left+1))
            let y=min(height-1,(pixel/width-top)*height/(bottom-top+1))
            original[y*columns+x]=true
        }
        let candidates=[ScreenshotOCRFontStyle(),.init(bold:true),.init(italic:true),.init(bold:true,italic:true)]
        var scores:[Double]=[]
        for style in candidates {
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[
                .font:style.font(100),.foregroundColor:NSColor.white]))
            let bounds=CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
            guard bounds.width>0,bounds.height>0 else{scores.append(0);continue}
            var data=[UInt8](repeating:0,count:columns*height)
            data.withUnsafeMutableBytes { bytes in
                guard let context=CGContext(data:bytes.baseAddress,width:columns,height:height,bitsPerComponent:8,
                    bytesPerRow:columns,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else{return}
                context.setShouldAntialias(false)
                context.scaleBy(x:CGFloat(columns)/bounds.width,y:CGFloat(height)/bounds.height)
                context.textPosition=CGPoint(x:-bounds.minX,y:-bounds.minY)
                CTLineDraw(line,context)
            }
            var intersection=0,union=0
            for i in data.indices {
                let rendered=data[i]>100
                if original[i] && rendered {intersection+=1}
                if original[i] || rendered {union+=1}
            }
            scores.append(union>0 ? Double(intersection)/Double(union):0)
        }
        guard let best=scores.indices.max(by:{scores[$0]<scores[$1]}),best>0,
              scores[best]>=0.48,scores[best]>scores[0]+0.08 else{return .init()}
        return candidates[best]
    }
}

private enum ScreenshotOCRBackgroundRestoration {
    /// Repair a local ink mask; pixels outside it retain their original color.
    static func make(from original:NSBitmapImageRep,source:NSRect,region:NSRect,
                     line:NSRect,excluding recognizedLines:[NSRect]=[],text:String="")->(image:NSImage,inkRect:NSRect?,style:ScreenshotOCRFontStyle)? {
        guard source.width>0,source.height>0 else{return nil}
        let sx=CGFloat(original.pixelsWide)/source.width
        let sy=CGFloat(original.pixelsHigh)/source.height
        let x=max(0,Int(round((region.minX-source.minX)*sx)))
        let top=max(0,Int(round((region.minY-source.minY)*sy)))
        let w=min(original.pixelsWide-x,max(1,Int(round(region.width*sx))))
        let h=min(original.pixelsHigh-top,max(1,Int(round(region.height*sy))))
        guard w>0,h>0 else{return nil}
        guard let patch=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
            colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else{return nil}
        func pixels(_ rect:NSRect)->NSRect {
            NSRect(x:(rect.minX-source.minX)*sx-CGFloat(x),
                   y:(rect.minY-source.minY)*sy-CGFloat(top),
                   width:rect.width*sx,height:rect.height*sy).insetBy(dx:-1,dy:-1)
        }
        let target=pixels(line)
        let excluded=recognizedLines.map(pixels).filter{$0.intersects(NSRect(x:0,y:0,width:w,height:h))}
        var colors=[SIMD4<Float>](repeating:.zero,count:w*h)
        var unsafe=[Bool](repeating:false,count:w*h),inside=unsafe,blocked=unsafe
        var perimeter:[SIMD4<Float>]=[]
        func key(_ color:SIMD4<Float>)->Int {
            let r=Int(min(15,max(0,color.x*15))),g=Int(min(15,max(0,color.y*15)))
            let b=Int(min(15,max(0,color.z*15))),a=Int(min(15,max(0,color.w*15)))
            return a<<12 | r<<8 | g<<4 | b
        }
        var backgroundBins:[Int:Int]=[:]
        for row in 0..<h {for column in 0..<w {
            let i=row*w+column,point=NSPoint(x:CGFloat(column)+0.5,y:CGFloat(row)+0.5)
            let color=original.ocrColorAt(x:x+column,y:top+row) ?? .white
            let alpha=Float(color.alphaComponent)
            colors[i]=SIMD4(Float(color.redComponent)*alpha,Float(color.greenComponent)*alpha,
                            Float(color.blueComponent)*alpha,alpha)
            inside[i]=target.contains(point)
            unsafe[i]=excluded.contains{$0.contains(point)}
            blocked[i]=unsafe[i] && !inside[i]
            if !unsafe[i] {perimeter.append(colors[i]);backgroundBins[key(colors[i]),default:0]+=1}
        }}
        guard !perimeter.isEmpty else{return nil}
        let fallback=perimeter.reduce(SIMD4<Float>.zero,+)/Float(perimeter.count)
        var candidate=[Bool](repeating:false,count:w*h),inkBins:[Int:Int]=[:]
        let count=max(1,inside.filter{$0}.count)
        for column in 0..<w {
            let upper=(0..<h).first{!unsafe[$0*w+column]}
            let lower=(0..<h).last{!unsafe[$0*w+column]}
            let a=upper.map{colors[$0*w+column]} ?? fallback
            let b=lower.map{colors[$0*w+column]} ?? fallback
            for row in 0..<h where inside[row*w+column] {
                let i=row*w+column
                let fraction=Float(row-(upper ?? 0))/Float(max(1,(lower ?? h-1)-(upper ?? 0)))
                let predicted=a+(b-a)*min(1,max(0,fraction))
                let delta=colors[i]-predicted
                candidate[i]=max(abs(delta.x),abs(delta.y),abs(delta.z),abs(delta.w))>0.055
                if candidate[i] {inkBins[key(colors[i]),default:0]+=1}
            }
        }
        // Ink colors are concentrated inside OCR boxes, not in the clean rim.
        // This avoids treating an existing texture or separator as text.
        let ink=Set(inkBins.compactMap { bin,frequency -> Int? in
            let r=(bin>>8)&15,g=(bin>>4)&15,b=bin&15,alpha=bin&0xF000
            var background=0
            for dr in -1...1 {for dg in -1...1 {for db in -1...1 {
                let nr=r+dr,ng=g+dg,nb=b+db
                if (0...15).contains(nr),(0...15).contains(ng),(0...15).contains(nb) {
                    background+=backgroundBins[alpha | nr<<8 | ng<<4 | nb,default:0]
                }
            }}}
            return Float(frequency)/Float(count)>Float(background)/Float(perimeter.count)*2.5+0.01 ? bin:nil
        })
        var mask=colors.indices.map{candidate[$0] && ink.contains(key(colors[$0]))}
        var neighborCache:[Int:[Int]]=[:]
        func neighbors(_ index:Int)->[Int] {
            if let cached=neighborCache[index] {return cached}
            let row=index/w,column=index%w
            let result:[Int]=(-1...1).flatMap { dy in (-1...1).compactMap { dx in
                let nr=row+dy,nc=column+dx
                return (dx != 0 || dy != 0) && nr>=0 && nr<h && nc>=0 && nc<w ? nr*w+nc:nil
            }}
            neighborCache[index]=result
            return result
        }
        var seen=[Bool](repeating:false,count:w*h)
        for seed in mask.indices where mask[seed] && !seen[seed] {
            var component=[seed],cursor=0;seen[seed]=true
            var left=seed%w,right=left,upper=seed/w,lower=upper
            while cursor<component.count {
                let i=component[cursor];cursor+=1
                left=min(left,i%w);right=max(right,i%w);upper=min(upper,i/w);lower=max(lower,i/w)
                for next in neighbors(i) where mask[next] && !seen[next] {seen[next]=true;component.append(next)}
            }
            if CGFloat(right-left)>target.height*4 && CGFloat(lower-upper)<target.height*0.45 {
                for i in component {mask[i]=false}
            }
        }
        let inkPixels=mask.indices.filter{mask[$0]}
        func contrast(_ index:Int)->Float {
            let delta=colors[index]-fallback
            return max(abs(delta.x),abs(delta.y),abs(delta.z),abs(delta.w))
        }
        let strongest=inkPixels.map(contrast).max() ?? 0
        // Code-pill backgrounds are not glyphs; measure the contrasting foreground.
        let glyphPixels=inkPixels.filter{contrast($0)>=strongest*0.3}
        let inkRect:NSRect?
        if let left=glyphPixels.map({$0%w}).min(),let right=glyphPixels.map({$0%w}).max(),
           let upper=glyphPixels.map({$0/w}).min(),let lower=glyphPixels.map({$0/w}).max() {
            inkRect=NSRect(x:source.minX+CGFloat(x+left)/sx,y:source.minY+CGFloat(top+upper)/sy,
                           width:CGFloat(right-left+1)/sx,height:CGFloat(lower-upper+1)/sy)
        } else {inkRect=nil}
        let style=ScreenshotOCRTypography.estimate(text:text,pixels:glyphPixels,width:w)
        for i in inkPixels {for next in neighbors(i) where inside[next] && !blocked[next] {mask[next]=true}}
        let repair=mask.indices.filter{mask[$0]}
        var unknown=mask,queued=[Bool](repeating:false,count:w*h),front:[Int]=[]
        for i in repair where neighbors(i).contains(where:{!unknown[$0] && !blocked[$0]}) {
            front.append(i);queued[i]=true
        }
        func average(_ indices:[Int])->SIMD4<Float> {
            indices.isEmpty ? fallback:indices.reduce(SIMD4<Float>.zero){$0+colors[$1]}/Float(indices.count)
        }
        while !front.isEmpty {
            let values=front.map{average(neighbors($0).filter{!unknown[$0] && !blocked[$0]})}
            for (i,value) in zip(front,values) {colors[i]=value;unknown[i]=false}
            var nextFront:[Int]=[]
            for i in front {for next in neighbors(i) where unknown[next] && !queued[next] {
                nextFront.append(next);queued[next]=true
            }}
            front=nextFront
        }
        for i in repair where unknown[i] {colors[i]=fallback}
        for _ in 0..<12 {
            let values=repair.map{average(neighbors($0).filter{!blocked[$0]})}
            for (i,value) in zip(repair,values) {colors[i]=value}
        }
        for row in 0..<h {for column in 0..<w {
            let value=colors[row*w+column],alpha=value.w
            let rgb=alpha>0 ? value/alpha:SIMD4<Float>.zero
            patch.setColor(NSColor(deviceRed:CGFloat(rgb.x),green:CGFloat(rgb.y),
                blue:CGFloat(rgb.z),alpha:CGFloat(alpha)),atX:column,y:row)
        }}
        let output=NSImage(size:region.size)
        output.addRepresentation(patch)
        return (output,inkRect,style)
    }
}

private extension NSBitmapImageRep {
    func ocrColorAt(x:Int,y:Int)->NSColor? {
        guard let sampled=colorAt(x:x,y:y) else{return nil}
        // colorAt exposes generic RGB components even for monitor ICC profiles.
        let tagged=colorSpace.numberOfColorComponents == 3 ?
            NSColor(colorSpace:colorSpace,components:[sampled.redComponent,sampled.greenComponent,
                sampled.blueComponent,sampled.alphaComponent],count:4):sampled
        return tagged.usingColorSpace(.deviceRGB)
    }
}

private extension NSImage {
    var suggestedTextColor:NSColor {
        guard let sample=representations.compactMap({$0 as? NSBitmapImageRep}).first,
              let color=sample.colorAt(x:sample.pixelsWide/2,y:sample.pixelsHigh/2)?
                .usingColorSpace(.deviceRGB) else{return .labelColor}
        return ScreenshotOCRTranslationBackground.textColor(on:color)
    }
}

/// This initializer can use installed Apple language resources only. The app
/// never downloads models or sends OCR text to an external service.
@available(macOS 26.0, *)
enum ScreenshotOCRTranslationService {
    static func translate(_ segments:[ScreenshotOCRTranslationSegment],
                          target override:String?=nil,source overrideSource:String?=nil,
                          onProgress:(@MainActor (Int,String) async->Void)?=nil,
                          onSegmentComplete:(@MainActor (Int) async->Void)?=nil) async throws ->[ScreenshotOCRTranslationOverlay] {
        guard !segments.isEmpty else{return []}
        let sourceText=segments.map(\.text).joined(separator:"\n")
        let source=overrideSource ?? ScreenshotOCRTranslationLanguage.source(for:sourceText)
        let target=override ?? ScreenshotOCRTranslationLanguage.defaultTarget(source:source)
        guard source != target else {
            throw NSError(domain:"MacState.OCRTranslation",code:1,
                          userInfo:[NSLocalizedDescriptionKey:"原文和目标语言相同，请更换翻译语言。"])
        }
        let sourceLanguage=Locale.Language(identifier:source)
        let targetLanguage=Locale.Language(identifier:target)
        let state=await LanguageAvailability().status(from:sourceLanguage,to:targetLanguage)
        try Task.checkCancellation()
        switch state {
        case .installed:break
        case .supported:
            throw NSError(domain:"MacState.OCRTranslation",code:2,
                          userInfo:[NSLocalizedDescriptionKey:"缺少离线语言包，请在系统设置的「通用 → 语言与地区 → 翻译语言」中安装。"])
        case .unsupported:
            throw NSError(domain:"MacState.OCRTranslation",code:3,
                          userInfo:[NSLocalizedDescriptionKey:"系统暂不支持这组离线翻译语言。"])
        @unknown default:
            throw NSError(domain:"MacState.OCRTranslation",code:4,
                          userInfo:[NSLocalizedDescriptionKey:"无法确认离线语言包状态。"])
        }
        let session=TranslationSession(installedSource:sourceLanguage,target:targetLanguage)
        let requests=segments.enumerated().map {
            TranslationSession.Request(sourceText:$0.element.text,clientIdentifier:String($0.offset))
        }
        var translated:[Int:String]=[:]
        for try await response in session.translate(batch:requests) {
            try Task.checkCancellation()
            guard let id=response.clientIdentifier,let index=Int(id),segments.indices.contains(index) else{continue}
            translated[index]=response.targetText
            await onProgress?(index,response.targetText)
            await onSegmentComplete?(index)
        }
        guard translated.count == segments.count else {
            throw NSError(domain:"MacState.OCRTranslation",code:5,
                          userInfo:[NSLocalizedDescriptionKey:"部分文字翻译失败，请重试。"])
        }
        return try segments.enumerated().map { index,segment in
            guard let text=translated[index] else {
                throw NSError(domain:"MacState.OCRTranslation",code:6,
                              userInfo:[NSLocalizedDescriptionKey:"译文顺序不完整。"])
            }
            return ScreenshotOCRTranslationOverlay(text:text,sourceRect:segment.rect,
                                                   sourceLineHeight:segment.lineHeight,
                                                   sourceLines:segment.sourceLines,sourceText:segment.text)
        }
    }
}
