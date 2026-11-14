import AppKit

private enum TraditionalColorCatalog {
    private static let colors: [(name: String, lab: (Double, Double, Double))] = {
        guard let url = Bundle.module.url(forResource:"colors",withExtension:"tsv",subdirectory:"TraditionalColors"),
              let content = try? String(contentsOf:url,encoding:.utf8) else { return [] }
        return content.split(whereSeparator:\.isNewline).compactMap { line in
            let fields = line.split(separator:"\t",omittingEmptySubsequences:false)
            guard fields.count == 2, fields[1].hasPrefix("#"),
                  let value = UInt32(fields[1].dropFirst(),radix:16) else { return nil }
            let red = Double((value >> 16) & 0xFF)/255
            let green = Double((value >> 8) & 0xFF)/255
            let blue = Double(value & 0xFF)/255
            return (String(fields[0]),toLab(red,green,blue))
        }
    }()

    static func nearestName(to color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB), !colors.isEmpty else { return nil }
        let target = toLab(rgb.redComponent,rgb.greenComponent,rgb.blueComponent)
        return colors.min { lhs, rhs in
            distanceSquared(lhs.lab,target) < distanceSquared(rhs.lab,target)
        }?.name
    }

    private static func toLab(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124564*r + 0.3575761*g + 0.1804375*b)/0.95047
        let y = 0.2126729*r + 0.7151522*g + 0.0721750*b
        let z = (0.0193339*r + 0.1191920*g + 0.9503041*b)/1.08883
        func pivot(_ value: Double) -> Double {
            value > 0.0088564517 ? pow(value,1.0/3.0) : 7.787037*value + 16.0/116.0
        }
        let fx = pivot(x), fy = pivot(y), fz = pivot(z)
        return (116*fy-16,500*(fx-fy),200*(fy-fz))
    }

    private static func distanceSquared(_ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)) -> Double {
        let l = lhs.0-rhs.0, a = lhs.1-rhs.1, b = lhs.2-rhs.2
        return l*l+a*a+b*b
    }
}

