import AppKit
import CoreImage
import Vision

enum ScreenshotEditTool: String, CaseIterable {
    case select, rectangle, ellipse, line, arrow, pen, mask, text, number, highlight
}
enum ScreenshotPaintMode: String, CaseIterable {
    case solid, gaussian, frosted, mosaic
    var title: String { switch self { case .solid:return "纯色";case .gaussian:return "高斯模糊";case .frosted:return "毛玻璃";case .mosaic:return "马赛克" } }
}

struct ScreenshotArrowGeometry {
    let tip: NSPoint
    let shaftEnd: NSPoint
    let leftBase: NSPoint
    let rightBase: NSPoint

    init(start: NSPoint, end: NSPoint, width: CGFloat) {
        let dx=end.x-start.x, dy=end.y-start.y
        let distance=max(1,hypot(dx,dy)), ux=dx/distance, uy=dy/distance
        let headLength=min(distance*0.65,max(10,width*3.2))
        let halfWidth=max(width*1.3,headLength*0.32)
        let base=NSPoint(x:end.x-ux*headLength,y:end.y-uy*headLength)
        let perpendicular=NSPoint(x:-uy*halfWidth,y:ux*halfWidth)
        tip=end
        shaftEnd=base
        leftBase=NSPoint(x:base.x+perpendicular.x,y:base.y+perpendicular.y)
        rightBase=NSPoint(x:base.x-perpendicular.x,y:base.y-perpendicular.y)
    }
}
struct ScreenshotAnnotation {
    var id = UUID()
    var tool: ScreenshotEditTool
    var start: NSPoint
    var end: NSPoint
    var points: [NSPoint] = []
    var color = NSColor.systemRed
    var opacity: CGFloat = 1
    var width: CGFloat = 2
    var isFilled = false
    var hasRoundedCorners = false
    var cornerRadius: CGFloat = 15
    var numberSize: CGFloat = 20
    var numberColor = NSColor.systemRed
    var mode = ScreenshotPaintMode.solid
    var text = ""
    var fontName = ""
    var fontSize: CGFloat = 20
    var bold = false, italic = false, underline = false, background = false
    var textShadow = false
    var textOutline = false, textOutlineCustom = false
    var textOutlineColor = NSColor.black
    var backgroundColor = NSColor.white
    var number = 1
    var labelSize = NSSize(width:160,height:42)
    var textBoxWidthIsUserSet = false
    var rect: NSRect { NSRect(x:min(start.x,end.x),y:min(start.y,end.y),width:max(1,abs(end.x-start.x)),height:max(1,abs(end.y-start.y))) }
    var textRect: NSRect { tool == .number ? NSRect(origin:end,size:labelSize) : rect }
    var font: NSFont {
        var result = NSFont(name:fontName,size:fontSize) ?? .systemFont(ofSize:fontSize)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }; if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { result = NSFontManager.shared.convert(result,toHaveTrait:traits) }
        return result
    }
    var textAttributes: [NSAttributedString.Key:Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        var values: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:color,.paragraphStyle:paragraph]
        if underline { values[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return values
    }
    mutating func translate(_ delta: NSPoint) {
        start.x += delta.x; start.y += delta.y; end.x += delta.x; end.y += delta.y
        points = points.map { NSPoint(x:$0.x+delta.x,y:$0.y+delta.y) }
    }
    mutating func scaleGeometry(by factor:CGFloat) {
        width *= factor;cornerRadius *= factor;numberSize *= factor;fontSize *= factor
        labelSize=NSSize(width:labelSize.width*factor,height:labelSize.height*factor)
    }
    func transformed(from old:NSRect,to new:NSRect) -> ScreenshotAnnotation {
        let ratio=new.width/old.width
        func convert(_ p:NSPoint)->NSPoint {
            NSPoint(x:new.minX+(p.x-old.minX)*ratio,y:new.minY+(p.y-old.minY)*ratio)
        }
        var result=self
        result.start=convert(start);result.end=convert(end);result.points=points.map(convert)
        result.scaleGeometry(by:ratio)
        return result
    }
    func contains(_ point: NSPoint) -> Bool {
        if tool == .number { return textRect.insetBy(dx:-8,dy:-8).contains(point) || hypot(point.x-start.x,point.y-start.y) <= max(1,numberSize*0.7)+7 }
        if tool == .line || tool == .arrow {
            let dx=end.x-start.x,dy=end.y-start.y, length=dx*dx+dy*dy
            let t=length>0 ? max(0,min(1,((point.x-start.x)*dx+(point.y-start.y)*dy)/length)) : 0
            return hypot(point.x-start.x-t*dx,point.y-start.y-t*dy)<max(6,width)
        }
        if tool == .pen { return points.contains { hypot(point.x-$0.x,point.y-$0.y)<max(6,width/2) } }
        if tool == .rectangle || tool == .ellipse {
            let threshold=max(7,width+4)
            if tool == .ellipse {
                let rx=max(1,rect.width/2),ry=max(1,rect.height/2),dx=(point.x-rect.midX)/rx,dy=(point.y-rect.midY)/ry
                let normalized=sqrt(dx*dx+dy*dy),distance=abs(normalized-1)*min(rx,ry)
                return isFilled ? normalized <= 1+threshold/min(rx,ry) : distance <= threshold
            }
            guard rect.insetBy(dx:-threshold,dy:-threshold).contains(point) else{return false}
            return isFilled || !rect.insetBy(dx:threshold,dy:threshold).contains(point)
        }
        return rect.insetBy(dx:-8,dy:-8).contains(point)
    }
}
struct ScreenshotOCRBox { let text: String; let rect: NSRect }
struct ScreenshotEditSnapshot {
    var selection: NSRect
    var annotations: [ScreenshotAnnotation]
    var cornerRadius: CGFloat
    var shadow: Bool
    var sourceOrigin: NSPoint = .zero
    var sourceSize: NSSize = .zero
}
final class ScreenshotEffectCache {
    private let images=NSCache<NSString,NSImage>()
    init() {images.countLimit=8;images.totalCostLimit=128*1024*1024}
    func image(for key:String)->NSImage? {images.object(forKey:key as NSString)}
    func insert(_ image:NSImage,for key:String,cost:Int) {images.setObject(image,forKey:key as NSString,cost:max(1,cost))}
}
enum ScreenshotEditPreferences {
    private static let radiusKey = "screenshotEditor.cornerRadiusPixels"
    private static let shadowKey = "screenshotEditor.shadowEnabled"
    static func restore(defaults: UserDefaults = .standard) -> (radiusPixels: CGFloat, shadow: Bool) {
        let radius = defaults.object(forKey: radiusKey) as? Double ?? 0
        let shadow = defaults.object(forKey: shadowKey) as? Bool ?? false
        return (max(0, min(1000, CGFloat(radius))), shadow)
    }
    static func save(radiusPixels: CGFloat, shadow: Bool, defaults: UserDefaults = .standard) {
        defaults.set(Double(max(0, min(1000, radiusPixels))), forKey: radiusKey)
        defaults.set(shadow, forKey: shadowKey)
    }
}
final class ScreenshotEditDocument {
    static let selectionShadowBlurRadius: CGFloat = 10
    static let selectionShadowOffset: CGFloat = 3
    static let selectionShadowPadding: CGFloat = 6
    let raster: ScreenshotRaster
    let viewSize: NSSize
    /// The rectangle occupied by the source image within the editing canvas.
    /// A screenshot-page editor can have a full-screen canvas without stretching
    /// the original screenshot to fill that canvas.
    var sourceRect: NSRect
    let effectCache: ScreenshotEffectCache
    var selection: NSRect
    var annotations: [ScreenshotAnnotation] = []
    var cornerRadius: CGFloat = 0
    var shadow = false
    private var history: [ScreenshotEditSnapshot] = []
    private let filterContext = CIContext(options:[.cacheIntermediates:false])
    init(image: CGImage, viewSize: NSSize, selection: NSRect, sourceRect: NSRect? = nil) {
        raster = ScreenshotRaster(image); self.viewSize=viewSize; self.selection=selection
        self.sourceRect = sourceRect ?? NSRect(origin:.zero,size:viewSize)
        effectCache=ScreenshotEffectCache()
    }
    init(raster: ScreenshotRaster, viewSize: NSSize, selection: NSRect,sourceRect: NSRect? = nil,effectCache:ScreenshotEffectCache = ScreenshotEffectCache()) {
        self.raster=raster;self.viewSize=viewSize;self.selection=selection
        self.sourceRect=sourceRect ?? NSRect(origin:.zero,size:viewSize)
        self.effectCache=effectCache
    }
    var pixelSize: NSSize { NSSize(width:(selection.width*CGFloat(raster.image.width)/sourceRect.width).rounded(),height:(selection.height*CGFloat(raster.image.height)/sourceRect.height).rounded()) }
    var canUndo: Bool { !history.isEmpty }
    func checkpoint() {
        history.append(ScreenshotEditSnapshot(selection:selection,annotations:annotations,cornerRadius:cornerRadius,shadow:shadow,sourceOrigin:sourceRect.origin,sourceSize:sourceRect.size))
        if history.count>200 { history.removeFirst() }
    }
    func undo() {
        guard let last=history.popLast() else{return}
        let previous=NSRect(origin:last.sourceOrigin,size:last.sourceSize == .zero ? sourceRect.size:last.sourceSize)
        selection=Self.convert(last.selection,from:previous,to:sourceRect)
        annotations=last.annotations.map {$0.transformed(from:previous,to:sourceRect)}
        cornerRadius=last.cornerRadius*sourceRect.width/previous.width;shadow=last.shadow
    }
    static func convert(_ rect:NSRect,from old:NSRect,to new:NSRect)->NSRect {
        let ratio=new.width/old.width
        return NSRect(x:new.minX+(rect.minX-old.minX)*ratio,
                      y:new.minY+(rect.minY-old.minY)*ratio,
                      width:rect.width*ratio,height:rect.height*ratio)
    }
    /// Changes only the on-screen viewport. Original raster pixels are untouched.
    /// Existing annotations and crop boundaries transform in the same coordinate space.
    func setSourceFrame(_ frame:NSRect) {
        guard frame.width>0,frame.height>0 else{return}
        let old=sourceRect
        selection=Self.convert(selection,from:old,to:frame)
        annotations=annotations.map {$0.transformed(from:old,to:frame)}
        cornerRadius *= frame.width/old.width
        sourceRect=frame
    }
    /// Panning changes only the editing canvas position, not image contents.
    /// Snapshots record their canvas origin so undo can translate lazily.
    func panCanvas(by delta: NSPoint) {
        sourceRect=sourceRect.offsetBy(dx:delta.x,dy:delta.y)
        selection=selection.offsetBy(dx:delta.x,dy:delta.y)
        annotations=annotations.map { var item=$0;item.translate(delta);return item }
    }
    func clampSelection(_ rect: NSRect) -> NSRect {
        let width=max(2,min(sourceRect.width,rect.width)),height=max(2,min(sourceRect.height,rect.height))
        return NSRect(x:max(sourceRect.minX,min(sourceRect.maxX-width,rect.minX)),
                      y:max(sourceRect.minY,min(sourceRect.maxY-height,rect.minY)),width:width,height:height)
    }
    /// Draw in display-point coordinates; the output context scales once to source pixels.
    func render(includeShadow: Bool = true) -> CGImage? {
        render(includeShadow: includeShadow, includeBase: true)
    }

