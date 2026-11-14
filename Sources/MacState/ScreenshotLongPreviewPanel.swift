import AppKit

/// Prefer showing the stitched result to the left of the live capture region.
/// Never place the preview over the capture rectangle when there is room on
/// the current or another display.
enum ScreenshotLongPreviewLayout {
    enum Position { case left, right, above, below, otherDisplay, overlapping }
    struct Placement {
        var frame: CGRect
        var position: Position
    }

    static func place(selection: CGRect, screens: [CGRect]) -> Placement {
        let margin:CGFloat=12, gap:CGFloat=18
        let selectedScreen=screens.first { $0.intersects(selection) } ??
            screens.first ?? CGRect(x:0,y:0,width:1200,height:800)
        let screen=selectedScreen.insetBy(dx:margin,dy:margin)
        let desiredWidth:CGFloat=min(430,max(295,selection.width*0.7))
        let desiredHeight:CGFloat=min(750,max(390,selection.height*1.16))
        let height=min(desiredHeight,screen.height)
        let y=min(max(screen.minY,selection.maxY-height),screen.maxY-height)
        let leftWidth=selection.minX-gap-screen.minX
        if leftWidth >= 245 {
            let width=min(desiredWidth,leftWidth)
            return Placement(frame:CGRect(x:selection.minX-gap-width,y:y,width:width,height:height),position:.left)
        }
        let rightX=selection.maxX+gap
        let rightWidth=screen.maxX-rightX
        if rightWidth >= 245 {
            let width=min(desiredWidth,rightWidth)
            return Placement(frame:CGRect(x:rightX,y:y,width:width,height:height),position:.right)
        }
        // Keep the capture region entirely free even on narrow displays.
        let belowHeight=selection.minY-gap-screen.minY
        let aboveY=selection.maxY+gap
        let aboveHeight=screen.maxY-aboveY
        let horizontalWidth=min(desiredWidth,screen.width)
        let x=min(max(selection.midX-horizontalWidth/2,screen.minX),screen.maxX-horizontalWidth)
        if aboveHeight>=260 {
            let h=min(desiredHeight,aboveHeight)
            return Placement(frame:CGRect(x:x,y:aboveY,width:horizontalWidth,height:h),position:.above)
        }
        if belowHeight>=260 {
            let h=min(desiredHeight,belowHeight)
            return Placement(frame:CGRect(x:x,y:selection.minY-gap-h,width:horizontalWidth,height:h),position:.below)
        }
        // A second monitor is preferable to covering the capture area.
        if let other=screens.first(where:{!$0.intersects(selection) && $0.width>250 && $0.height>280}) {
            let target=other.insetBy(dx:margin,dy:margin)
            let w=min(desiredWidth,target.width),h=min(desiredHeight,target.height)
            return Placement(frame:CGRect(x:target.maxX-w,y:target.maxY-h,width:w,height:h),position:.otherDisplay)
        }
        // Extreme case: nearly full-screen selection, keep a movable panel
        // which is explicitly hidden whenever its bounds cross the capture.
        let w=min(desiredWidth,screen.width),h=min(desiredHeight,screen.height)
        return Placement(frame:CGRect(x:screen.minX,y:screen.maxY-h,width:w,height:h),position:.overlapping)
    }
}

