import AppKit

/// OCR character positions are expressed as grapheme-cluster offsets instead
/// of UTF-16 offsets, so selecting Chinese, emoji and accented text is safe.
struct ScreenshotOCRPosition: Comparable, Equatable {
    var line: Int
    var offset: Int
    static func < (lhs:Self,rhs:Self)->Bool {
        lhs.line == rhs.line ? lhs.offset < rhs.offset : lhs.line < rhs.line
    }
}

struct ScreenshotOCRTextSelection {
    private(set) var boxes: [ScreenshotOCRBox] = []
    private(set) var region: NSRect = NSRect(x:0,y:0,width:1,height:1)
    private(set) var anchor: ScreenshotOCRPosition?
    private(set) var focus: ScreenshotOCRPosition?

    mutating func install(_ boxes:[ScreenshotOCRBox],region:NSRect) {
        self.boxes=boxes.sorted {
            let a=$0.rect,b=$1.rect
            // Vision's boxes are flipped to top-left origin.
            let sameRow=abs(a.midY-b.midY) < min(a.height,b.height)*0.45
            return sameRow ? a.minX<b.minX : a.midY<b.midY
        }
        self.region=region;anchor=nil;focus=nil
    }
    mutating func clear() {boxes=[];anchor=nil;focus=nil}
    mutating func deselect() {anchor=nil;focus=nil}
    mutating func selectAll() {
        guard let last=boxes.last else{deselect();return}
        anchor=ScreenshotOCRPosition(line:0,offset:0)
        focus=ScreenshotOCRPosition(line:boxes.count-1,offset:last.text.count)
    }
    var hasSelection:Bool {
        guard let anchor,let focus else{return false}
        return anchor != focus
    }
    func frame(for index:Int,in source:NSRect)->NSRect {
        let area=NSRect(x:source.minX+region.minX*source.width,
                        y:source.minY+region.minY*source.height,
                        width:region.width*source.width,height:region.height*source.height)
        let rect=boxes[index].rect
        return NSRect(x:area.minX+rect.minX*area.width,y:area.minY+rect.minY*area.height,
                      width:rect.width*area.width,height:rect.height*area.height)
    }
    func line(at point:NSPoint,in source:NSRect)->Int? {
        boxes.indices.first {frame(for:$0,in:source).insetBy(dx:-2,dy:-3).contains(point)}
    }
    private func proportions(for index:Int)->[CGFloat] {
        let graphemes=Array(boxes[index].text).map(String.init)
        guard !graphemes.isEmpty else{return [0]}
        // Shape-aware approximate hit testing, with the recognized bounding
        // box providing actual positions. Never alter the OCR's original text.
        let font=NSFont.systemFont(ofSize:18)
        let advances=graphemes.map {max(1,($0 as NSString).size(withAttributes:[.font:font]).width)}
        let total=advances.reduce(0,+)
        var result:[CGFloat]=[0],accumulated:CGFloat=0
        for advance in advances {accumulated+=advance;result.append(accumulated/total)}
        return result
    }
    func position(at point:NSPoint,in source:NSRect)->ScreenshotOCRPosition? {
        guard let index=line(at:point,in:source) else{return nil}
        let rect=frame(for:index,in:source),fractions=proportions(for:index)
        let fraction=max(0,min(1,(point.x-rect.minX)/max(1,rect.width)))
        let boundary=fractions.enumerated().min {
            abs($0.element-fraction)<abs($1.element-fraction)
        }?.offset ?? 0
        return ScreenshotOCRPosition(line:index,offset:boundary)
    }
    mutating func begin(at point:NSPoint,in source:NSRect)->Bool {
        guard let pos=position(at:point,in:source) else {deselect();return false}
        anchor=pos;focus=pos;return true
    }
    mutating func extend(to point:NSPoint,in source:NSRect) {
        guard anchor != nil,!boxes.isEmpty else{return}
        if let pos=position(at:point,in:source) {focus=pos;return}
        // Extending beyond the detected glyph rectangle reaches the closest
        // line, including its left or right end.
        let closest=boxes.indices.min {
            abs(frame(for:$0,in:source).midY-point.y) <
            abs(frame(for:$1,in:source).midY-point.y)
        }!
        let rect=frame(for:closest,in:source)
        focus=ScreenshotOCRPosition(line:closest,offset:point.x<rect.midX ? 0 : boxes[closest].text.count)
    }
    mutating func selectLine(_ index:Int) {
        guard boxes.indices.contains(index) else{return}
        anchor=ScreenshotOCRPosition(line:index,offset:0)
        focus=ScreenshotOCRPosition(line:index,offset:boxes[index].text.count)
    }
    mutating func selectParagraph(_ index:Int,in source:NSRect) {
        guard boxes.indices.contains(index) else{return}
        var start=index,end=index
        while start>0 && sameParagraph(start-1,start,in:source) {start-=1}
        while end+1<boxes.count && sameParagraph(end,end+1,in:source) {end+=1}
        anchor=ScreenshotOCRPosition(line:start,offset:0)
        focus=ScreenshotOCRPosition(line:end,offset:boxes[end].text.count)
    }
    private func sameParagraph(_ a:Int,_ b:Int,in source:NSRect)->Bool {
        let first=frame(for:a,in:source),second=frame(for:b,in:source)
        let gap=second.minY-first.maxY
        return gap >= -min(first.height,second.height)*0.4 &&
               gap <= max(first.height,second.height)*0.9 &&
               abs(first.minX-second.minX)<max(first.height,second.height)*1.5
    }
    mutating func selectWord(at point:NSPoint,in source:NSRect) {
        guard let pos=position(at:point,in:source) else{return}
        let graphemes=Array(boxes[pos.line].text)
        guard !graphemes.isEmpty else{return}
        let cursor=min(graphemes.count-1,max(0,pos.offset == graphemes.count ? pos.offset-1:pos.offset))
        func asciiWord(_ ch:Character)->Bool {
            ch.unicodeScalars.allSatisfy {CharacterSet.alphanumerics.contains($0) || $0=="_"}
        }
        var lo=cursor,hi=cursor+1
        if asciiWord(graphemes[cursor]) {
            while lo>0 && asciiWord(graphemes[lo-1]) {lo-=1}
            while hi<graphemes.count && asciiWord(graphemes[hi]) {hi+=1}
        }
        anchor=ScreenshotOCRPosition(line:pos.line,offset:lo)
        focus=ScreenshotOCRPosition(line:pos.line,offset:hi)
    }
    func selectedText()->String {
        guard let anchor,let focus,anchor != focus else{return ""}
        let start=min(anchor,focus),end=max(anchor,focus)
        guard boxes.indices.contains(start.line),boxes.indices.contains(end.line) else{return ""}
        return (start.line...end.line).compactMap { index in
            let chars=Array(boxes[index].text)
            let lo=index == start.line ? start.offset : 0
            let hi=index == end.line ? end.offset : chars.count
            return lo<hi ? String(chars[max(0,lo)..<min(chars.count,hi)]) : nil
        }.joined(separator:"\n")
    }
    func selectedRects(in source:NSRect)->[NSRect] {
        guard let anchor,let focus,anchor != focus else{return []}
        let start=min(anchor,focus),end=max(anchor,focus)
        guard boxes.indices.contains(start.line),boxes.indices.contains(end.line) else{return []}
        return (start.line...end.line).compactMap { index in
            let box=frame(for:index,in:source),proportions=proportions(for:index)
            let lo=index == start.line ? start.offset : 0
            let hi=index == end.line ? end.offset : proportions.count-1
            guard lo<hi,hi<proportions.count else{return nil}
            let x=box.minX+box.width*proportions[lo]
            return NSRect(x:x,y:box.minY,width:max(1,box.width*(proportions[hi]-proportions[lo])),height:box.height)
        }
    }
    func allText()->String {boxes.map(\.text).joined(separator:"\n")}
    func lineText(at point:NSPoint,in source:NSRect)->String? {
        line(at:point,in:source).map {boxes[$0].text}
    }
    func paragraphText(at point:NSPoint,in source:NSRect)->String? {
        guard let index=line(at:point,in:source) else{return nil}
        var copy=self;copy.selectParagraph(index,in:source)
        return copy.selectedText()
    }
}