/// A single frozen frame per display. Sampling never starts a continuous capture stream.
struct ScreenshotRaster {
    let image: CGImage
    private let pixels: [UInt8]
    init(_ image: CGImage) {
        self.image = image
        // Normalize wide-gamut/HDR/monochrome inputs once; pointer movement is an O(1) read.
        if let space = CGColorSpace(name:CGColorSpace.sRGB),
           let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) {
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            pixels = context.data.map { Array(UnsafeBufferPointer(start:$0.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4)) } ?? []
        } else { pixels = [] }
    }
    func pixel(at point: NSPoint, viewSize: NSSize) -> NSPoint {
        NSPoint(x:max(0,min(CGFloat(image.width-1),floor(point.x * CGFloat(image.width)/max(1,viewSize.width)))),
                y:max(0,min(CGFloat(image.height-1),floor(point.y * CGFloat(image.height)/max(1,viewSize.height)))))
    }
    func color(at point: NSPoint, viewSize: NSSize) -> NSColor? {
        let p = pixel(at:point,viewSize:viewSize)
        return colorAtPixel(x:Int(p.x),y:Int(p.y))
    }
    func colorAtPixel(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = (y*image.width+x)*4
        guard offset+3 < pixels.count else { return nil }
        let alpha = max(1,Int(pixels[offset+3]))
        return NSColor(srgbRed:CGFloat(pixels[offset])/CGFloat(alpha),green:CGFloat(pixels[offset+1])/CGFloat(alpha),blue:CGFloat(pixels[offset+2])/CGFloat(alpha),alpha:CGFloat(pixels[offset+3])/255)
    }
    func drawMagnifier(center: NSPoint, in rect: NSRect) {
        // Keep each sampled pixel at its existing size; use a smaller 7×7 sample window.
        let radius = 3, side = CGFloat(20), size = side*CGFloat(radius*2+1)
        let origin = NSPoint(x:rect.midX-size/2,y:rect.midY-size/2)
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = max(0,min(image.width-1,Int(center.x)+dx))
                let y = max(0,min(image.height-1,Int(center.y)+dy))
                guard let color = colorAtPixel(x:x,y:y) else { continue }
                let cell = NSRect(x:origin.x+CGFloat(dx+radius)*side,y:origin.y+CGFloat(dy+radius)*side,width:side,height:side)
                color.setFill(); NSBezierPath(rect:cell).fill()
                NSColor.black.withAlphaComponent(0.38).setStroke()
                let grid = NSBezierPath(rect:cell.insetBy(dx:0.25,dy:0.25)); grid.lineWidth = 0.5; grid.stroke()
            }
        }
        let centerCell = NSRect(x:rect.midX-side/2,y:rect.midY-side/2,width:side,height:side)
        NSColor.systemCyan.setStroke(); let outline = NSBezierPath(rect:centerCell.insetBy(dx:1,dy:1)); outline.lineWidth = 2; outline.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke(); let frame = NSBezierPath(rect:NSRect(x:origin.x,y:origin.y,width:size,height:size).insetBy(dx:0.5,dy:0.5)); frame.lineWidth = 1; frame.stroke()
    }
    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "—" }
        return String(format:"#%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
    }
    static func colorName(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "未知颜色" }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maximum = max(r,g,b), minimum = min(r,g,b), lightness = (maximum+minimum)/2
        let delta = maximum-minimum
        if delta < 0.085 {
            if lightness < 0.12 { return "黑色" }
            if lightness < 0.32 { return "深灰色" }
            if lightness > 0.9 { return "白色" }
            if lightness > 0.72 { return "浅灰色" }
            return "灰色"
        }
        let saturation = delta / max(0.0001,1-abs(2*lightness-1))
        var hue: CGFloat
        if maximum == r { hue = 60 * ((g-b)/delta).truncatingRemainder(dividingBy:6) }
        else if maximum == g { hue = 60 * ((b-r)/delta+2) }
        else { hue = 60 * ((r-g)/delta+4) }
        if hue < 0 { hue += 360 }
        let base: String
        switch hue {
        case 15..<45: base = "橙色"
        case 45..<70: base = "黄色"
        case 70..<155: base = "绿色"
        case 155..<195: base = "青色"
        case 195..<255: base = "蓝色"
        case 255..<290: base = "紫色"
        case 290..<335: base = "品红色"
        default: base = (hue >= 335 || hue < 15) && lightness < 0.34 && saturation > 0.4 ? "酒红色" : "红色"
        }
        if lightness < 0.2 { return "深"+base }
        if lightness > 0.78 { return "浅"+base }
        return base
    }
    func crop(_ rect: NSRect, viewSize: NSSize) -> CGImage? {
        let clipped = rect.standardized.intersection(NSRect(origin:.zero,size:viewSize))
        guard !clipped.isNull,clipped.width>=1,clipped.height>=1 else { return nil }
        let sx = CGFloat(image.width)/max(1,viewSize.width), sy = CGFloat(image.height)/max(1,viewSize.height)
        let pixels = CGRect(x:floor(clipped.minX*sx),y:floor(clipped.minY*sy),width:ceil(clipped.maxX*sx)-floor(clipped.minX*sx),height:ceil(clipped.maxY*sy)-floor(clipped.minY*sy))
        return image.cropping(to:pixels)
    }
}

private final class ScreenshotSelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown || (event.type == .keyDown && event.keyCode == 53) {onCancel?();return}
        super.sendEvent(event)
    }
}