/// An overlay with an entirely transparent centre. AppKit cannot intercept
/// mouse/scroll events through this window, so the actual webpage underneath
/// remains the scroll target. All visible ink is OUTSIDE the captured pixels.
final class ScreenshotLongCaptureFrameView: NSView {
    static let inset:CGFloat=16
    override var isOpaque:Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let capture=bounds.insetBy(dx:Self.inset,dy:Self.inset)
        guard capture.width>0,capture.height>0 else{return}
        NSColor(calibratedRed:0.12,green:0.68,blue:1,alpha:0.95).setFill()
        let thickness:CGFloat=2, clearGap:CGFloat=3
        // Keep a three-point transparent safety margin around the screenshot.
        // This also prevents antialiasing from leaking blue pixels into exports.
        NSRect(x:capture.minX-clearGap-thickness,y:capture.minY-clearGap-thickness,
               width:capture.width+(clearGap+thickness)*2,height:thickness).fill()
        NSRect(x:capture.minX-clearGap-thickness,y:capture.maxY+clearGap,
               width:capture.width+(clearGap+thickness)*2,height:thickness).fill()
        NSRect(x:capture.minX-clearGap-thickness,y:capture.minY-clearGap,
               width:thickness,height:capture.height+clearGap*2).fill()
        NSRect(x:capture.maxX+clearGap,y:capture.minY-clearGap,
               width:thickness,height:capture.height+clearGap*2).fill()
        let cornerLength:CGFloat=11,cornerThickness:CGFloat=3
        for x in [capture.minX,capture.maxX] {
            for y in [capture.minY,capture.maxY] {
                let left=x==capture.minX
                let low=y==capture.minY
                let cx=left ? x-clearGap-cornerLength:x+clearGap
                let cy=low ? y-clearGap-cornerThickness:y+clearGap
                NSRect(x:cx,y:cy,width:cornerLength,height:cornerThickness).fill()
                let vx=left ? x-clearGap-cornerThickness:x+clearGap
                let vy=low ? y-clearGap-cornerLength:y+clearGap
                NSRect(x:vx,y:vy,width:cornerThickness,height:cornerLength).fill()
            }
        }
    }
}

final class ScreenshotLongCaptureFrame: NSPanel {
    init(selection:CGRect) {
        let inset=ScreenshotLongCaptureFrameView.inset
        let region=selection.insetBy(dx:-inset,dy:-inset)
        super.init(contentRect:region,styleMask:[.borderless,.nonactivatingPanel],
                   backing:.buffered,defer:false)
        isOpaque=false
        backgroundColor = .clear
        hasShadow=false
        ignoresMouseEvents=true
        isReleasedWhenClosed=false
        hidesOnDeactivate=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        level = .screenSaver
        contentView=ScreenshotLongCaptureFrameView(frame:NSRect(origin:.zero,size:region.size))
        orderFrontRegardless()
    }
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

/// Renders the immutable screenshot slices without repeatedly composing a
/// 100-megapixel bitmap just to update the preview.
final class ScreenshotLongPreviewImageView: NSView {
    private(set) var sections:[CGImage]=[]
    private(set) var sourceWidth=1
    private(set) var sourceHeight=1
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {true}

    func update(sections:[CGImage],sourceWidth:Int,sourceHeight:Int,displayWidth:CGFloat) {
        self.sections=sections
        self.sourceWidth=max(1,sourceWidth)
        self.sourceHeight=max(1,sourceHeight)
        let width=max(1,displayWidth)
        let height=max(1,ceil(CGFloat(self.sourceHeight)*width/CGFloat(self.sourceWidth)))
        setFrameSize(NSSize(width:width,height:height))
        needsDisplay=true
    }

    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.12,alpha:1).setFill()
        dirtyRect.fill()
        let scale=bounds.width/CGFloat(sourceWidth)
        var top:CGFloat=0
        NSGraphicsContext.current?.imageInterpolation = .high
        for segment in sections {
            let next=top+CGFloat(segment.height)*scale
            let target=CGRect(x:0,y:top,width:bounds.width,height:next-top)
            if target.intersects(dirtyRect) {
                NSImage(cgImage:segment,size:NSSize(width:segment.width,height:segment.height))
                    .draw(in:target,from:.zero,operation:.copy,fraction:1,
                          respectFlipped:true,hints:nil)
            }
            top=next
        }
    }
}