    /// Render only marks onto a transparent crop-sized layer. The frozen screenshot stays
    /// in the window's native drawing path, avoiding a second color conversion/resampling.
    func renderOverlay() -> CGImage? {
        guard !annotations.isEmpty else { return nil }
        return render(includeShadow: false, includeBase: false)
    }

    private func render(includeShadow: Bool, includeBase: Bool) -> CGImage? {
        let imageSelection=selection.offsetBy(dx:-sourceRect.minX,dy:-sourceRect.minY)
        guard let cropped=raster.crop(imageSelection,viewSize:sourceRect.size) else { return nil }
        // Preserve the captured pixels exactly when no editing operation needs a compositor.
        if includeBase && annotations.isEmpty && (!includeShadow || !shadow) && cornerRadius <= 0 { return cropped }
        let sx=CGFloat(cropped.width)/selection.width, sy=CGFloat(cropped.height)/selection.height
        let pad = includeBase && includeShadow && shadow ? Self.selectionShadowPadding : 0
        let width=Int(ceil((selection.width+2*pad)*sx)),height=Int(ceil((selection.height+2*pad)*sy))
        guard width>0,height>0,Double(width)*Double(height)<=100_000_000,
              let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:sx,y:-sy)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
        defer {NSGraphicsContext.restoreGraphicsState()}
        let output=NSRect(x:pad,y:pad,width:selection.width,height:selection.height)
        let rounded=NSBezierPath(roundedRect:output,xRadius:min(cornerRadius,selection.width/2),yRadius:min(cornerRadius,selection.height/2))
        if pad>0 {
            NSGraphicsContext.saveGraphicsState()
            let shade=NSShadow();shade.shadowColor=NSColor.black.withAlphaComponent(0.5);shade.shadowBlurRadius=Self.selectionShadowBlurRadius;shade.shadowOffset=NSSize(width:0,height:-Self.selectionShadowOffset);shade.set()
            NSColor.black.setFill();rounded.fill();NSGraphicsContext.restoreGraphicsState()
        }
        if includeBase {
            rounded.addClip()
            let base=NSImage(cgImage:cropped,size:output.size)
            base.draw(in:output,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        } else {
            NSBezierPath(rect:output).addClip()
        }
        context.translateBy(x:pad-selection.minX,y:pad-selection.minY)
        func effect(_ mode: ScreenshotPaintMode, width: CGFloat) -> NSImage {
            let key="\(Int((imageSelection.minX*CGFloat(raster.image.width)/sourceRect.width).rounded())):\(Int((imageSelection.minY*CGFloat(raster.image.height)/sourceRect.height).rounded())):\(cropped.width)x\(cropped.height):\(Int((width*sx*1000).rounded())):\(mode.rawValue)"
            if let cached=effectCache.image(for:key) { return cached }
            let original=CIImage(cgImage:cropped),extent=original.extent
            var result=original
            if mode == .mosaic { result=original.applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:max(6,width*sx)]) }
            else { result=original.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(8,width*sx/2)]).cropped(to:extent) }
            if mode == .frosted { result=result.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0.55,kCIInputContrastKey:0.85,kCIInputBrightnessKey:0.08]) }
            let image=filterContext.createCGImage(result,from:extent) ?? cropped
            let display=NSImage(cgImage:image,size:selection.size)
            effectCache.insert(display,for:key,cost:image.width*image.height*4)
            return display
        }
        for item in annotations {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let annotationColor=item.color.withAlphaComponent(item.color.alphaComponent*max(0,min(1,item.opacity)))
            annotationColor.setStroke();annotationColor.setFill()
            let shape=NSBezierPath();shape.lineWidth=item.width;shape.lineCapStyle = .round;shape.lineJoinStyle = .round
            switch item.tool {
            case .rectangle:
                let radius=item.hasRoundedCorners ? min(item.cornerRadius,min(item.rect.width,item.rect.height)/2) : 0
                let path=NSBezierPath(roundedRect:item.rect,xRadius:radius,yRadius:radius)
                path.lineWidth=item.width;path.lineJoinStyle = .round
                if item.isFilled {path.fill()}
                path.stroke()
            case .ellipse:
                let path=NSBezierPath(ovalIn:item.rect);path.lineWidth=item.width
                if item.isFilled {path.fill()}
                path.stroke()
            case .line,.arrow:
                if item.tool == .arrow {
                    let arrow=ScreenshotArrowGeometry(start:item.start,end:item.end,width:item.width)
                    shape.move(to:item.start);shape.line(to:arrow.shaftEnd);shape.stroke()
                    let head=NSBezierPath();head.move(to:arrow.tip);head.line(to:arrow.leftBase);head.line(to:arrow.rightBase);head.close();head.fill()
                } else {shape.move(to:item.start);shape.line(to:item.end);shape.stroke()}
            case .pen:
                guard let first=item.points.first else {continue}
                let path=CGMutablePath();path.move(to:first)
                for point in item.points.dropFirst() {path.addLine(to:point)}
                if item.points.count == 1 {path.addLine(to:NSPoint(x:first.x+0.01,y:first.y))}
                if item.mode == .solid { context.addPath(path);context.setStrokeColor(annotationColor.cgColor);context.setLineWidth(item.width);context.setLineCap(.round);context.setLineJoin(.round);context.strokePath() }
                else {
                    context.addPath(path);context.setLineWidth(item.width);context.setLineCap(.round);context.setLineJoin(.round);context.replacePathWithStrokedPath();context.clip()
                    effect(item.mode,width:item.width).draw(in:selection,from:.zero,operation:.sourceOver,fraction:item.opacity,respectFlipped:true,hints:nil)
                }
            case .mask:
                NSBezierPath(rect:item.rect).addClip()
                if item.mode == .solid {
                    annotationColor.setFill();NSBezierPath(rect:item.rect).fill()
                } else {
                    effect(item.mode,width:item.width).draw(in:selection,from:.zero,operation:.sourceOver,fraction:item.opacity,respectFlipped:true,hints:nil)
                }
            case .text:
                if item.background {
                    item.backgroundColor.withAlphaComponent(item.backgroundColor.alphaComponent*item.opacity).setFill()
                    let radius=item.hasRoundedCorners ? min(item.cornerRadius,min(item.textRect.width,item.textRect.height)/2) : 0
                    NSBezierPath(roundedRect:item.textRect,xRadius:radius,yRadius:radius).fill()
                }
                var attributes=item.textAttributes;attributes[.foregroundColor]=annotationColor
                if item.textShadow {let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.7);shadow.shadowBlurRadius=2;shadow.shadowOffset=NSSize(width:0,height:-1);attributes[.shadow]=shadow}
                if item.textOutline {let stroke=item.textOutlineCustom ? item.textOutlineColor : automaticTextOutline(for:item.color);attributes[.strokeColor]=stroke.withAlphaComponent(stroke.alphaComponent*item.opacity);attributes[.strokeWidth] = -5.0}
                NSAttributedString(string:item.text,attributes:attributes).draw(with:item.textRect.insetBy(dx:6,dy:4),options:[.usesLineFragmentOrigin,.usesFontLeading])
            case .number:
                let radius=max(1,item.numberSize*0.7),label=item.textRect
                let destination=NSPoint(x:max(label.minX,min(label.maxX,item.start.x)),y:max(label.minY,min(label.maxY,item.start.y)))
                let markerColor=item.numberColor.withAlphaComponent(item.numberColor.alphaComponent*item.opacity)
                markerColor.setStroke();shape.move(to:item.start);shape.line(to:destination);shape.stroke()
                markerColor.setFill();NSBezierPath(ovalIn:NSRect(x:item.start.x-radius,y:item.start.y-radius,width:radius*2,height:radius*2)).fill()
                let number="\(item.number)" as NSString,attributes: [NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:item.numberSize,weight:.semibold),.foregroundColor:automaticTextOutline(for:item.numberColor).withAlphaComponent(item.opacity)]
                let size=number.size(withAttributes:attributes);number.draw(at:NSPoint(x:item.start.x-size.width/2,y:item.start.y-size.height/2),withAttributes:attributes)
                let labelRadius=item.hasRoundedCorners ? min(item.cornerRadius,min(label.width,label.height)/2) : 0
                let labelPath=NSBezierPath(roundedRect:label,xRadius:labelRadius,yRadius:labelRadius)
                if item.background { item.backgroundColor.withAlphaComponent(item.backgroundColor.alphaComponent*item.opacity).setFill();labelPath.fill() }
                annotationColor.setStroke();labelPath.withWidth(item.width).stroke()
                var labelAttributes=item.textAttributes;labelAttributes[.foregroundColor]=annotationColor
                if item.textShadow {let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.7);shadow.shadowBlurRadius=2;shadow.shadowOffset=NSSize(width:0,height:-1);labelAttributes[.shadow]=shadow}
                if item.textOutline {let stroke=item.textOutlineCustom ? item.textOutlineColor : automaticTextOutline(for:item.color);labelAttributes[.strokeColor]=stroke.withAlphaComponent(stroke.alphaComponent*item.opacity);labelAttributes[.strokeWidth] = -5.0}
                NSAttributedString(string:item.text,attributes:labelAttributes).draw(with:label.insetBy(dx:6,dy:4),options:[.usesLineFragmentOrigin,.usesFontLeading])
            case .highlight:
                let radius=item.hasRoundedCorners ? min(item.cornerRadius,min(item.rect.width,item.rect.height)/2) : 0
                let shade=NSBezierPath(rect:selection);shade.append(NSBezierPath(roundedRect:item.rect,xRadius:radius,yRadius:radius));shade.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55*max(0,min(1,item.opacity))).setFill();shade.fill()
            case .select: break
            }
        }
        return context.makeImage()
    }
    private func automaticTextOutline(for color:NSColor)->NSColor {
        let rgb=color.usingColorSpace(.sRGB) ?? color
        let luminance=0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent
        return luminance>0.45 ? .black:.white
    }
    static func recognize(_ image: CGImage) throws -> [ScreenshotOCRBox] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true;request.automaticallyDetectsLanguage=true
        let supported=try request.supportedRecognitionLanguages();request.recognitionLanguages=["zh-Hans","zh-Hant","en-US"].filter{supported.contains($0)}
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text=observation.topCandidates(1).first?.string else{return nil}
            let box=observation.boundingBox
            return ScreenshotOCRBox(text:text,rect:NSRect(x:box.minX,y:1-box.maxY,width:box.width,height:box.height))
        }
    }
}
private extension NSBezierPath {
    func withWidth(_ width: CGFloat) -> NSBezierPath { lineWidth=width;return self }
}