final class ScreenshotRegionPicker {
    private var panels: [NSPanel] = []
    private var pinned: [ScreenshotPinnedWindow] = []
    private(set) var outputAction = "configured"
    private var completion: ((CGImage?) -> Void)?
    var active: Bool { !panels.isEmpty }
    func start(frames: [(NSRect,CGImage)], onLongCapture: ((CGRect,CGImage)->Void)? = nil, completion: @escaping (CGImage?) -> Void) {
        dismiss(); self.completion = completion;outputAction="configured"
        for (frame,image) in frames {
            let panel = ScreenshotSelectionPanel(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
            panel.level = .screenSaver; panel.isOpaque = true; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let view = ScreenshotSelectionView(frame:NSRect(origin:.zero,size:frame.size),image:image)
            view.onFinish = { [weak self] image in self?.finish(image) }
            view.onEditorAction = {[weak self] action in self?.outputAction=action}
            view.onLongCapture = {[weak self] selection,image in
                guard let self,let onLongCapture else{return}
                let screenRect=CGRect(x:frame.minX+selection.minX,
                                      y:frame.maxY-selection.maxY,
                                      width:selection.width,height:selection.height)
                self.dismiss()
                onLongCapture(screenRect,image)
            }
            view.onPin = {[weak self] image,selection in
                guard let self else{return}
                let rect=NSRect(x:frame.minX+selection.minX,y:frame.maxY-selection.maxY,width:selection.width,height:selection.height)
                let window=ScreenshotPinnedWindow(image:image,frame:rect)
                window.onClosed={[weak self,weak window] in self?.pinned.removeAll{$0 === window}}
                self.pinned.append(window);window.orderFrontRegardless()
            }
            panel.onCancel = {[weak self] in self?.finish(nil)}
            panel.contentView = view; panel.acceptsMouseMovedEvents = true; panels.append(panel)
            panel.orderFrontRegardless(); panel.makeFirstResponder(view); view.preparePixelSampling()
        }
        NSApp.activate(ignoringOtherApps:true)
        if let panel = panels.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? panels.first { panel.makeKey() }
        if panels.isEmpty { finish(nil) }
    }
    func dismiss() {
        NSColorPanel.shared.orderOut(nil);NSColorPanel.shared.level = .floating
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); completion = nil
    }
    func cancel() { finish(nil) }
    private func finish(_ image: CGImage?) { let callback = completion; dismiss(); callback?(image) }
}