/// Native preview panel, kept outside the selected region whenever possible.
/// The panel is non-activating: clicking its controls does not bring the MacState
/// monitor back in front of the page being scrolled.
final class ScreenshotLongPreviewPanel: NSPanel {
    var onAutomaticToggle:(()->Void)?
    var onPauseToggle:(()->Void)?
    var onComplete:(()->Void)?
    var onCancel:(()->Void)?

    private let heading=NSTextField(labelWithString:"已拼接的长截图")
    private let hint=NSTextField(labelWithString:"在右侧蓝框内上下滚动（每次约半屏）")
    private let summary=NSTextField(labelWithString:"正在获取初始画面…")
    private let detail=NSTextField(labelWithString:"手动滚动 · 采集中")
    private let preview=ScreenshotLongPreviewImageView()
    private let scroll=NSScrollView()
    private let modeButton=NSButton(title:"开始自动滚动",target:nil,action:nil)
    private let pauseButton=NSButton(title:"暂停采集",target:nil,action:nil)
    private let doneButton=NSButton(title:"完成并保存",target:nil,action:nil)
    private let cancelButton=NSButton(title:"取消",target:nil,action:nil)
    private var backingWidth:CGFloat=0

    var displayedFrames:Int=0
    var displayedHeight:Int=0
    var previewDocument:ScreenshotLongPreviewImageView {preview}
    var isAutomatic=false
    var isPaused=false

