import AppKit

/// Full-screen dimmed editing surface, matching the region-screenshot editor.
/// The screenshot remains at its native backing-pixel size, while editing
/// controls can use the entire display instead of being clipped to its edges.
enum ScreenshotEditorLayout {
    static let topInset:CGFloat=52
    static let bottomInset:CGFloat=230
    static let horizontalInset:CGFloat=48
    static func sourceFrame(imageSize: NSSize, backingScale: CGFloat, canvas: NSRect) -> NSRect {
        let scale=max(1,backingScale)
        let natural=NSSize(width:imageSize.width/scale,height:imageSize.height/scale)
        let availableWidth=max(1,canvas.width-horizontalInset*2)
        let availableHeight=max(1,canvas.height-topInset-bottomInset)
        // Never enlarge a small image. Fit larger images entirely between
        // the dimensions bar and the (potentially expanded) annotation palette.
        let fit=min(1,availableWidth/natural.width,availableHeight/natural.height)
        let size=NSSize(width:natural.width*fit,height:natural.height*fit)
        return NSRect(x:(canvas.width-size.width)/2,
                      y:topInset+availableHeight/2-size.height/2,
                      width:size.width,height:size.height)
    }
}

final class ScreenshotEditorPanel: NSPanel {
    let editor: ScreenshotEditingView
    var onClosed: (() -> Void)?

    init(image: CGImage, screen: NSScreen) {
        let canvas=NSRect(origin:.zero,size:screen.frame.size)
        let imageFrame=ScreenshotEditorLayout.sourceFrame(
            imageSize:NSSize(width:image.width,height:image.height),
            backingScale:screen.backingScaleFactor,canvas:canvas)
        editor=ScreenshotEditingView(frame:canvas,image:image,selection:imageFrame,
                                    cancelTitle:"返回截屏页（Esc / 右键）",
                                    sourceRect:imageFrame)
        editor.configureHistoryViewport(backingScale:screen.backingScaleFactor)
        super.init(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
        isReleasedWhenClosed=false
        isOpaque=false
        backgroundColor = .clear
        hasShadow=false
        level = .screenSaver
        hidesOnDeactivate=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        contentView=editor
        acceptsMouseMovedEvents=true
    }

    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}

    override func close() {
        NSColorPanel.shared.orderOut(nil)
        NSColorPanel.shared.level = .floating
        super.close()
        onClosed?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            // The first Escape leaves OCR text selection. A second Escape
            // closes the screenshot editor, just like the region picker.
            editor.keyDown(with:event)
            return
        }
        super.sendEvent(event)
    }
}