final class ScreenshotSelectionView: NSView {
    var onFinish: ((CGImage?) -> Void)?
    var onEditorAction: ((String) -> Void)?
    var onPin: ((CGImage,NSRect) -> Void)?
    var onLongCapture: ((NSRect,CGImage) -> Void)?
    private var raster: ScreenshotRaster?
    private let image: CGImage
    private let background: NSImage
    private var cursor = NSPoint.zero, anchor: NSPoint?
    private var editorIsActive = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: NSRect, image: CGImage) {
        self.image = image; background = NSImage(cgImage:image,size:frame.size)
        super.init(frame:frame)
    }
    required init?(coder: NSCoder) { nil }
    func preparePixelSampling() {
        let image = image
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let raster = ScreenshotRaster(image)
            DispatchQueue.main.async { self?.raster = raster; self?.needsDisplay = true }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { cursor = convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect:bounds,options:[.activeAlways,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        tracking = next; addTrackingArea(next)
    }
    override func resetCursorRects() {
        guard !editorIsActive else { return }
        addCursorRect(bounds,cursor:.crosshair)
    }
    private func move(_ event: NSEvent) { cursor = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); move(event) }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) { move(event); anchor = cursor }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func mouseUp(with event: NSEvent) {
        move(event); guard let anchor else { return }
        let rect = NSRect(x:min(anchor.x,cursor.x),y:min(anchor.y,cursor.y),width:abs(anchor.x-cursor.x),height:abs(anchor.y-cursor.y))
        if rect.width>=2,rect.height>=2 {
            let editor=ScreenshotEditingView(frame:bounds,image:image,selection:rect)
            editor.onFinish = {[weak self] image,action in self?.onEditorAction?(action);self?.onFinish?(image)}
            editor.onPin = {[weak self] image,selection in self?.onPin?(image,selection)}
            editor.onLongCapture = {[weak self] selection,image in self?.onLongCapture?(selection,image)}
            editorIsActive=true;addSubview(editor);window?.invalidateCursorRects(for:self);NSCursor.arrow.set();window?.makeFirstResponder(editor);self.anchor=nil
        }
        else { self.anchor = nil; needsDisplay = true }
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }
    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }
        else if event.keyCode == 8, let color = raster?.color(at:cursor,viewSize:bounds.size) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ScreenshotRaster.hex(color),forType:.string)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        background.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        NSColor.black.withAlphaComponent(0.22).setFill()
        if let anchor {
            let selected = NSRect(x:min(anchor.x,cursor.x),y:min(anchor.y,cursor.y),width:abs(anchor.x-cursor.x),height:abs(anchor.y-cursor.y))
            let shade = NSBezierPath(rect:bounds); shade.append(NSBezierPath(rect:selected)); shade.windingRule = .evenOdd; shade.fill()
            NSColor.white.setStroke(); let outline = NSBezierPath(rect:selected); outline.lineWidth = 1; outline.stroke()
        } else { bounds.fill() }
        // Full-display guides make the sampled pixel easy to align while staying out of the captured crop.
        let crosshair = NSBezierPath()
        crosshair.move(to:NSPoint(x:0,y:cursor.y)); crosshair.line(to:NSPoint(x:bounds.maxX,y:cursor.y))
        crosshair.move(to:NSPoint(x:cursor.x,y:0)); crosshair.line(to:NSPoint(x:cursor.x,y:bounds.maxY))
        crosshair.lineWidth = 2
        NSColor.black.withAlphaComponent(0.72).setStroke(); crosshair.stroke()
        crosshair.lineWidth = 1
        NSColor.white.withAlphaComponent(0.92).setStroke(); crosshair.stroke()
        guard let raster else {
            ("正在准备取色…" as NSString).draw(at:NSPoint(x:cursor.x+18,y:cursor.y+18),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white])
            return
        }
        let color = raster.color(at:cursor,viewSize:bounds.size) ?? .black
        let hex = ScreenshotRaster.hex(color), c = color.usingColorSpace(.sRGB) ?? .black
        let rgb = "RGB \(Int((c.redComponent*255).rounded())), \(Int((c.greenComponent*255).rounded())), \(Int((c.blueComponent*255).rounded()))"
        var details = "拖动框选 · C 拷贝色值 · Esc 取消"
        if let anchor {
            let sx = CGFloat(raster.image.width)/bounds.width, sy = CGFloat(raster.image.height)/bounds.height
            details = "\(Int(abs(cursor.x-anchor.x)*sx)) × \(Int(abs(cursor.y-anchor.y)*sy)) px · 松开截取"
        }
        let magnifierSide: CGFloat = 140
        let hintHeight: CGFloat = 0
        let gap: CGFloat = 0
        let boxWidth = magnifierSide
        let boxHeight = magnifierSide+gap+hintHeight
        let x = cursor.x+24+boxWidth <= bounds.maxX ? cursor.x+24 : cursor.x-boxWidth-24
        let y = cursor.y+24+boxHeight <= bounds.maxY ? cursor.y+24 : cursor.y-boxHeight-24
        let box = NSRect(x:max(4,min(x,bounds.maxX-boxWidth-4)),y:max(4,min(y,bounds.maxY-boxHeight-4)),width:boxWidth,height:boxHeight)
        let magnifier = NSRect(x:box.minX,y:box.minY+hintHeight+gap,width:magnifierSide,height:magnifierSide)
        raster.drawMagnifier(center:raster.pixel(at:cursor,viewSize:bounds.size),in:magnifier)
        let pixel = raster.pixel(at:cursor,viewSize:bounds.size)
        let name = TraditionalColorCatalog.nearestName(to:color).map { "近似传统色 · \($0)" } ?? ScreenshotRaster.colorName(color)
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        textShadow.shadowBlurRadius = 2
        textShadow.shadowOffset = NSSize(width:0,height:-1)
        let titleStyle: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:8,weight:.semibold),.foregroundColor:NSColor.white,.shadow:textShadow]
        let valueStyle: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:6.8,weight:.medium),.foregroundColor:NSColor.white,.shadow:textShadow]
        // NSString drawing includes font-specific vertical inset; use a small top
        // origin so the visible glyph edge matches the action hint's ~3 pt bottom gap.
        let lensTopTextInset: CGFloat = 2
        let lensTextRowSpacing: CGFloat = 12
        // Place color details and the concise action hint inside the lens. The hint sits
        // at the square's lower-left corner; it has no backing fill or border.
        (name as NSString).draw(at:NSPoint(x:magnifier.minX+5,y:magnifier.minY+lensTopTextInset+2*lensTextRowSpacing),withAttributes:titleStyle)
        ("\(Int(pixel.x)), \(Int(pixel.y)) px" as NSString).draw(at:NSPoint(x:magnifier.minX+5,y:magnifier.minY+lensTopTextInset+lensTextRowSpacing),withAttributes:valueStyle)
        ("\(hex)  \(rgb)" as NSString).draw(at:NSPoint(x:magnifier.minX+5,y:magnifier.minY+lensTopTextInset),withAttributes:valueStyle)
        let hintFont = NSFont.systemFont(ofSize:7,weight:.medium)
        (details as NSString).draw(at:NSPoint(x:magnifier.minX+3,y:magnifier.maxY-11),withAttributes:[.font:hintFont,.foregroundColor:NSColor.white.withAlphaComponent(0.92),.shadow:textShadow])
    }
}