    init(selection:CGRect,screens:[CGRect]) {
        let placement=ScreenshotLongPreviewLayout.place(selection:selection,screens:screens)
        super.init(contentRect:placement.frame,styleMask:[.titled,.resizable,.nonactivatingPanel],
                   backing:.buffered,defer:false)
        title="MacState · 长截屏预览"
        isReleasedWhenClosed=false
        hidesOnDeactivate=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        level = .floating
        minSize=NSSize(width:245,height:290)
        maxSize=NSSize(width:700,height:1200)
        let content=NSVisualEffectView(frame:NSRect(origin:.zero,size:placement.frame.size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.autoresizingMask=[.width,.height]
        contentView=content

        heading.font = .systemFont(ofSize:16,weight:.semibold)
        heading.textColor = .labelColor
        hint.font = .systemFont(ofSize:11)
        hint.textColor = .secondaryLabelColor
        summary.font = .monospacedSystemFont(ofSize:11,weight:.medium)
        summary.textColor = .labelColor
        detail.font = .systemFont(ofSize:11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for view in [heading,hint,summary,detail] {content.addSubview(view)}
        scroll.documentView=preview
        scroll.hasVerticalScroller=true
        scroll.autohidesScrollers=true
        scroll.hasHorizontalScroller=false
        scroll.drawsBackground=true
        scroll.backgroundColor=NSColor(calibratedWhite:0.09,alpha:0.75)
        scroll.borderType = .bezelBorder
        content.addSubview(scroll)

        for (button,action) in [(modeButton,#selector(toggleAuto)),
                                (pauseButton,#selector(togglePause)),
                                (doneButton,#selector(completeCapture)),
                                (cancelButton,#selector(cancelCapture))] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize:12,weight:.medium)
            button.target=self
            button.action=action
            content.addSubview(button)
        }
        doneButton.bezelColor = NSColor(calibratedRed:0.17,green:0.54,blue:0.97,alpha:1)
        doneButton.contentTintColor = .white
        content.needsLayout=true
        layoutContent()
        orderFrontRegardless()
    }

    override func setContentSize(_ size:NSSize) {
        super.setContentSize(size)
        if contentView != nil {layoutContent()}
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutContent()
    }

    private func layoutContent() {
        guard let content=contentView else{return}
        let b=content.bounds
        guard b.width>0,b.height>0 else{return}
        let padding:CGFloat=13
        heading.frame=NSRect(x:padding,y:b.height-34,width:b.width-2*padding,height:23)
        hint.frame=NSRect(x:padding,y:b.height-55,width:b.width-2*padding,height:18)
        summary.frame=NSRect(x:padding,y:b.height-78,width:b.width-2*padding,height:18)
        detail.frame=NSRect(x:padding,y:69,width:b.width-2*padding,height:18)
        scroll.frame=NSRect(x:padding,y:94,width:b.width-2*padding,
                            height:max(85,b.height-183))
        let half=max(100,(b.width-3*padding)/2)
        modeButton.frame=NSRect(x:padding,y:41,width:half,height:27)
        pauseButton.frame=NSRect(x:padding*2+half,y:41,width:half,height:27)
        cancelButton.frame=NSRect(x:padding,y:8,width:half,height:28)
        doneButton.frame=NSRect(x:padding*2+half,y:8,width:half,height:28)
        let width=max(1,scroll.contentSize.width-1)
        if abs(backingWidth-width)>0.5 {
            backingWidth=width
            preview.update(sections:preview.sections,sourceWidth:preview.sourceWidth,
                           sourceHeight:preview.sourceHeight,displayWidth:width)
        }
    }

    /// Newly discovered top rows change the coordinate of every existing
    /// preview pixel. Anchor the scroll position instead of making the preview
    /// jump to unrelated content or always following the bottom.
    static func previewScrollOffset(previous:CGFloat,previousHeight:CGFloat,
                                    nextHeight:CGFloat,viewportHeight:CGFloat,
                                    prependedPoints:CGFloat)->CGFloat {
        let oldMax=max(0,previousHeight-viewportHeight)
        let newMax=max(0,nextHeight-viewportHeight)
        if prependedPoints>0 {
            // When not deliberately reading the middle, follow the newly
            // discovered upper edge of the screenshot.
            if previous<=28 || previous>=oldMax-28 {return 0}
            return min(newMax,previous+prependedPoints)
        }
        return previous>=oldMax-28 ? newMax : min(newMax,previous)
    }

    func show(stitcher:ScreenshotLongStitcher,message:String,prependedPixels:Int=0) {
        let viewportHeight=scroll.contentView.bounds.height
        let previousOffset=scroll.contentView.bounds.minY
        let previousHeight=preview.frame.height
        let viewWidth=max(1,scroll.contentSize.width-1)
        displayedFrames=stitcher.frames
        displayedHeight=stitcher.height
        summary.stringValue="\(stitcher.width) × \(stitcher.height) px  ·  \(stitcher.frames) 段"
        detail.stringValue=message
        preview.update(sections:stitcher.sections,sourceWidth:stitcher.width,
                       sourceHeight:stitcher.height,displayWidth:viewWidth)
        let addedPoints=CGFloat(prependedPixels)*viewWidth/CGFloat(stitcher.width)
        let target=Self.previewScrollOffset(previous:previousOffset,
                                            previousHeight:previousHeight,
                                            nextHeight:preview.frame.height,
                                            viewportHeight:viewportHeight,
                                            prependedPoints:addedPoints)
        scroll.contentView.scroll(to:NSPoint(x:0,y:target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func showStatus(_ message:String) { detail.stringValue=message }

    func setControls(automatic:Bool,paused:Bool) {
        isAutomatic=automatic
        isPaused=paused
        modeButton.title=automatic ? "切换手动滚动" : "开始自动滚动"
        pauseButton.title=paused ? "继续采集" : "暂停采集"
    }

    func intersectsCapture(_ rect:CGRect)->Bool {
        !frame.intersection(rect).isNull && frame.intersection(rect).width>0 &&
        frame.intersection(rect).height>0
    }

    @objc private func toggleAuto(_ sender:Any?) {onAutomaticToggle?()}
    @objc private func togglePause(_ sender:Any?) {onPauseToggle?()}
    @objc private func completeCapture(_ sender:Any?) {onComplete?()}
    @objc private func cancelCapture(_ sender:Any?) {onCancel?()}

    override func close() {
        onAutomaticToggle=nil;onPauseToggle=nil;onComplete=nil;onCancel=nil
        super.close()
    }
}
