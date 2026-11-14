import AppKit

/// Match the custom toggle's glyph renderer exactly. NSTextField's native
/// cell draws CJK text several screen pixels above an NSButton label even
/// when their frames have identical vertical centers.
private final class ScreenshotEditorHeaderCaption: NSButton {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        // Use the same NSButton drawing coordinates, glyph height and font
        // as ScreenshotEditorToggle's 70%-scale caption. Unlike NSTextField,
        // NSButton preserves the same raster baseline inside both rows of
        // the nonflipped header container.
        let labelHeight:CGFloat=18*0.70
        (title as NSString).draw(
            in:NSRect(x:0,y:bounds.midY-labelHeight/2,
                      width:bounds.width,height:labelHeight),
            withAttributes:[
                .font:NSFont.systemFont(ofSize:8),
                .foregroundColor:NSColor.labelColor
            ])
    }
}

private final class CenteredNumberFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing=super.drawingRect(forBounds:rect)
        drawing.size.height=min(drawing.height,cellSize(forBounds:rect).height)
        drawing.origin.y=rect.midY-drawing.height/2
        return drawing
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        title.origin.y = rect.midY - title.height / 2
        return title
    }
}

private final class CenteredNumberField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredNumberFieldCell.self }
        set { }
    }
}

private final class ScreenshotAnnotationTextField: NSTextField {
    var passesPointerEvents = false
    override func hitTest(_ point:NSPoint)->NSView? {passesPointerEvents ? nil : super.hitTest(point)}
}

private enum ScreenshotRadiusCurve {
    static func value(at position: Double, maximum: Double) -> Double {
        guard maximum > 0 else { return 0 }
        let t = min(1, max(0, position / maximum))
        return maximum * t * t * (3 - 2 * t)
    }

    static func position(for value: Double, maximum: Double) -> Double {
        guard maximum > 0 else { return 0 }
        let target = min(1, max(0, value / maximum))
        var low = 0.0, high = 1.0
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if middle * middle * (3 - 2 * middle) < target { low = middle } else { high = middle }
        }
        return (low + high) / 2 * maximum
    }
}

private final class ScreenshotRadiusSlider: NSSlider {
    private(set) var isTrackingRadius = false
    var onTrackingBegan: (() -> Void)?
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isTrackingRadius = true
        onTrackingBegan?()
        super.mouseDown(with: event)
        isTrackingRadius = false
        onTrackingEnded?()
    }
}

private final class ScreenshotStyleSlider: NSSlider {
    private(set) var isTrackingValue = false
    var onTrackingBegan: (() -> Void)?
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isTrackingValue = true
        onTrackingBegan?()
        super.mouseDown(with: event)
        isTrackingValue = false
        onTrackingEnded?()
    }
}

private enum ScreenshotResizeCursors {
    static func native(_ index:Int) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position:NSCursor.FrameResizePosition
            switch index {
            case 0: position = .topLeft
            case 1: position = .top
            case 2: position = .topRight
            case 3: position = .right
            case 4: position = .bottomRight
            case 5: position = .bottom
            case 6: position = .bottomLeft
            default: position = .left
            }
            return NSCursor.frameResize(position:position,directions:.all)
        }
        switch index {
        case 1,5: return .resizeUpDown
        case 3,7: return .resizeLeftRight
        default: return .arrow
        }
    }
}

private final class ScreenshotTooltipBubble: NSView {
    let label=NSTextField(labelWithString:"")
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        label.frame=NSRect(x:9,y:4,width:max(0,bounds.width-18),height:max(0,bounds.height-8))
    }
    init() {
        super.init(frame:.zero)
        wantsLayer=true;layer?.cornerRadius=6;layer?.backgroundColor=NSColor(calibratedWhite:0.10,alpha:0.97).cgColor
        layer?.borderColor=NSColor.white.withAlphaComponent(0.35).cgColor;layer?.borderWidth=0.7
        layer?.shadowColor=NSColor.black.cgColor;layer?.shadowOpacity=0.35;layer?.shadowRadius=5;layer?.shadowOffset=NSSize(width:0,height:-2)
        label.font = .systemFont(ofSize:11,weight:.medium);label.textColor = .white;addSubview(label)
        isHidden=true
    }
    required init?(coder:NSCoder) { nil }
}

/// Compact, hit-testable screenshot toolbar geometry. All actions remain
/// visible: use a single row when possible, and wrap rather than clip on a
/// narrow display. Calculations are independent of AppKit window state.
enum ScreenshotEditorToolbarLayout {
    private static let inset:CGFloat=7
    private static let gap:CGFloat=1
    private static let topBottom:CGFloat=6
    static func geometry(availableWidth:CGFloat,buttonCount:Int)->(size:NSSize,frames:[NSRect]) {
        guard buttonCount>0 else{return (.zero,[])}
        let space=max(1,availableWidth)
        let idealSide:CGFloat=28
        let minimumSide:CGFloat=24
        let minimumWidth=2*inset+CGFloat(buttonCount)*minimumSide+CGFloat(buttonCount-1)*gap
        let columns:Int
        let side:CGFloat
        if space>=minimumWidth {
            columns=buttonCount
            side=min(idealSide,floor((space-2*inset-CGFloat(buttonCount-1)*gap)/CGFloat(buttonCount)))
        } else {
            let perItem=idealSide+gap
            columns=min(10,max(1,Int(floor((space-2*inset+gap)/perItem))))
            side=idealSide
        }
        let rows=(buttonCount+columns-1)/columns
        let rowSpacing:CGFloat=2
        var frames:[NSRect]=[]
        frames.reserveCapacity(buttonCount)
        for i in 0..<buttonCount {
            frames.append(NSRect(x:inset+CGFloat(i%columns)*(side+gap),
                                 y:topBottom+CGFloat(i/columns)*(side+rowSpacing),
                                 width:side,height:side))
        }
        let widest=min(buttonCount,columns)
        let width=2*inset+CGFloat(widest)*side+CGFloat(widest-1)*gap
        let height=2*topBottom+CGFloat(rows)*side+CGFloat(rows-1)*rowSpacing
        return (NSSize(width:width,height:height),frames)
    }
}

@MainActor final class ScreenshotOCRRevealProgress {
    var received:[Int:String]=[:],shown:[Int:Int]=[:]
    var finished=Set<Int>()
    var completed=false

    func available(_ index:Int)->String {
        received[index] ?? ""
    }

    func advance(_ index:Int) {
        let count=available(index).count
        shown[index]=min(count,shown[index,default:0]+max(1,(count+7)/8))
    }

    func next(count:Int)->Int? {
        (0..<count).first { (!completed && !finished.contains($0)) || shown[$0,default:0]<(received[$0]?.count ?? 0) }
    }
}

final class ScreenshotEditingView: NSView, NSTextFieldDelegate {
    private static let rectanglePalette: [NSColor] = [.systemRed,.systemPink,.systemTeal,.systemYellow,.systemGreen,.systemOrange,.systemPurple]
    // Shape and stroke inspectors share one compact 4+3+1 palette.
    private static let shapeInspectorPalette: [NSColor] = [.systemRed,.systemPink,.systemTeal,.systemYellow,.systemGreen,.black,.white]
    private static let compactInspectorTools:Set<ScreenshotEditTool> = [.rectangle,.ellipse,.line,.arrow,.pen,.mask]
    private var displayedPalette: [NSColor] { Self.compactInspectorTools.contains(activeTool) || [.text,.number].contains(activeTool) ? Self.shapeInspectorPalette : Self.rectanglePalette }
    var onFinish: ((CGImage?,String) -> Void)?
    var onPin: ((CGImage,NSRect) -> Void)?
    var onLongCapture: ((NSRect,CGImage) -> Void)? {
        didSet { toolbar.subviews.compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue == "long"}?.isEnabled = onLongCapture != nil }
    }
    private let cancelTitle: String
    let document: ScreenshotEditDocument
    private(set) var tool = ScreenshotEditTool.select
    private var style = ScreenshotAnnotation(tool:.rectangle,start:.zero,end:.zero)
    private var perToolStyles: [ScreenshotEditTool:ScreenshotAnnotation] = [:]
    private var selectedID: UUID?
    private var dragStart = NSPoint.zero
    private var original: ScreenshotEditSnapshot?
    private enum AnnotationGesture { case move(Bool), resize(Int), endpoint(Bool) }
    private enum Drag { case none, cropMove, cropResize(Int), objectMove(UUID,Bool), objectResize(UUID,Int), lineEndpoint(UUID,Bool), pendingManipulation(UUID,AnnotationGesture), pendingCreate(ScreenshotEditTool), create(UUID) }
    private var dragging = Drag.none
    private var preview: CGImage?, previewSelection = NSRect.zero
    private var renderToken = UUID()
    private var completedRenderToken: UUID?
    var previewReady: Bool { completedRenderToken == renderToken }
    var recognizedBoxes: [ScreenshotOCRBox] {ocrBoxes}
    var ocrModeForTesting: Bool {ocrMode}
    func setOCRProcessingForTesting(_ value:Bool) {
        guard ocrMode else{return}
        processing=value
        status.stringValue=value ? "正在本机识别文字…" : "识别完成，拖动选择文字。"
        layoutControls()
    }
    var ocrSelectionForTesting: String {visibleOCRSelection.selectedText()}
    var ocrTranslationTextForTesting: String {ocrTranslationText}
    var ocrTranslationOverlaysForTesting:[ScreenshotOCRTranslationOverlay] {ocrTranslationOverlays}
    var ocrShowingTranslationForTesting:Bool {showingOCRTranslation}
    var ocrTranslatingForTesting:Bool {ocrTranslationTask != nil}
    var ocrTranslationScrollOffsetForTesting:CGFloat {ocrTranslationScrollOffset}
    var ocrTranslationContentRectForTesting:NSRect {ocrTranslationContentRect}
    func installOCRTranslationsForTesting(_ translated:[String],copyResult:Bool=false,streamingTarget:String?=nil) {
        let segments=ScreenshotOCRTranslationSegment.make(from:ocrText,in:document.sourceRect)
        let overlays=zip(segments,translated).map {
            ScreenshotOCRTranslationOverlay(text:$0.1,sourceRect:$0.0.rect,
                                            sourceLineHeight:$0.0.lineHeight,
                                            sourceLines:$0.0.sourceLines,sourceText:$0.0.text)
        }
        applyOCRTranslation(overlays,copyResult:copyResult,streamingTarget:streamingTarget)
    }
    func installOCRForTesting(_ boxes:[ScreenshotOCRBox],region:NSRect=NSRect(x:0,y:0,width:1,height:1)) {
        clearOCRTranslation()
        ocrMode=true;ocrText.install(boxes,region:region)
        ocrText.selectAll()
        ocrDetectedLanguage=ScreenshotOCRTranslationLanguage.source(for:ocrText.allText())
        ocrBoxes=ocrText.boxes;layoutControls();needsDisplay=true
    }
    var isProcessing: Bool {processing}
    var radiusInputCellTitleRectForTesting: NSRect { radiusValue.cell!.titleRect(forBounds:radiusValue.bounds) }
    var radiusInputBoundsForTesting: NSRect { radiusValue.bounds }
    var shadowLabelFrameForTesting: NSRect { shadowToggle.frame }
    var editorHeaderFrameForTesting: NSRect { header.frame }
    var editorToolbarFrameForTesting: NSRect { toolbar.frame }
    var editorOptionsFrameForTesting: NSRect { optionsHost.frame }
    var numberStyleControlsFitForTesting: Bool { !numberSizeValue.isHidden && numberSizeValue.frame.maxX <= options.frame.width }
    var textStyleControlsFitForTesting: Bool { !textOutlineColor.isHidden && textOutlineColor.frame.maxX <= options.frame.width }
    var radiusSliderValueForTesting: Double { radius.doubleValue }
    var radiusSliderMaximumForTesting: Double { radius.maxValue }
    var annotationColorWellForTesting: NSColorWell { color }
    var renderTokenForTesting: UUID { renderToken }
    private let renderQueue: OperationQueue = { let q=OperationQueue();q.name="MacState.screenshot.preview";q.maxConcurrentOperationCount=1;q.qualityOfService = .userInitiated;return q }()
    private var finished = false, processing = false
    private var ocrBoxes: [ScreenshotOCRBox] = []
    private var ocrMode=false,ocrDraggingText=false
    private var translationMode=false,translateAfterRecognition=false
    private var ocrText=ScreenshotOCRTextSelection()
    private var ocrGeneration=UUID()
    private weak var ocrToolbarButton:NSButton?
    private weak var translationToolbarButton:NSButton?
    private let ocrSelectedButton=ScreenshotOCRButton(title:"复制选中",target:nil,action:nil)
    private let ocrTranslateButton=ScreenshotOCRButton(title:"翻译",target:nil,action:nil)
    private let ocrTranslateCopyButton=ScreenshotOCRButton(title:"翻译并复制",target:nil,action:nil)
    private let ocrSettingsButton=ScreenshotOCRButton(title:"翻译设置",target:nil,action:nil)
    private var ocrSettingsWindow:ScreenshotOCRTranslationSettingsWindow?
    private var ocrTranslationOverlays:[ScreenshotOCRTranslationOverlay]=[]
    private var translatedOCRText=ScreenshotOCRTextSelection()
    private var showingOCRTranslation=false
    private var ocrReplacingOriginal=false
    private var ocrTranslationScrollOffset:CGFloat=0
    private let ocrTranslationScroller=NSScroller()
    private var ocrTranslationContentRect:NSRect {
        let bottom=ocrTranslationOverlays.flatMap(\.lines).map{$0.rect.maxY+4}.max() ?? document.selection.maxY
        return NSRect(x:document.selection.minX,y:document.selection.minY,width:document.selection.width,
                      height:max(document.selection.height,bottom-document.selection.minY))
    }
    private var ocrTranslationScrollMaximum:CGFloat {max(0,ocrTranslationContentRect.height-document.selection.height)}
    private var ocrTranslationTask:Task<Void,Never>?
    private var ocrRevealTask:Task<Void,Never>?
    private var ocrBackgroundTask:Task<[ScreenshotOCRTranslationOverlay],Never>?
    private var ocrTranslationToken=UUID()
    private var ocrTranslationTargetOverride:String?
    private var ocrTranslationSourceOverride:String?
    private var ocrDetectedLanguage="en"
    private let ocrSourceLanguage=NSPopUpButton(),ocrTargetLanguage=NSPopUpButton()
    private let ocrSourceTitle=NSTextField(labelWithString:"原文"),ocrTargetTitle=NSTextField(labelWithString:"译文")
    private let ocrLanguageArrow=NSTextField(labelWithString:"→")
    private var visibleOCRSelection:ScreenshotOCRTextSelection {
        showingOCRTranslation ? translatedOCRText:ocrText
    }
    private var input: NSTextField?, inputID: UUID?
    private let header=NSView(),toolbar=NSView(),options=ScreenshotEditorOptionsView()
    private let optionsHost=NSView(),optionsScroll=NSScrollView()
    private let moreStyles=NSTextField(labelWithString:"滚动查看更多样式 ↓")
    private var displayedStyle=""
    private let zoomHUD=NSView(),zoomLabel=NSTextField(labelWithString:"100%")
    private var naturalImageSize: NSSize?
    private var spaceHeld=false,viewPanning=false,panToolEnabled=false
    private weak var panButton:NSButton?
    private var lastPanPoint=NSPoint.zero
    var viewportZoom:CGFloat {
        guard let size=naturalImageSize,size.width>0 else{return 1}
        return document.sourceRect.width/size.width
    }
    var viewportFrameForTesting:NSRect {document.sourceRect}
    func configureHistoryViewport(backingScale:CGFloat) {
        let factor=max(1,backingScale)
        naturalImageSize=NSSize(width:CGFloat(document.raster.image.width)/factor,
                                height:CGFloat(document.raster.image.height)/factor)
        setupZoomHUD()
        layoutControls()
    }
    private let dimensions=NSTextField(labelWithString:""),headerRadiusTitle=ScreenshotEditorHeaderCaption(title:"圆角",target:nil,action:nil),radius=ScreenshotRadiusSlider(value:0,minValue:0,maxValue:1000,target:nil,action:nil),radiusValue=CenteredNumberField(string:"0")
    private let shadowToggle=ScreenshotEditorToggle(checkboxWithTitle:"阴影",target:nil,action:nil)
    private let color=ScreenshotEditingColorWell(),lineWidth=ScreenshotStyleSlider(value:2,minValue:1,maxValue:80,target:nil,action:nil),lineValue=CenteredNumberField(string:"2")
    private let rectangleOpacity=ScreenshotStyleSlider(value:100,minValue:0,maxValue:100,target:nil,action:nil)
    private let rectangleOpacityValue=NSTextField(labelWithString:"100")
    private let rectangleOpacityInput=CenteredNumberField(string:"100")
    private let rectangleSizeTitle=NSTextField(labelWithString:"大小"),rectangleOpacityTitle=NSTextField(labelWithString:"不透明度")
    private let rectangleFill=ScreenshotEditorToggle(checkboxWithTitle:"实心",target:nil,action:nil),rectangleRounded=ScreenshotEditorToggle(checkboxWithTitle:"圆角",target:nil,action:nil)
    private let rectangleSectionRules=(0..<2).map{_ in ScreenshotEditorDivider()}
    private let textSectionRule=ScreenshotEditorDivider()
    private let numberSectionRule=ScreenshotEditorDivider()
    private let shapeCornerRadius=ScreenshotStyleSlider(value:15,minValue:0,maxValue:100,target:nil,action:nil),shapeCornerRadiusValue=CenteredNumberField(string:"15")
    private let textCornerRadius=ScreenshotStyleSlider(value:15,minValue:0,maxValue:60,target:nil,action:nil),textCornerRadiusValue=CenteredNumberField(string:"15")
    private var rectangleColorButtons: [NSButton] = []
    private let numberSizeTitle=NSTextField(labelWithString:"序号大小"),numberSize=ScreenshotStyleSlider(value:20,minValue:8,maxValue:80,target:nil,action:nil),numberSizeValue=CenteredNumberField(string:"20")
    private let numberColorTitle=NSTextField(labelWithString:"序号颜色")
    private let fontSizeTitle=NSTextField(labelWithString:"字号"),textFontTitle=NSTextField(labelWithString:"字体"),textCornerRadiusTitle=NSTextField(labelWithString:"圆角")
    private let effect=NSPopUpButton(),effectModeTitle=NSTextField(labelWithString:"方式"),fontFamily=NSPopUpButton(),fontSize=ScreenshotStyleSlider(value:20,minValue:8,maxValue:144,target:nil,action:nil),fontValue=CenteredNumberField(string:"20")
    private let bold=ScreenshotEditorToggle(checkboxWithTitle:"粗体",target:nil,action:nil),italic=ScreenshotEditorToggle(checkboxWithTitle:"斜体",target:nil,action:nil),underline=ScreenshotEditorToggle(checkboxWithTitle:"下划线",target:nil,action:nil)
    private let textBackground=ScreenshotEditorToggle(checkboxWithTitle:"底色",target:nil,action:nil),textRounded=ScreenshotEditorToggle(checkboxWithTitle:"圆角底色",target:nil,action:nil),textShadow=ScreenshotEditorToggle(checkboxWithTitle:"阴影",target:nil,action:nil),textOutline=ScreenshotEditorToggle(checkboxWithTitle:"描边",target:nil,action:nil),backgroundColor=ScreenshotEditingColorWell(),textOutlineColor=ScreenshotEditingColorWell(),numberColor=ScreenshotEditingColorWell()
    private let copyOCR=ScreenshotOCRButton(title:"拷贝全部文字",target:nil,action:nil),status=NSTextField(labelWithString:"")
    private let tooltipBubble=ScreenshotTooltipBubble()
    private var pointerTracking:NSTrackingArea?
    private var toolButtons: [ScreenshotEditTool:NSButton] = [:]
    override var isFlipped: Bool {true}
    override var acceptsFirstResponder: Bool {true}
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds,cursor:.arrow)
    }
    override func cursorUpdate(with event:NSEvent) {
        if viewPanning {NSCursor.closedHand.set();return}
        if spaceHeld || panToolEnabled {NSCursor.openHand.set();return}
        cursor(at:convert(event.locationInWindow,from:nil)).set()
    }
    private func cursor(at point:NSPoint)->NSCursor {
        if ocrMode {
            guard document.selection.contains(point) else{return .arrow}
            return visibleOCRSelection.line(at:ocrPoint(point),in:document.sourceRect) != nil ? .iBeam : .arrow
        }
        let cropHandles=handles(document.selection)
        if let index=cropHandles.firstIndex(where:{NSRect(x:$0.x-7,y:$0.y-7,width:14,height:14).contains(point)}) {
            return ScreenshotResizeCursors.native(index)
        }
        if case .cropMove=dragging,document.selection.contains(point) {return .closedHand}
        for item in document.annotations.reversed() {
            guard item.contains(point),let gesture=annotationGesture(for:item,at:point) else{continue}
            switch gesture {
            case .move:
                if [.text,.number].contains(item.tool),item.textRect.contains(point),!isNearEdge(item.textRect,point:point) {return .iBeam}
                return .openHand
            case .resize(let index):return ScreenshotResizeCursors.native(index)
            case .endpoint:return .crosshair
            }
        }
        return .arrow
    }
    private func annotationGesture(for item:ScreenshotAnnotation,at point:NSPoint)->AnnotationGesture? {
        if item.tool == .line || item.tool == .arrow {
            if hypot(point.x-item.start.x,point.y-item.start.y)<=10 {return .endpoint(true)}
            if hypot(point.x-item.end.x,point.y-item.end.y)<=10 {return .endpoint(false)}
            return item.contains(point) ? .move(false) : nil
        }
        if [.rectangle,.ellipse,.mask,.text,.number,.highlight].contains(item.tool) {
            let points=[.text,.number].contains(item.tool) ? [handles(resizeFrame(for:item))[4]] : handles(resizeFrame(for:item))
            if let handle=points.firstIndex(where:{NSRect(x:$0.x-7,y:$0.y-7,width:14,height:14).contains(point)}) {
                return .resize([.text,.number].contains(item.tool) ? 4 : handle)
            }
        }
        if item.contains(point) {
            let movesNumberLabel=item.tool == .number && item.textRect.insetBy(dx:-8,dy:-8).contains(point) && !numberBadgeContains(item,point)
            return .move(movesNumberLabel)
        }
        return nil
    }
    private func resizeFrame(for item:ScreenshotAnnotation)->NSRect {item.tool == .number ? item.textRect : item.rect}
    private func isNearEdge(_ rect:NSRect,point:NSPoint)->Bool {
        guard rect.insetBy(dx:-8,dy:-8).contains(point) else{return false}
        return min(min(abs(point.x-rect.minX),abs(point.x-rect.maxX)),min(abs(point.y-rect.minY),abs(point.y-rect.maxY))) <= 8
    }
    private func numberBadgeContains(_ item:ScreenshotAnnotation,_ point:NSPoint)->Bool {
        let radius=max(1,item.numberSize*0.7)
        return hypot(point.x-item.start.x,point.y-item.start.y) <= radius+7
    }
    private let preferences: UserDefaults
    private let translationPreferences:ScreenshotOCRTranslationPreferences
    private let translationClient:ScreenshotOCRLLMService
    init(frame: NSRect,image: CGImage,selection: NSRect,preferences: UserDefaults = .standard,cancelTitle: String = "取消截图（Esc / 右键）",sourceRect: NSRect? = nil,
         translationPreferences:ScreenshotOCRTranslationPreferences?=nil,translationClient:ScreenshotOCRLLMService = .init()) {
        self.preferences=preferences
        self.translationPreferences=translationPreferences ?? ScreenshotOCRTranslationPreferences(defaults:preferences)
        self.translationClient=translationClient
        self.cancelTitle=cancelTitle
        document=ScreenshotEditDocument(image:image,viewSize:frame.size,selection:selection,sourceRect:sourceRect)
        let saved=ScreenshotEditPreferences.restore(defaults:preferences)
        document.cornerRadius=saved.radiusPixels*document.sourceRect.width/CGFloat(image.width)
        document.shadow=saved.shadow
        super.init(frame:frame);setupControls();addSubview(tooltipBubble);invalidate()
    }
    required init?(coder: NSCoder) {nil}
    deinit {renderQueue.cancelAllOperations();ocrTranslationTask?.cancel();ocrRevealTask?.cancel()}
    private func chrome(_ view: NSView) {
        view.wantsLayer=true;view.layer?.cornerRadius=12;view.layer?.masksToBounds=true
        view.layer?.borderColor=NSColor.white.withAlphaComponent(0.13).cgColor;view.layer?.borderWidth=1
        let material=NSVisualEffectView(frame:view.bounds)
        material.material = .hudWindow;material.blendingMode = .withinWindow;material.state = .active
        material.autoresizingMask=[.width,.height]
        view.addSubview(material,positioned:.below,relativeTo:nil);addSubview(view)
    }
    private func configure(_ field: NSTextField,width: CGFloat) {
        field.frame.size=NSSize(width:width,height:24);field.font = .monospacedSystemFont(ofSize:12,weight:.medium);field.alignment = .center
        field.target=self;field.action = #selector(settingChanged(_:))
    }
    private func setupControls() {
        [header,toolbar,optionsHost].forEach(chrome)
        ocrTranslationScroller.scrollerStyle = .overlay
        ocrTranslationScroller.controlSize = .small
        ocrTranslationScroller.isEnabled=true
        ocrTranslationScroller.target=self;ocrTranslationScroller.action = #selector(scrollOCRTranslation(_:))
        ocrTranslationScroller.identifier=NSUserInterfaceItemIdentifier("ocrTranslationScroller")
        ocrTranslationScroller.setAccessibilityLabel("译文滚动")
        ocrTranslationScroller.isHidden=true;addSubview(ocrTranslationScroller)
        optionsHost.addSubview(optionsScroll);optionsHost.layer?.masksToBounds=true
        moreStyles.font = .systemFont(ofSize:10);moreStyles.textColor = .secondaryLabelColor;moreStyles.alignment = .center
        optionsHost.addSubview(moreStyles)
        optionsScroll.drawsBackground=false;optionsScroll.hasVerticalScroller=true;optionsScroll.hasHorizontalScroller=true;optionsScroll.autohidesScrollers=true;optionsScroll.scrollerStyle = .overlay
        optionsScroll.documentView=options
        appearance=NSAppearance(named:.darkAqua)
        dimensions.font = .monospacedSystemFont(ofSize:9,weight:.semibold);dimensions.textColor = .white
        header.addSubview(dimensions)
        headerRadiusTitle.font = .systemFont(ofSize:8)
        headerRadiusTitle.isBordered=false
        header.addSubview(headerRadiusTitle)
        radius.onTrackingBegan = { [weak self] in self?.document.checkpoint() }
        radius.onTrackingEnded = { [weak self] in self?.invalidate() }
        radius.target=self;radius.action = #selector(settingChanged(_:));radius.isContinuous=true;radius.toolTip="截图圆角（像素）";radius.controlSize = .mini;header.addSubview(radius)
        configure(radiusValue,width:31);radiusValue.font = .monospacedSystemFont(ofSize:8,weight:.medium);radiusValue.toolTip="圆角像素";header.addSubview(radiusValue)
        shadowToggle.target=self;shadowToggle.action = #selector(settingChanged(_:));shadowToggle.controlSize = .mini;shadowToggle.font = .systemFont(ofSize:8);shadowToggle.compactScale=0.70;header.addSubview(shadowToggle)
        let tools: [(ScreenshotEditTool,String,String)] = [(.select,"cursorarrow","移动 / 选择"),(.rectangle,"rectangle","矩形"),(.ellipse,"circle","圆形"),(.line,"line.diagonal","线条"),(.arrow,"arrow.up.right","箭头"),(.pen,"pencil.tip","画笔"),(.mask,"square.fill.on.square.fill","打码"),(.text,"textformat","文本"),(.number,"1.circle","序号"),(.highlight,"viewfinder","高亮")]
        for (kind,symbol,title) in tools {
            let button=icon(symbol,title,action:"tool:"+kind.rawValue)
            toolbar.addSubview(button);toolButtons[kind]=button
        }
        for (action,symbol,title) in [("pin","pin.fill","固定"),("undo","arrow.uturn.backward","撤销"),("ocr","text.viewfinder","OCR"),("translate","translate","翻译"),("cancel","xmark",cancelTitle),("long","rectangle.portrait","长截屏：在框选范围内滚动页面"),("save","square.and.arrow.down","保存"),("copy","checkmark","拷贝至剪贴板")] {
            let button=icon(symbol,title,action:action)
            button.isEnabled=action != "long";toolbar.addSubview(button)
            if action=="ocr" {ocrToolbarButton=button;button.toolTip="OCR 文本选择模式（再次点击退出）"}
            if action=="translate" {translationToolbarButton=button;button.toolTip="识别并翻译文字（使用下方所选语言和翻译服务）"}
        }
        color.color=style.color;color.target=self;color.action = #selector(settingChanged(_:));color.toolTip="标注颜色"
        lineWidth.target=self;lineWidth.action = #selector(settingChanged(_:));lineWidth.toolTip="线条 / 画笔粗细";configure(lineValue,width:38)
        lineWidth.isContinuous=true;lineWidth.onTrackingBegan = { [weak self] in self?.document.checkpoint() };lineWidth.onTrackingEnded = { [weak self] in self?.invalidate() }
        effect.addItems(withTitles:ScreenshotPaintMode.allCases.map(\.title));effect.target=self;effect.action = #selector(settingChanged(_:));effect.toolTip="画笔 / 打码方式"
        effectModeTitle.font = .systemFont(ofSize:8);effectModeTitle.textColor = .labelColor
        fontFamily.addItems(withTitles:["系统字体"]+NSFontManager.shared.availableFontFamilies.sorted());fontFamily.target=self;fontFamily.action = #selector(settingChanged(_:));fontFamily.toolTip="字体"
        fontSize.target=self;fontSize.action = #selector(settingChanged(_:));fontSize.toolTip="字号";configure(fontValue,width:42);fontValue.toolTip="字号（8–144）"
        fontSize.isContinuous=true;fontSize.onTrackingBegan = { [weak self] in self?.document.checkpoint() };fontSize.onTrackingEnded = { [weak self] in self?.invalidate() }
        for button in [bold,italic,underline,textBackground] {button.target=self;button.action = #selector(settingChanged(_:))}
        bold.toolTip="加粗";underline.toolTip="下划线";italic.toolTip="倾斜"
        backgroundColor.color = .white;backgroundColor.target=self;backgroundColor.action = #selector(settingChanged(_:));backgroundColor.toolTip="文本底色"
        textOutlineColor.color = .black;textOutlineColor.target=self;textOutlineColor.action = #selector(settingChanged(_:));textOutlineColor.toolTip="手动选择文字描边颜色"
        numberColor.color = .systemRed;numberColor.target=self;numberColor.action = #selector(settingChanged(_:));numberColor.toolTip="序号圆点与连接线颜色"
        for slider in [textCornerRadius] {slider.target=self;slider.action = #selector(settingChanged(_:));slider.isContinuous=true;slider.toolTip="文本框底色圆角半径";slider.onTrackingBegan = { [weak self] in self?.document.checkpoint() };slider.onTrackingEnded = { [weak self] in self?.invalidate() }}
        configure(textCornerRadiusValue,width:32);textCornerRadiusValue.toolTip="底色圆角半径（0–60）"
        for button in [textRounded,textShadow,textOutline] {button.target=self;button.action = #selector(settingChanged(_:));button.controlSize = .small;button.font = .systemFont(ofSize:10)}
        rectangleOpacity.target=self;rectangleOpacity.action = #selector(settingChanged(_:));rectangleOpacity.isContinuous=true;rectangleOpacity.toolTip="不透明度"
        rectangleOpacity.onTrackingBegan = { [weak self] in self?.document.checkpoint() };rectangleOpacity.onTrackingEnded = { [weak self] in self?.invalidate() }
        numberSize.target=self;numberSize.action = #selector(settingChanged(_:));numberSize.isContinuous=true;numberSize.toolTip="序号圆点大小"
        numberSize.onTrackingBegan = { [weak self] in self?.document.checkpoint() };numberSize.onTrackingEnded = { [weak self] in self?.invalidate() }
        configure(numberSizeValue,width:32);numberSizeValue.toolTip="序号大小（8–80）"
        shapeCornerRadius.target=self;shapeCornerRadius.action = #selector(settingChanged(_:));shapeCornerRadius.isContinuous=true;shapeCornerRadius.toolTip="矩形圆角大小"
        shapeCornerRadius.onTrackingBegan = { [weak self] in self?.document.checkpoint() };shapeCornerRadius.onTrackingEnded = { [weak self] in self?.invalidate() }
        configure(shapeCornerRadiusValue,width:32);shapeCornerRadiusValue.toolTip="圆角大小（0–100）"
        rectangleOpacityTitle.font = .systemFont(ofSize:10);rectangleOpacityTitle.textColor = .white
        rectangleSizeTitle.font = .systemFont(ofSize:10);rectangleSizeTitle.textColor = .white
        rectangleOpacityValue.font = .monospacedSystemFont(ofSize:10,weight:.medium);rectangleOpacityValue.textColor = .white;rectangleOpacityValue.alignment = .right
        configure(rectangleOpacityInput,width:44)
        rectangleOpacityInput.toolTip="矩形不透明度（0–100%）"
        for (index,paletteColor) in Self.rectanglePalette.enumerated() {
            let swatch=NSButton(title:"",target:nil,action:nil)
            swatch.tag=index;swatch.isBordered=false;swatch.wantsLayer=true;swatch.layer?.cornerRadius=10
            swatch.layer?.backgroundColor=paletteColor.cgColor;swatch.toolTip="标注颜色"
            swatch.target=self;swatch.action = #selector(rectanglePaletteClicked(_:))
            rectangleColorButtons.append(swatch)
        }
        for button in [rectangleFill,rectangleRounded] {button.target=self;button.action = #selector(settingChanged(_:));button.controlSize = .small;button.font = .systemFont(ofSize:10);button.state = .on}
        copyOCR.target=self;copyOCR.action = #selector(copyRecognizedText)
        copyOCR.title="复制全部";copyOCR.identifier=NSUserInterfaceItemIdentifier("copyOCRAll")
        status.font = .systemFont(ofSize:12);status.textColor = .white
        for (button,title,action) in [
            (ocrSelectedButton,"复制选中","copyOCRSelection"),
            (ocrTranslateButton,"翻译","translateOCR"),
            (ocrTranslateCopyButton,"翻译并复制","translateAndCopyOCR")
        ] {
            button.title=title;button.isBordered=false;button.font = .systemFont(ofSize:10,weight:.medium)
            button.contentTintColor = .white
            button.identifier=NSUserInterfaceItemIdentifier(action)
            button.target=self;button.action = #selector(ocrButtonClicked(_:))
            options.addSubview(button)
        }
        numberSizeTitle.font = .systemFont(ofSize:10);numberSizeTitle.textColor = .white
        numberColorTitle.font = .systemFont(ofSize:10);numberColorTitle.textColor = .white
        for title in [fontSizeTitle,textCornerRadiusTitle] {title.font = .systemFont(ofSize:10);title.textColor = .white}
        for view in [color,lineWidth,lineValue,effect,effectModeTitle,fontFamily,fontSize,fontValue,bold,italic,underline,textBackground,textRounded,textShadow,textOutline,backgroundColor,textOutlineColor,numberColor,numberColorTitle,textCornerRadius,textCornerRadiusValue,textCornerRadiusTitle,fontSizeTitle,textFontTitle,rectangleOpacity,rectangleOpacityValue,rectangleOpacityInput,rectangleSizeTitle,rectangleOpacityTitle,rectangleFill,rectangleRounded,shapeCornerRadius,shapeCornerRadiusValue,numberSizeTitle,numberSize,numberSizeValue,copyOCR,status] as [NSView] {options.addSubview(view)}
        rectangleColorButtons.forEach(options.addSubview)
        rectangleSectionRules.forEach(options.addSubview)
        options.addSubview(textSectionRule)
        options.addSubview(numberSectionRule)
        for field in [lineValue,fontValue,shapeCornerRadiusValue,textCornerRadiusValue,numberSizeValue,rectangleOpacityInput,radiusValue] {
            field.font = .monospacedSystemFont(ofSize:field === radiusValue ? 8:11,weight:.medium)
            field.isBezeled=false;field.drawsBackground=false
            field.wantsLayer=true;field.layer?.cornerRadius=8;field.layer?.masksToBounds=true
            field.layer?.backgroundColor=ScreenshotEditorChrome.controlFill.cgColor
            field.layer?.borderWidth=0.5;field.layer?.borderColor=NSColor.white.withAlphaComponent(0.13).cgColor
        }
        for label in [rectangleSizeTitle,rectangleOpacityTitle,numberSizeTitle,numberColorTitle,fontSizeTitle,textFontTitle,textCornerRadiusTitle] {
            label.font = .systemFont(ofSize:11);label.textColor = .secondaryLabelColor
        }
        bold.identifier=NSUserInterfaceItemIdentifier("format-bold")
        italic.identifier=NSUserInterfaceItemIdentifier("format-italic")
        underline.identifier=NSUserInterfaceItemIdentifier("format-underline")
        for button in toolbar.subviews.compactMap({$0 as? NSButton}) {
            button.wantsLayer=true;button.layer?.cornerRadius=6
        }
        options.addSubview(ocrSettingsButton)
        ocrSettingsButton.identifier=NSUserInterfaceItemIdentifier("ocrTranslationSettings")
        ocrSettingsButton.target=self;ocrSettingsButton.action = #selector(openOCRTranslationSettings)
        ocrSettingsButton.toolTip="管理系统离线翻译、本地大语言模型和 API 服务"
        for button in [ocrSelectedButton,copyOCR,ocrTranslateButton,ocrTranslateCopyButton,ocrSettingsButton] {
            button.isBordered=false;button.wantsLayer=true;button.layer?.cornerRadius=7
            button.layer?.borderWidth=0.5;button.layer?.borderColor=NSColor.white.withAlphaComponent(0.13).cgColor
            button.layer?.backgroundColor=ScreenshotEditorChrome.controlFill.cgColor
            button.contentTintColor = .white
            button.font = .systemFont(ofSize:10,weight:.medium)
        }
        ocrSelectedButton.toolTip="复制拖动选中的文字（⌘C）"
        copyOCR.toolTip="复制所有已经识别的文字"
        for (popup,id) in [(ocrSourceLanguage,"ocrSourceLanguage"),(ocrTargetLanguage,"ocrTargetLanguage")] {
            popup.identifier=NSUserInterfaceItemIdentifier(id)
            popup.font = .systemFont(ofSize:10);popup.controlSize = .small
            popup.target=self;popup.action = #selector(ocrLanguageChanged(_:))
            popup.addItem(withTitle:popup === ocrSourceLanguage ? "自动识别":"简体中文（默认）")
            popup.lastItem?.representedObject=""
            for (code,name) in ScreenshotOCRTranslationLanguage.supported {
                popup.addItem(withTitle:name);popup.lastItem?.representedObject=code
            }
            popup.toolTip=popup === ocrSourceLanguage ? "原文语言：自动识别或手动选择":"目标语言：中文原文默认译英文，其他默认译简体中文"
            options.addSubview(popup)
        }
        for label in [ocrSourceTitle,ocrTargetTitle,ocrLanguageArrow] {
            label.font = .systemFont(ofSize:10);label.textColor = .secondaryLabelColor
            options.addSubview(label)
        }
        ocrTranslateButton.toolTip="按上方语言翻译原文；已有译文时切换原文/译文"
        ocrTranslateCopyButton.toolTip="按上方语言翻译，并复制完整译文"
        for button in [ocrTranslateButton,ocrTranslateCopyButton] {
            let menu=NSMenu(title:"翻译目标语言")
            for (code,name) in [("", "自动选择目标语言")] +
                ScreenshotOCRTranslationLanguage.supported.map({($0.code,$0.name)}) {
                let item=menu.addItem(withTitle:name,
                                      action:#selector(chooseOCRTranslationTarget(_:)),
                                      keyEquivalent:"")
                item.representedObject=code
                item.target=self
            }
            button.menu=menu
        }
        for (button,symbol) in [(ocrSelectedButton,"selection.pin.in.out"),(copyOCR,"doc.on.doc"),
                                (ocrTranslateButton,"translate"),(ocrTranslateCopyButton,"doc.on.clipboard"),
                                (ocrSettingsButton,"gearshape")] {
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:button.title)?.withSymbolConfiguration(.init(pointSize:10,weight:.medium))
            button.imagePosition = .imageLeading;button.font = .systemFont(ofSize:10,weight:.medium)
        }
        layoutControls()
    }
    private func setupZoomHUD() {
        guard naturalImageSize != nil,zoomHUD.superview == nil else{return}
        chrome(zoomHUD)
        for (label,action,x,width) in [
            ("−","zoomOut",8.0,26.0),("","",38.0,54.0),
            ("+","zoomIn",96.0,26.0),("适应","zoomFit",130.0,64.0),
            ("100%","zoomActual",201.0,64.0),("移动","panMode",269.0,60.0)
        ] {
            if action.isEmpty {
                zoomLabel.frame=NSRect(x:x,y:8,width:width,height:21)
                zoomLabel.font = .monospacedSystemFont(ofSize:12,weight:.medium)
                zoomLabel.alignment = .center;zoomLabel.textColor = .white
                zoomHUD.addSubview(zoomLabel)
            } else {
                let button=NSButton(title:label,target:self,action:#selector(zoomClicked(_:)))
                button.identifier=NSUserInterfaceItemIdentifier(action)
                button.isBordered=false;button.contentTintColor = .white
                button.font = .systemFont(ofSize:12,weight:.medium)
                button.frame=NSRect(x:x,y:5,width:width,height:28)
                button.toolTip = action=="zoomActual" ? "原始大小 (⌘1)" : action=="zoomFit" ? "适应屏幕 (⌘0)" : "缩放 (⌘+ / ⌘−)"
                if action=="panMode" {
                    button.toolTip="切换手形移动模式 (H)；也可按住空格拖动"
                    panButton=button
                }
                zoomHUD.addSubview(button)
            }
        }
        zoomHUD.frame.size=NSSize(width:338,height:38)
    }
    @objc private func zoomClicked(_ sender:NSButton) {
        switch sender.identifier?.rawValue {
        case "zoomIn":zoomViewport(to:viewportZoom*1.25)
        case "zoomOut":zoomViewport(to:viewportZoom/1.25)
        case "zoomFit":fitImageToViewport()
        case "zoomActual":zoomViewport(to:1)
        case "panMode":togglePanTool()
        default:break
        }
    }
    private func togglePanTool() {
        guard naturalImageSize != nil else{return}
        panToolEnabled.toggle()
        panButton?.contentTintColor=panToolEnabled ? .systemCyan:.white
        (panToolEnabled ? NSCursor.openHand:NSCursor.arrow).set()
        window?.invalidateCursorRects(for:self)
    }
    func fitImageToViewport() {
        guard let natural=naturalImageSize else{return}
        let frame=ScreenshotEditorLayout.sourceFrame(imageSize:natural,backingScale:1,canvas:bounds)
        repositionViewport(to:frame)
    }
    func zoomViewport(to requested:CGFloat,focus:NSPoint?=nil) {
        guard let natural=naturalImageSize,!processing else{return}
        let old=document.sourceRect
        let fit=ScreenshotEditorLayout.sourceFrame(imageSize:natural,backingScale:1,canvas:bounds)
        let target=max(min(0.10,fit.width/natural.width),min(8,requested))
        let scale=target/viewportZoom
        guard abs(scale-1)>0.00001 else{return}
        let imageCenterY=ScreenshotEditorLayout.topInset+(bounds.height-ScreenshotEditorLayout.topInset-ScreenshotEditorLayout.bottomInset)/2
        let pivot=focus ?? NSPoint(x:bounds.midX,y:imageCenterY)
        let width=natural.width*target,height=natural.height*target
        let proposed=NSRect(x:pivot.x-(pivot.x-old.minX)*scale,
                            y:pivot.y-(pivot.y-old.minY)*scale,width:width,height:height)
        repositionViewport(to:boundedViewport(proposed))
    }
    private func boundedViewport(_ proposed:NSRect)->NSRect {
        let margin:CGFloat=24
        let left=margin,right=bounds.width-margin
        let top=ScreenshotEditorLayout.topInset
        let bottom=bounds.height-ScreenshotEditorLayout.bottomInset
        let minX=min(left,right-proposed.width),maxX=max(left,right-proposed.width)
        let minY=min(top,bottom-proposed.height),maxY=max(top,bottom-proposed.height)
        return NSRect(x:max(minX,min(maxX,proposed.minX)),
                      y:max(minY,min(maxY,proposed.minY)),
                      width:proposed.width,height:proposed.height)
    }
    private func repositionViewport(to frame:NSRect) {
        guard naturalImageSize != nil,!processing else{return}
        if input != nil {commitText()}
        guard case .none=dragging,input == nil else{return}
        guard document.sourceRect != frame else{return}
        let ready=previewReady
        document.setSourceFrame(frame)
        if ready {
            // Camera-only changes can reposition the already-rendered overlay.
            renderToken=UUID();renderQueue.cancelAllOperations()
            previewSelection=document.selection;completedRenderToken=renderToken
            layoutControls();needsDisplay=true
        } else {scheduleOverlayRender(updateLayout:true)}
    }
    private func icon(_ symbol: String,_ title: String,action: String) -> NSButton {
        let button=NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:title) ?? NSImage(),target:self,action:#selector(buttonClicked(_:)))
        button.identifier=NSUserInterfaceItemIdentifier(action);button.isBordered=false;button.contentTintColor = .white;button.setAccessibilityLabel(title);button.setAccessibilityHelp(title)
        let tracking=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:["screenshotTooltip":title])
        button.addTrackingArea(tracking)
        return button
    }
    override func mouseEntered(with event:NSEvent) {
        guard let title=event.trackingArea?.userInfo?["screenshotTooltip"] as? String else {return}
        tooltipBubble.label.stringValue=title
        let textSize=(title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium)])
        let size=NSSize(width:ceil(textSize.width)+18,height:24)
        let point=convert(event.locationInWindow,from:nil)
        let x=max(4,min(bounds.maxX-size.width-4,point.x-size.width/2))
        let below=point.y+16
        let y=point.y-size.height-16 >= 4 ? point.y-size.height-16 : min(bounds.maxY-size.height-4,below)
        tooltipBubble.frame=NSRect(origin:NSPoint(x:x,y:y),size:size)
        tooltipBubble.isHidden=false
        addSubview(tooltipBubble,positioned:.above,relativeTo:nil)
    }
    override func mouseExited(with event:NSEvent) {
        guard event.trackingArea?.userInfo?["screenshotTooltip"] != nil else {return}
        tooltipBubble.isHidden=true
    }
    override func layout() {super.layout();layoutControls()}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking {removeTrackingArea(pointerTracking)}
        let tracking=NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking);pointerTracking=tracking
    }
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();window?.acceptsMouseMovedEvents=true}
    override func mouseMoved(with event:NSEvent) {
        if spaceHeld || panToolEnabled {NSCursor.openHand.set();return}
        guard case .none=dragging else{return}
        let point=convert(event.locationInWindow,from:nil)
        if ocrMode {cursor(at:point).set();return}
        cursor(at:point).set()
    }
    /// Scroll large, unscaled screenshots inside the dimmed display without
    /// changing the image pixels, selection dimensions or annotation geometry.
    func panHistoryImage(by delta: NSPoint) {
        guard naturalImageSize != nil else{return}
        repositionViewport(to:boundedViewport(document.sourceRect.offsetBy(dx:delta.x,dy:delta.y)))
    }
    override func scrollWheel(with event: NSEvent) {
        if showingOCRTranslation,!event.modifierFlags.contains(.command),
           document.selection.contains(convert(event.locationInWindow,from:nil)) {
            let factor:CGFloat=event.hasPreciseScrollingDeltas ? 1:12
            setOCRTranslationScroll(ocrTranslationScrollOffset-event.scrollingDeltaY*factor)
            return
        }
        guard naturalImageSize != nil else {super.scrollWheel(with:event);return}
        let factor:CGFloat=event.hasPreciseScrollingDeltas ? 1:12
        if event.modifierFlags.contains(.command) {
            zoomViewport(to:viewportZoom*exp(event.scrollingDeltaY*factor*0.004),
                         focus:convert(event.locationInWindow,from:nil))
        } else {
            panHistoryImage(by:NSPoint(x:event.scrollingDeltaX*factor,y:event.scrollingDeltaY*factor))
        }
    }
    override func magnify(with event:NSEvent) {
        guard naturalImageSize != nil else {super.magnify(with:event);return}
        zoomViewport(to:viewportZoom*max(0.1,1+event.magnification),
                     focus:convert(event.locationInWindow,from:nil))
    }
    private var activeTool: ScreenshotEditTool { selectedID.flatMap { id in document.annotations.first{$0.id==id}?.tool } ?? tool }
    private func layoutControls() {
        updateOCRTranslationScroller()
        if naturalImageSize != nil {
            zoomHUD.frame.origin=NSPoint(x:max(8,bounds.width-zoomHUD.frame.width-24),y:20)
            zoomLabel.stringValue="\(Int((viewportZoom*100).rounded()))%"
        }
        let rect=document.selection,headerWidth:CGFloat=318
        // The top capture controls share the 8pt text, 72x17 slider,
        // 31x17 rounded numeric field and 70%-scale toggle of the
        // compact annotation inspectors. The missing radius title is
        // restored and always appears immediately before its slider.
        let compactHeaderWidth=min(headerWidth,max(1,bounds.width-8))
        let headerWrap=compactHeaderWidth<headerWidth
        let headerHeight:CGFloat=headerWrap ? 52:32
        header.frame=NSRect(x:max(4,min(rect.minX,bounds.width-compactHeaderWidth-4)),
                            y:max(4,rect.minY-headerHeight-4),
                            width:compactHeaderWidth,height:headerHeight)
        if headerWrap {
            // The 205pt-wide canvas can still access every control without
            // shrinking the native hit areas or losing the radius caption.
            dimensions.frame=NSRect(x:12,y:7,width:90,height:14)
            headerRadiusTitle.frame=NSRect(x:12,y:28,width:25,height:17)
            radius.frame=NSRect(x:40,y:28,width:72,height:17)
            radiusValue.frame=NSRect(x:118,y:28,width:31,height:17)
            shadowToggle.frame=NSRect(x:153,y:28,width:43,height:17)
        } else {
            dimensions.frame=NSRect(x:12,y:9,width:90,height:14)
            headerRadiusTitle.frame=NSRect(x:106,y:7,width:25,height:17)
            radius.frame=NSRect(x:135,y:7,width:72,height:17)
            radiusValue.frame=NSRect(x:214,y:7,width:31,height:17)
            shadowToggle.frame=NSRect(x:260,y:7,width:43,height:17)
        }
        // Reflow only geometry, never tool order or event handlers.
        // Narrow canvases use an extra row rather than clipping actions.
        let buttons=toolbar.subviews.compactMap{$0 as? NSButton}
        let compact=ScreenshotEditorToolbarLayout.geometry(availableWidth:bounds.width-8,
                                                            buttonCount:buttons.count)
        toolbar.frame.size=compact.size
        for (button,frame) in zip(buttons,compact.frames) {button.frame=frame}
        let toolbarWidth=toolbar.frame.width
        let isText=[ScreenshotEditTool.text,.number].contains(activeTool)
        let below=rect.maxY+10
        let fullHeight:CGFloat=(isText ? 206:130)+(compact.size.height-46)
        var toolbarY=below+fullHeight <= bounds.maxY-4 ? below : max(4,rect.minY-fullHeight-42)
        toolbar.frame.origin=NSPoint(x:max(4,min(rect.minX,bounds.width-toolbarWidth-4)),y:toolbarY)
        // Size-preserving compact flow: all interactive controls keep the
        // exact dimensions of the previous grouped panels. Removing section
        // headers and packing controls into horizontal rows is what reduces
        // the overall footprint; controls are never scaled down.
        for view in options.subviews {view.isHidden=true}
        let compactShape=Self.compactInspectorTools.contains(activeTool) && !ocrMode && !processing
        let compactHighlight=activeTool == .highlight && !ocrMode && !processing
        let compactDrawing=compactShape || compactHighlight
        let compactTypography=[ScreenshotEditTool.text,.number].contains(activeTool) && !ocrMode && !processing
        // Text and Number share every typographic/effect control. Number
        // additionally exposes badge colour and size in the lower-right.
        textRounded.title=compactTypography ? "圆角":"圆角底色"
        color.compactCircularMode=compactShape || compactTypography
        backgroundColor.compactCircularMode=compactTypography
        textOutlineColor.compactCircularMode=compactTypography
        numberColor.compactCircularMode=compactTypography && activeTool == .number
        fontSizeTitle.stringValue=compactTypography ? "大小":"字号"
        fontFamily.controlSize=compactTypography ? .small:.regular
        fontFamily.font = .systemFont(ofSize:compactTypography ? 9:12)
        switch activeTool {
        case .ellipse:rectangleOpacityInput.toolTip="圆形不透明度（0–100%）"
        case .rectangle:rectangleOpacityInput.toolTip="矩形不透明度（0–100%）"
        case .text:rectangleOpacityInput.toolTip="文字不透明度（0–100%）"
        case .number:rectangleOpacityInput.toolTip="序号不透明度（0–100%）"
        case .highlight:rectangleOpacityInput.toolTip="高亮不透明度（0–100%）"
        default:rectangleOpacityInput.toolTip="不透明度（0–100%）"
        }
        effect.controlSize=compactShape ? .small:.regular
        effect.font = compactShape ? .systemFont(ofSize:10):.systemFont(ofSize:12)
        // Restore native typography outside these compact inspectors so
        // unmodified tools retain their established layout and controls.
        for label in [rectangleSizeTitle,rectangleOpacityTitle] {
            label.font = .systemFont(ofSize:compactDrawing || compactTypography ? 8:11)
            // NSButton's "实心 / 圆角" captions use labelColor.
            // Compact drawing inspectors share the primary-colour captions;
            // preserve secondary labels for the remaining tools.
            label.textColor = compactDrawing || compactTypography ? .labelColor : .secondaryLabelColor
        }
        for field in [lineValue,rectangleOpacityInput,shapeCornerRadiusValue] {
            field.font = .monospacedSystemFont(ofSize:compactDrawing || compactTypography ? 8:11,weight:.medium)
        }
        for label in [fontSizeTitle,textFontTitle,textCornerRadiusTitle] {
            label.font = .systemFont(ofSize:compactTypography ? 8:11)
            label.textColor = compactTypography ? .labelColor:.secondaryLabelColor
        }
        for field in [fontValue,textCornerRadiusValue] {
            field.font = .monospacedSystemFont(ofSize:compactTypography ? 8:11,weight:.medium)
        }
        for slider in [lineWidth,rectangleOpacity,shapeCornerRadius] {
            slider.controlSize=compactShape || (compactHighlight && slider !== lineWidth)
                || (compactTypography && slider === rectangleOpacity) ? .mini:.regular
        }
        for slider in [fontSize,textCornerRadius,numberSize] {
            slider.controlSize=compactTypography ? .mini:.regular
        }
        for toggle in [rectangleFill,rectangleRounded] {
            toggle.compactScale=compactDrawing ? 0.70:1
        }
        for toggle in [textBackground,textRounded,textOutline,textShadow] {
            toggle.compactScale=compactTypography ? 0.70:1
        }
        for label in [numberColorTitle,numberSizeTitle] {
            label.font = .systemFont(ofSize:compactTypography ? 8:11)
            label.textColor=compactTypography ? .labelColor:.secondaryLabelColor
        }
        numberSizeValue.font = .monospacedSystemFont(ofSize:compactTypography ? 8:11,weight:.medium)
        let outerInset:CGFloat=8,spacing:CGFloat=8,rowPitch:CGFloat=28
        let maximumWidth:CGFloat = ocrMode ? 394 :
            (Self.compactInspectorTools.contains(activeTool) ? 568 :
             ([ScreenshotEditTool.text,.number].contains(activeTool) ? 468 :
             (activeTool == .highlight ? 182 : 820)))
        let availableWidth=max(120,min(maximumWidth,bounds.width-16))
        let usableWidth=availableWidth-outerInset*2
        // Restore the normal screenshot feedback style after leaving OCR;
        // its compact status caption is only used inside OCR mode.
        status.font = .systemFont(ofSize:ocrMode ? 10:12)
        status.textColor=ocrMode ? .secondaryLabelColor:.white
        status.lineBreakMode=ocrMode ? .byTruncatingTail:.byClipping
        status.toolTip=ocrMode ? status.stringValue:nil
        var cursorX:CGFloat=outerInset, row=0, rightmost:CGFloat=0, hasContent=false
        var explicitPanelSize:NSSize?

        func place(_ view:NSView,_ x:CGFloat,_ top:CGFloat,_ width:CGFloat,_ height:CGFloat=24) {
            view.frame=NSRect(x:x,y:top,width:width,height:height)
            view.isHidden=false
        }
        typealias CompactControl=(NSView,NSRect)
        func unit(_ width:CGFloat,_ controls:[CompactControl]) {
            guard !controls.isEmpty else{return}
            let occupied=cursorX-outerInset
            if occupied>0 && occupied+spacing+width > usableWidth {
                row+=1
                cursorX=outerInset
            } else if occupied>0 {
                cursorX+=spacing
            }
            let originY:CGFloat=1+CGFloat(row)*rowPitch
            for (control,position) in controls {
                place(control,cursorX+position.minX,originY+position.minY,
                      position.width,position.height)
            }
            rightmost=max(rightmost,cursorX+width)
            cursorX+=width
            hasContent=true
        }
        func fieldRow(_ label:NSTextField,_ slider:NSSlider,_ value:NSTextField) -> [CompactControl] {
            [
                (label,NSRect(x:0,y:4,width:62,height:18)),
                (slider,NSRect(x:64,y:0,width:151,height:24)),
                (value,NSRect(x:221,y:0,width:44,height:24))
            ]
        }
        if ocrMode {
            // Recognition starts when OCR mode opens. Copy and translation
            // actions remain stable while Vision is processing.
            hasContent=true
            if status.stringValue.isEmpty {
                status.stringValue="拖动选择文字后复制，或复制全部。"
            }
            status.toolTip=status.stringValue
            let translating=ocrTranslationTask != nil
            for button in [ocrSelectedButton,copyOCR,ocrTranslateButton,ocrTranslateCopyButton] {
                button.isEnabled = !processing && !translating
            }
            ocrSourceLanguage.isEnabled = !translating;ocrTargetLanguage.isEnabled = !translating
            refreshOCRLanguages()
            if bounds.width >= 402 {
                explicitPanelSize=NSSize(width:394,height:84)
                place(ocrSourceTitle,8,9,28,14);place(ocrSourceLanguage,36,4,138,24)
                place(ocrLanguageArrow,182,9,18,14)
                place(ocrTargetTitle,204,9,28,14);place(ocrTargetLanguage,232,4,154,24)
                place(ocrSelectedButton,8,34,84,22)
                place(copyOCR,100,34,84,22)
                place(ocrTranslateButton,192,34,88,22)
                place(ocrTranslateCopyButton,288,34,98,22)
                place(status,8,62,278,14)
                place(ocrSettingsButton,294,59,92,20)
            } else {
                explicitPanelSize=NSSize(width:194,height:140)
                place(ocrSourceTitle,8,9,28,14);place(ocrSourceLanguage,36,4,150,24)
                place(ocrTargetTitle,8,37,28,14);place(ocrTargetLanguage,36,32,150,24)
                place(ocrSelectedButton,8,62,84,22)
                place(copyOCR,100,62,84,22)
                place(ocrTranslateButton,8,90,82,22)
                place(ocrTranslateCopyButton,98,90,88,22)
                place(status,8,118,80,14)
                place(ocrSettingsButton,98,115,88,20)
            }
        } else if processing || !ocrBoxes.isEmpty || !status.stringValue.isEmpty {
            if !ocrBoxes.isEmpty {
                unit(150,[(copyOCR,NSRect(x:0,y:1,width:150,height:24))])
            }
            unit(180,[(status,NSRect(x:0,y:1,width:180,height:24))])
        } else if activeTool != .select {
            if Self.compactInspectorTools.contains(activeTool) {
                // All four stroke tools reuse the exact numeric and colour
                // columns of rectangle/ellipse. Pen and mask add a short
                // effect selector; line and arrow need no third column.
                // ~70% of the original native dimensions, with native actions.
                // Row spacing shrinks from 8pt to 4pt (17pt + 4pt).
                // The two numeric rows share the same slider origin.
                let hasEffect=[ScreenshotEditTool.pen,.mask].contains(activeTool)
                let panelWidth:CGFloat
                switch activeTool {
                case .rectangle:panelWidth=460
                case .ellipse:panelWidth=344
                case .pen,.mask:panelWidth=424
                default:panelWidth=280
                }
                explicitPanelSize=NSSize(width:panelWidth,height:52)
                hasContent=true
                // NSTextField's baseline sits about 2pt above the matching
                // NSString-drawn switch captions at equal frame Y.
                place(rectangleSizeTitle,12,9.5,42,17)
                place(lineWidth,60,7,72,17)
                place(lineValue,138,7,31,17)
                place(rectangleOpacityTitle,12,30.5,43,17)
                place(rectangleOpacity,60,28,72,17)
                place(rectangleOpacityInput,138,28,31,17)

                // 4 + 3 + 1 colour grid: size, row and column pitch reduced.
                for (index,button) in rectangleColorButtons.enumerated() {
                    let column=index % 4, row=index / 4
                    place(button,191+CGFloat(column)*20,
                          7+CGFloat(row)*21,16,16)
                    button.layer?.cornerRadius=8
                    button.layer?.backgroundColor=displayedPalette[index].cgColor
                    button.layer?.borderWidth=color.color.isEqual(displayedPalette[index]) ? 1.4:0.6
                    button.layer?.borderColor=(color.color.isEqual(displayedPalette[index]) ?
                        NSColor.white:NSColor.white.withAlphaComponent(0.34)).cgColor
                }
                place(color,251,28,16,16)

                // Toggles are compact-drawn at 70% scale. Text-to-switch
                // separation is 9pt instead of the former ~30pt.
                if [.rectangle,.ellipse].contains(activeTool) {
                    place(rectangleFill,290,7,43,17)
                }
                if activeTool == .rectangle {
                    place(rectangleRounded,290,28,43,17)
                    place(shapeCornerRadius,338,28,72,17)
                    place(shapeCornerRadiusValue,416,28,31,17)
                }

                place(rectangleSectionRules[0],178,6,1,40)
                if [.rectangle,.ellipse].contains(activeTool) || hasEffect {
                    place(rectangleSectionRules[1],279,6,1,40)
                }
                if hasEffect {
                    place(effectModeTitle,289,20,24,17)
                    place(effect,317,16,94,21)
                }
            } else if [.text,.number].contains(activeTool) {
                // Shared compact typography inspector. Number adds its own
                // colour and badge-size controls in the lower-right region;
                // every shared control keeps exactly the same frame as Text.
                explicitPanelSize=NSSize(width:468,height:114)
                hasContent=true
                place(rectangleOpacityTitle,12,9.5,43,17)
                place(rectangleOpacity,60,7,72,17)
                place(rectangleOpacityInput,138,7,31,17)
                place(fontSizeTitle,12,30.5,42,17)
                place(fontSize,60,28,72,17)
                place(fontValue,138,28,31,17)
                for (index,button) in rectangleColorButtons.enumerated() {
                    let column=index%4,row=index/4
                    place(button,191+CGFloat(column)*20,
                          7+CGFloat(row)*21,16,16)
                    button.layer?.cornerRadius=8
                    button.layer?.backgroundColor=displayedPalette[index].cgColor
                    button.layer?.borderWidth=color.color.isEqual(displayedPalette[index]) ? 1.4:0.6
                    button.layer?.borderColor=(color.color.isEqual(displayedPalette[index]) ?
                        NSColor.white:NSColor.white.withAlphaComponent(0.34)).cgColor
                }
                place(color,251,28,16,16)
                place(textFontTitle,291,9.5,23,17)
                place(fontFamily,318,6,136,21)
                place(bold,291,29,46,17)
                place(underline,345,29,46,17)
                place(italic,399,29,46,17)
                place(rectangleSectionRules[0],178,6,1,40)
                place(rectangleSectionRules[1],279,6,1,40)
                place(textSectionRule,12,55,444,1)

                // The second group follows the diagram: top row holds
                // background + rounded-background radius; below is
                // OUTLINE first and SHADOW second (reversed from old UI).
                place(textBackground,12,65,45,17)
                place(backgroundColor,62,65,18,18)
                // Match the rectangle inspector's one-label arrangement:
                // "圆角" toggle -> 5pt gap -> slider -> 6pt gap -> value.
                // No duplicate corner-radius title between the controls.
                place(textRounded,103,65,45,17)
                place(textCornerRadius,153,65,72,17)
                place(textCornerRadiusValue,231,65,31,17)
                place(textOutline,12,88,45,17)
                place(textOutlineColor,62,88,18,18)
                place(textShadow,103,88,45,17)
                if activeTool == .number {
                    // Red-marked lower-right space: number-specific controls.
                    // One compact row each, without displacing text effects.
                    place(numberSectionRule,279,63,1,43)
                    place(numberColorTitle,292,67.5,46,17)
                    place(numberColor,342,65,18,18)
                    place(numberSizeTitle,292,90.5,46,17)
                    place(numberSize,342,88,72,17)
                    place(numberSizeValue,422,88,31,17)
                }
            } else if activeTool == .highlight {
                // Highlight uses a darkened outside mask, not a coloured
                // stroke. Reuse rectangle's visual language without
                // presenting colour or line-size controls that do nothing.
                // Both 72pt sliders and 31pt inputs align across two rows.
                explicitPanelSize=NSSize(width:182,height:52)
                hasContent=true
                place(rectangleOpacityTitle,12,9.5,43,17)
                place(rectangleOpacity,60,7,72,17)
                place(rectangleOpacityInput,138,7,31,17)
                place(rectangleRounded,12,28,43,17)
                place(shapeCornerRadius,60,28,72,17)
                place(shapeCornerRadiusValue,138,28,31,17)
            } else {
                var palette:[CompactControl]=[]
                for (index,button) in rectangleColorButtons.enumerated() {
                    palette.append((button,NSRect(x:CGFloat(index)*25,y:3,width:20,height:20)))
                    button.layer?.cornerRadius=6
                    button.layer?.backgroundColor=displayedPalette[index].cgColor
                    button.layer?.borderWidth=color.color.isEqual(displayedPalette[index]) ? 2:0.5
                    button.layer?.borderColor=(color.color.isEqual(displayedPalette[index]) ?
                                                 NSColor.white:NSColor.white.withAlphaComponent(0.3)).cgColor
                }
                palette.append((color,NSRect(x:176,y:1,width:46,height:24)))
                unit(222,palette)
                // For shapes, keep the "filled" toggle beside the palette.
                // The size+opacity pair then packs into the next short row.
                if [.rectangle,.ellipse].contains(activeTool) {
                    unit(110,[(rectangleFill,NSRect(x:0,y:1,width:110,height:24))])
                }
                unit(265,fieldRow(rectangleOpacityTitle,rectangleOpacity,rectangleOpacityValue))
                if !isText {
                    unit(265,fieldRow(rectangleSizeTitle,lineWidth,lineValue))
                }
                if [.pen,.mask].contains(activeTool) {
                    unit(564,[(effect,NSRect(x:0,y:0,width:564,height:26))])
                }
                if activeTool == .rectangle {
                        unit(430,[
                            (rectangleRounded,NSRect(x:0,y:1,width:82,height:24)),
                            (shapeCornerRadius,NSRect(x:90,y:0,width:288,height:24)),
                            (shapeCornerRadiusValue,NSRect(x:386,y:0,width:44,height:24))
                        ])
                }
                if isText {
                    unit(534,[
                        (fontFamily,NSRect(x:0,y:0,width:166,height:26)),
                        (fontSizeTitle,NSRect(x:172,y:4,width:28,height:18)),
                        (fontSize,NSRect(x:204,y:0,width:142,height:26)),
                        (fontValue,NSRect(x:350,y:0,width:44,height:26)),
                        (bold,NSRect(x:400,y:0,width:42,height:26)),
                        (italic,NSRect(x:446,y:0,width:42,height:26)),
                        (underline,NSRect(x:492,y:0,width:42,height:26))
                    ])
                    if activeTool == .number {
                        unit(546,[
                            (numberColorTitle,NSRect(x:0,y:4,width:70,height:18)),
                            (numberColor,NSRect(x:76,y:0,width:46,height:26)),
                            (numberSizeTitle,NSRect(x:130,y:4,width:58,height:18)),
                            (numberSize,NSRect(x:194,y:0,width:300,height:26)),
                            (numberSizeValue,NSRect(x:502,y:0,width:44,height:26))
                        ])
                    }
                    unit(530,[
                        (textBackground,NSRect(x:0,y:1,width:74,height:24)),
                        (backgroundColor,NSRect(x:80,y:0,width:46,height:26)),
                        (textRounded,NSRect(x:134,y:1,width:102,height:24)),
                        (textCornerRadiusTitle,NSRect(x:242,y:4,width:28,height:18)),
                        (textCornerRadius,NSRect(x:274,y:0,width:206,height:26)),
                        (textCornerRadiusValue,NSRect(x:486,y:0,width:44,height:26))
                    ])
                    unit(238,[
                        (textShadow,NSRect(x:0,y:1,width:94,height:24)),
                        (textOutline,NSRect(x:100,y:1,width:86,height:24)),
                        (textOutlineColor,NSRect(x:192,y:0,width:46,height:26))
                    ])
                }
            }
        }

        let compactWidth=explicitPanelSize?.width ?? max(0,rightmost+outerInset)
        let compactHeight=explicitPanelSize?.height ?? (CGFloat(row+1)*26+CGFloat(row)*2+2)
        let visibleWidth=min(compactWidth,max(80,bounds.width-8))
        options.frame=NSRect(x:0,y:0,width:compactWidth,height:compactHeight)
        optionsHost.isHidden = !hasContent
        // The height estimate is based on actual rows, not the old tall cards.
        let groupHeight=toolbar.frame.height+4+compactHeight
        toolbarY=below+groupHeight <= bounds.maxY-4 ? below :
            max(4,rect.minY-groupHeight-10)
        toolbar.frame.origin=NSPoint(x:max(4,min(rect.minX,bounds.width-toolbarWidth-4)),y:toolbarY)
        let panelTop=toolbarY+toolbar.frame.height+4
        let panelHeight=min(compactHeight,max(26,bounds.maxY-panelTop-4))
        optionsHost.frame=NSRect(x:max(4,min(toolbar.frame.minX,bounds.width-visibleWidth-4)),
                                 y:panelTop,width:visibleWidth,height:panelHeight)
        let footer:CGFloat=compactHeight>panelHeight ? 22:0
        moreStyles.isHidden=footer==0
        moreStyles.frame=NSRect(x:12,y:3,width:max(0,visibleWidth-24),height:16)
        // Preserve horizontal navigation for fixed-size controls that are
        // wider than a narrow editor window; overlay scrollers auto-hide.
        // Borderless scroll view must fill the compact host exactly. Leaving
        // a 1pt inset on each edge clipped the last row of 26pt controls.
        optionsScroll.frame=NSRect(x:0,y:footer,width:max(1,visibleWidth),
                                   height:max(1,panelHeight-footer))
        let styleID=ocrMode ? "ocr":activeTool.rawValue
        if displayedStyle != styleID {optionsScroll.contentView.scroll(to:.zero);displayedStyle=styleID}
        rectangleOpacity.doubleValue=Double(style.opacity*100)
        rectangleOpacityValue.stringValue="\(Int((style.opacity*100).rounded()))%"
        rectangleOpacityInput.stringValue=String(Int((style.opacity*100).rounded()))
        shapeCornerRadius.doubleValue=Double(style.cornerRadius);shapeCornerRadiusValue.stringValue=String(Int(style.cornerRadius.rounded()))
        rectangleFill.state=style.isFilled ? .on:.off;rectangleRounded.state=style.hasRoundedCorners ? .on:.off
        let pixels=document.pixelSize;dimensions.stringValue="\(Int(pixels.width)) × \(Int(pixels.height))"
        // Fixed slider range plus inverse smoothstep keeps the radius stable as the crop changes.
        let radiusPixels=Double(document.cornerRadius*CGFloat(document.raster.image.width)/document.sourceRect.width)
        if !radius.isTrackingRadius { radius.doubleValue=ScreenshotRadiusCurve.position(for:radiusPixels,maximum:radius.maxValue) }
        radiusValue.stringValue=String(Int(radiusPixels.rounded()));shadowToggle.state=document.shadow ? .on : .off
        for (kind,button) in toolButtons {
            let selected=kind==tool && !ocrMode
            button.contentTintColor=selected ? ScreenshotEditorChrome.accent:.white
            button.layer?.backgroundColor=(selected ? ScreenshotEditorChrome.accent.withAlphaComponent(0.21):NSColor.clear).cgColor
        }
        for (button,selected) in [(ocrToolbarButton,ocrMode && !translationMode),
                                  (translationToolbarButton,ocrMode && translationMode)] {
            button?.contentTintColor=selected ? ScreenshotEditorChrome.accent:.white
            button?.layer?.backgroundColor=(selected ? ScreenshotEditorChrome.accent.withAlphaComponent(0.21):NSColor.clear).cgColor
        }
        if let input,let id=inputID,let annotation=document.annotations.first(where:{$0.id==id}) {
            input.frame=annotation.textRect;input.font=annotation.font;input.textColor=annotation.color
            input.wantsLayer=true;input.isBordered=false;input.drawsBackground=false
            input.layer?.backgroundColor=(annotation.background ? annotation.backgroundColor : NSColor(calibratedWhite:0.15,alpha:0.95)).cgColor
            input.layer?.cornerRadius=annotation.background && annotation.hasRoundedCorners ? min(annotation.cornerRadius,min(annotation.textRect.width,annotation.textRect.height)/2):0
            input.layer?.masksToBounds=true
        }
    }
    private func snapshotDocument() -> ScreenshotEditDocument {
        let result=ScreenshotEditDocument(raster:document.raster,viewSize:document.viewSize,selection:document.selection,sourceRect:document.sourceRect,effectCache:document.effectCache)
        result.annotations=document.annotations;result.cornerRadius=document.cornerRadius;result.shadow=document.shadow;return result
    }
    private func scheduleOverlayRender(updateLayout:Bool) {
        renderToken=UUID();let token=renderToken,copy=snapshotDocument()
        renderQueue.cancelAllOperations()
        let operation=BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation] in
            guard operation?.isCancelled == false else {return}
            let result=copy.renderOverlay()
            DispatchQueue.main.async { [weak self] in guard let self,self.renderToken==token,!self.finished else{return};self.preview=result;self.previewSelection=copy.selection;self.completedRenderToken=token;self.needsDisplay=true }
        }
        renderQueue.addOperation(operation)
        if updateLayout {layoutControls()}
        needsDisplay=true
    }
    private func updateOverlayDuringDrag() {
        renderToken=UUID()
        renderQueue.cancelAllOperations()
        guard let current=document.renderOverlay() else {scheduleOverlayRender(updateLayout:false);return}
        preview=current;previewSelection=document.selection;completedRenderToken=renderToken;needsDisplay=true
    }
    private func invalidate() {
        clearOCRTranslation()
        ocrGeneration=UUID()
        ocrText.clear();ocrMode=false
        ocrBoxes=[]
        scheduleOverlayRender(updateLayout:true)
    }
    func selectTool(_ next: ScreenshotEditTool) {
        if ocrMode {exitOCRMode()}
        commitText()
        ocrGeneration=UUID();ocrMode=false
        ocrText.clear();ocrBoxes=[]
        selectedID=nil
        if next != .select {style=perToolStyles[next] ?? restoreAnnotationStyle(for:next)}
        tool=next;status.stringValue="";syncStyle();layoutControls();window?.makeFirstResponder(self);needsDisplay=true
    }
    @objc private func buttonClicked(_ sender: NSButton) {
        guard let action=sender.identifier?.rawValue else{return}
        if action.hasPrefix("tool:"),let next=ScreenshotEditTool(rawValue:String(action.dropFirst(5))) {selectTool(next)}
        else {performAction(action)}
    }
    private func syncStyle() {
        if let id=selectedID,let item=document.annotations.first(where:{$0.id==id}) {
            style=item
            if naturalImageSize != nil {style.scaleGeometry(by:1/viewportZoom)}
        }
        color.color=style.color;lineWidth.doubleValue=Double(style.width);lineValue.stringValue=String(Int(style.width));effect.selectItem(at:ScreenshotPaintMode.allCases.firstIndex(of:style.mode) ?? 0)
        rectangleOpacity.doubleValue=Double(style.opacity*100);rectangleOpacityValue.stringValue="\(Int((style.opacity*100).rounded()))"
        rectangleOpacityInput.stringValue=String(Int((style.opacity*100).rounded()))
        numberSize.doubleValue=Double(style.numberSize);numberSizeValue.stringValue=String(Int(style.numberSize.rounded()))
        numberColor.color=style.numberColor
        rectangleFill.state=style.isFilled ? .on:.off;rectangleRounded.state=style.hasRoundedCorners ? .on:.off
        fontSize.doubleValue=Double(style.fontSize);fontValue.stringValue=String(Int(style.fontSize));bold.state=style.bold ? .on : .off;italic.state=style.italic ? .on : .off;underline.state=style.underline ? .on : .off;textBackground.state=style.background ? .on : .off;backgroundColor.color=style.backgroundColor
        textRounded.state=style.hasRoundedCorners ? .on:.off;textCornerRadius.doubleValue=Double(style.cornerRadius);textCornerRadiusValue.stringValue=String(Int(style.cornerRadius.rounded()))
        textShadow.state=style.textShadow ? .on:.off;textOutline.state=style.textOutline ? .on:.off
        textOutlineColor.color=style.textOutlineCustom ? style.textOutlineColor : automaticTextOutlineColor(style.color)
        fontFamily.selectItem(withTitle:style.fontName.isEmpty ? "系统字体" : style.fontName)
    }
    private func automaticTextOutlineColor(_ color:NSColor)->NSColor {
        let rgb=color.usingColorSpace(.sRGB) ?? color
        return 0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent > 0.45 ? .black:.white
    }
    private func shapePreferenceKey(for tool:ScreenshotEditTool)->String? {
        switch tool {case .rectangle:return "screenshotEditor.annotationStyle.rectangle";case .ellipse:return "screenshotEditor.annotationStyle.ellipse";default:return nil}
    }
    private func annotationPreferenceKey(for tool:ScreenshotEditTool)->String {"screenshotEditor.annotationStyle.\(tool.rawValue)"}
    private func restoreAnnotationStyle(for tool:ScreenshotEditTool)->ScreenshotAnnotation {
        guard let values=preferences.dictionary(forKey:annotationPreferenceKey(for:tool)) else {
            return shapePreferenceKey(for:tool) == nil ? ScreenshotAnnotation(tool:tool,start:.zero,end:.zero,width:2) : restoreLegacyShapeStyle(for:tool)
        }
        var restored=ScreenshotAnnotation(tool:tool,start:.zero,end:.zero,width:CGFloat(max(1,min(80,(values["width"] as? Double) ?? 2))))
        restored.opacity=CGFloat(max(0,min(1,(values["opacity"] as? Double) ?? 1)))
        restored.isFilled=(values["filled"] as? Bool) ?? false
        restored.hasRoundedCorners=(values["rounded"] as? Bool) ?? false
        restored.cornerRadius=CGFloat(max(0,min([.text,.number].contains(tool) ? 60:100,(values["cornerRadius"] as? Double) ?? 15)))
        restored.mode=ScreenshotPaintMode(rawValue:(values["mode"] as? String) ?? "solid") ?? .solid
        restored.fontName=(values["fontName"] as? String) ?? ""
        restored.fontSize=CGFloat(max(8,min(144,(values["fontSize"] as? Double) ?? 20)))
        restored.bold=(values["bold"] as? Bool) ?? false;restored.italic=(values["italic"] as? Bool) ?? false;restored.underline=(values["underline"] as? Bool) ?? false
        restored.background=(values["background"] as? Bool) ?? false
        restored.hasRoundedCorners=(values["textRounded"] as? Bool) ?? false
        restored.textShadow=(values["textShadow"] as? Bool) ?? false
        restored.textOutline=(values["textOutline"] as? Bool) ?? false
        restored.textOutlineCustom=(values["textOutlineCustom"] as? Bool) ?? false
        restored.numberSize=CGFloat(max(8,min(80,(values["numberSize"] as? Double) ?? 20)))
        let components=(values["color"] as? [Double]) ?? []
        if components.count==4 {restored.color=NSColor(srgbRed:components[0],green:components[1],blue:components[2],alpha:components[3])}
        let numberComponents=(values["numberColor"] as? [Double]) ?? []
        if numberComponents.count==4 {restored.numberColor=NSColor(srgbRed:numberComponents[0],green:numberComponents[1],blue:numberComponents[2],alpha:numberComponents[3])} else if tool == .number {restored.numberColor=restored.color}
        let backgroundComponents=(values["backgroundColor"] as? [Double]) ?? []
        if backgroundComponents.count==4 {restored.backgroundColor=NSColor(srgbRed:backgroundComponents[0],green:backgroundComponents[1],blue:backgroundComponents[2],alpha:backgroundComponents[3])}
        let outlineComponents=(values["textOutlineColor"] as? [Double]) ?? []
        if outlineComponents.count==4 {restored.textOutlineColor=NSColor(srgbRed:outlineComponents[0],green:outlineComponents[1],blue:outlineComponents[2],alpha:outlineComponents[3])}
        return restored
    }
    private func restoreLegacyShapeStyle(for tool:ScreenshotEditTool)->ScreenshotAnnotation {
        var restored=ScreenshotAnnotation(tool:tool,start:.zero,end:.zero,width:2)
        restored.cornerRadius=15;restored.hasRoundedCorners=false
        guard let key=shapePreferenceKey(for:tool),let values=preferences.dictionary(forKey:key) else{return restored}
        restored.width=CGFloat(max(1,min(80,(values["width"] as? Double) ?? 2)))
        restored.opacity=CGFloat(max(0,min(1,(values["opacity"] as? Double) ?? 1)))
        restored.isFilled=(values["filled"] as? Bool) ?? false
        restored.hasRoundedCorners=(tool == .rectangle) && ((values["rounded"] as? Bool) ?? false)
        restored.cornerRadius=CGFloat(max(0,min(100,(values["cornerRadius"] as? Double) ?? 15)))
        let components=(values["color"] as? [Double]) ?? []
        if components.count==4 {restored.color=NSColor(srgbRed:components[0],green:components[1],blue:components[2],alpha:components[3])}
        return restored
    }
    private func persistShapeStyle() {
        guard let key=shapePreferenceKey(for:activeTool) else{return}
        let color=style.color.usingColorSpace(.sRGB) ?? style.color
        preferences.set(["width":Double(style.width),"opacity":Double(style.opacity),"filled":style.isFilled,"rounded":style.hasRoundedCorners,"cornerRadius":Double(style.cornerRadius),"color":[Double(color.redComponent),Double(color.greenComponent),Double(color.blueComponent),Double(color.alphaComponent)]],forKey:key)
    }
    private func persistAnnotationStyle() {
        let foreground=style.color.usingColorSpace(.sRGB) ?? style.color
        let background=style.backgroundColor.usingColorSpace(.sRGB) ?? style.backgroundColor
        let outline=style.textOutlineColor.usingColorSpace(.sRGB) ?? style.textOutlineColor
        let marker=style.numberColor.usingColorSpace(.sRGB) ?? style.numberColor
        let foregroundValues=[Double(foreground.redComponent),Double(foreground.greenComponent),Double(foreground.blueComponent),Double(foreground.alphaComponent)]
        let backgroundValues=[Double(background.redComponent),Double(background.greenComponent),Double(background.blueComponent),Double(background.alphaComponent)]
        let outlineValues=[Double(outline.redComponent),Double(outline.greenComponent),Double(outline.blueComponent),Double(outline.alphaComponent)]
        let markerValues=[Double(marker.redComponent),Double(marker.greenComponent),Double(marker.blueComponent),Double(marker.alphaComponent)]
        preferences.set(["width":Double(style.width),"opacity":Double(style.opacity),"filled":style.isFilled,"rounded":style.hasRoundedCorners,"textRounded":style.hasRoundedCorners,"textShadow":style.textShadow,"textOutline":style.textOutline,"textOutlineCustom":style.textOutlineCustom,"textOutlineColor":outlineValues,"cornerRadius":Double(style.cornerRadius),"color":foregroundValues,"numberColor":markerValues,"mode":style.mode.rawValue,"fontName":style.fontName,"fontSize":Double(style.fontSize),"bold":style.bold,"italic":style.italic,"underline":style.underline,"background":style.background,"backgroundColor":backgroundValues,"numberSize":Double(style.numberSize)],forKey:annotationPreferenceKey(for:activeTool))
        persistShapeStyle()
    }
    @objc private func settingChanged(_ sender: NSControl) {
        guard !processing else{return}
        if sender === radius || sender === radiusValue {
            if sender === radiusValue || !radius.isTrackingRadius { document.checkpoint() }
            let pixels=sender === radiusValue ? max(0,min(radius.maxValue,radiusValue.doubleValue)) : ScreenshotRadiusCurve.value(at:radius.doubleValue,maximum:radius.maxValue)
            radiusValue.stringValue=String(Int(pixels.rounded()))
            document.cornerRadius=CGFloat(pixels)*document.sourceRect.width/CGFloat(document.raster.image.width)
            ScreenshotEditPreferences.save(radiusPixels:CGFloat(pixels),shadow:document.shadow,defaults:preferences)
            layoutControls();needsDisplay=true
            if !radius.isTrackingRadius {invalidate()}
            return
        } else if sender === shadowToggle {document.checkpoint();document.shadow=shadowToggle.state == .on}
        else {
            let trackingStyleSlider = (sender === lineWidth && lineWidth.isTrackingValue) || (sender === fontSize && fontSize.isTrackingValue) || (sender === rectangleOpacity && rectangleOpacity.isTrackingValue) || (sender === shapeCornerRadius && shapeCornerRadius.isTrackingValue) || (sender === numberSize && numberSize.isTrackingValue) || (sender === textCornerRadius && textCornerRadius.isTrackingValue)
            if sender === shapeCornerRadiusValue || sender === textCornerRadiusValue || !trackingStyleSlider { document.checkpoint() }
            if sender === color {style.color=color.color}
            if sender === lineWidth || sender === lineValue {style.width=CGFloat(max(1,min(80,sender === lineValue ? lineValue.doubleValue : lineWidth.doubleValue)))}
            if sender === rectangleOpacity || sender === rectangleOpacityInput {
                let input=sender === rectangleOpacityInput ? rectangleOpacityInput.doubleValue : rectangleOpacity.doubleValue
                style.opacity=CGFloat(max(0,min(100,input))/100)
            }
            if sender === shapeCornerRadius || sender === shapeCornerRadiusValue {style.cornerRadius=CGFloat(max(0,min(100,sender === shapeCornerRadiusValue ? shapeCornerRadiusValue.doubleValue:shapeCornerRadius.doubleValue)))}
            if sender === textCornerRadius || sender === textCornerRadiusValue {style.cornerRadius=CGFloat(max(0,min(60,sender === textCornerRadiusValue ? textCornerRadiusValue.doubleValue:textCornerRadius.doubleValue)))}
            if sender === rectangleFill {style.isFilled=rectangleFill.state == .on}
            if sender === rectangleRounded {style.hasRoundedCorners=rectangleRounded.state == .on}
            if sender === textRounded {style.hasRoundedCorners=textRounded.state == .on}
            if sender === textShadow {style.textShadow=textShadow.state == .on}
            if sender === textOutline {style.textOutline=textOutline.state == .on}
            if sender === textOutlineColor {style.textOutlineColor=textOutlineColor.color;style.textOutlineCustom=true}
            if sender === effect {style.mode=ScreenshotPaintMode.allCases[max(0,effect.indexOfSelectedItem)]}
            if sender === fontFamily {style.fontName=fontFamily.indexOfSelectedItem == 0 ? "" : fontFamily.titleOfSelectedItem ?? ""}
            if sender === fontSize || sender === fontValue {style.fontSize=CGFloat(max(8,min(144,sender === fontValue ? fontValue.doubleValue : fontSize.doubleValue)))}
            if sender === numberSize || sender === numberSizeValue {style.numberSize=CGFloat(max(8,min(80,sender === numberSizeValue ? numberSizeValue.doubleValue:numberSize.doubleValue)))}
            if sender === numberColor {style.numberColor=numberColor.color}
            style.bold=bold.state == .on;style.italic=italic.state == .on;style.underline=underline.state == .on;style.background=textBackground.state == .on;style.backgroundColor=backgroundColor.color
            if let id=selectedID,let index=document.annotations.firstIndex(where:{$0.id==id}) {
                let item=document.annotations[index];var next=style
                if naturalImageSize != nil {next.scaleGeometry(by:viewportZoom)}
                next.id=item.id;next.tool=item.tool;next.start=item.start;next.end=item.end;next.points=item.points;next.text=item.text;next.number=item.number;next.labelSize=item.labelSize;next.textBoxWidthIsUserSet=item.textBoxWidthIsUserSet
                let typographyChanged=next.fontSize != item.fontSize || next.fontName != item.fontName || next.bold != item.bold || next.italic != item.italic || next.underline != item.underline
                if [.text,.number].contains(item.tool) && typographyChanged {
                    fitTextBox(&next)
                }
                document.annotations[index]=next
            }
        }
        let radiusPixels=document.cornerRadius*CGFloat(document.raster.image.width)/document.sourceRect.width
        ScreenshotEditPreferences.save(radiusPixels:radiusPixels,shadow:document.shadow,defaults:preferences)
        let trackingStyleSlider = (sender === lineWidth && lineWidth.isTrackingValue) || (sender === fontSize && fontSize.isTrackingValue) || (sender === rectangleOpacity && rectangleOpacity.isTrackingValue) || (sender === shapeCornerRadius && shapeCornerRadius.isTrackingValue) || (sender === numberSize && numberSize.isTrackingValue) || (sender === textCornerRadius && textCornerRadius.isTrackingValue)
        syncStyle()
        if trackingStyleSlider {
            lineValue.stringValue=String(Int(style.width.rounded()));fontValue.stringValue=String(Int(style.fontSize.rounded()))
            rectangleOpacityValue.stringValue="\(Int((style.opacity*100).rounded()))"
            rectangleOpacityInput.stringValue=String(Int((style.opacity*100).rounded()))
            shapeCornerRadiusValue.stringValue=String(Int(style.cornerRadius.rounded()))
            numberSizeValue.stringValue=String(Int(style.numberSize.rounded()))
            textCornerRadiusValue.stringValue=String(Int(style.cornerRadius.rounded()))
            if sender === lineWidth || sender === rectangleOpacity || sender === shapeCornerRadius || sender === numberSize || sender === textCornerRadius {scheduleOverlayRender(updateLayout:false)}
        } else { invalidate() }
        if activeTool != .select {persistAnnotationStyle()}
        if activeTool != .rectangle && activeTool != .ellipse && activeTool != .select {perToolStyles[activeTool]=style}
    }
    @objc private func rectanglePaletteClicked(_ sender:NSButton) {
        guard displayedPalette.indices.contains(sender.tag) else{return}
        color.color=displayedPalette[sender.tag]
        settingChanged(color)
    }
    override func mouseDown(with event: NSEvent) {
        if naturalImageSize != nil && (spaceHeld || panToolEnabled) {
            viewPanning=true;lastPanPoint=convert(event.locationInWindow,from:nil)
            NSCursor.closedHand.set();return
        }
        if ocrMode {
            guard !processing,ocrTranslationTask == nil else{return}
            let location=convert(event.locationInWindow,from:nil)
            if showingOCRTranslation,!document.selection.contains(location) {translatedOCRText.deselect();needsDisplay=true;return}
            let point=ocrPoint(location)
            window?.makeFirstResponder(self)
            if !showingOCRTranslation && !ocrTranslationOverlays.isEmpty {
                clearOCRTranslation()
            }
            if showingOCRTranslation {
                ocrDraggingText=translatedOCRText.begin(at:point,in:document.sourceRect)
            } else {
                ocrDraggingText=ocrText.begin(at:point,in:document.sourceRect)
            }
            let line=visibleOCRSelection.line(at:point,in:document.sourceRect)
            if event.clickCount>=3,let line {
                if showingOCRTranslation {translatedOCRText.selectParagraph(line,in:document.sourceRect)}
                else {ocrText.selectParagraph(line,in:document.sourceRect)}
            } else if event.clickCount==2 {
                if showingOCRTranslation {translatedOCRText.selectWord(at:point,in:document.sourceRect)}
                else {ocrText.selectWord(at:point,in:document.sourceRect)}
            }
            needsDisplay=true
            return
        }
        guard !processing else{return};commitText();window?.makeFirstResponder(self)
        let point=convert(event.locationInWindow,from:nil);dragStart=point
        original=ScreenshotEditSnapshot(selection:document.selection,annotations:document.annotations,cornerRadius:document.cornerRadius,shadow:document.shadow)
        if let index=handles(document.selection).firstIndex(where:{NSRect(x:$0.x-6,y:$0.y-6,width:12,height:12).contains(point)}) {document.checkpoint();dragging = .cropResize(index);window?.invalidateCursorRects(for:self);return}
        guard document.selection.contains(point) else{return}
        if let item=document.annotations.reversed().first(where:{$0.contains(point)}) {
            selectedID=item.id;syncStyle();layoutControls();window?.invalidateCursorRects(for:self);needsDisplay=true
            if let gesture=annotationGesture(for:item,at:point) {
                if item.tool == .text,item.textRect.contains(point),!isNearEdge(item.textRect,point:point) {
                    beginText(item.id);dragging = .none;return
                }
                dragging = .pendingManipulation(item.id,gesture);return
            }
        }
        if tool == .select {
            selectedID=nil;document.checkpoint();dragging = .cropMove;window?.invalidateCursorRects(for:self);NSCursor.closedHand.set();layoutControls();return
        }
        if tool == .text {
            guard document.annotations.count<200 else{status.stringValue="最多保留 200 个标注；请撤销或输出后继续。";return}
            document.checkpoint();var item=style
            if naturalImageSize != nil {item.scaleGeometry(by:viewportZoom)}
            item.id=UUID();item.tool=tool;item.start=point;item.end=NSPoint(x:min(document.selection.maxX,point.x+40*viewportZoom),y:min(document.selection.maxY,point.y+32*viewportZoom));item.text=""
            document.annotations.append(item);selectedID=item.id;beginText(item.id);dragging = .none;invalidate();return
        }
        if tool == .number {
            guard document.annotations.count<200 else{status.stringValue="最多保留 200 个标注；请撤销或输出后继续。";return}
            document.checkpoint();var item=style
            if naturalImageSize != nil {item.scaleGeometry(by:viewportZoom)}
            item.id=UUID();item.tool=tool;item.start=point
            item.number=(document.annotations.filter{$0.tool == .number}.map(\.number).max() ?? 0)+1
            item.end=NSPoint(x:max(document.selection.minX,min(document.selection.maxX-item.labelSize.width,point.x+24)),y:max(document.selection.minY,min(document.selection.maxY-item.labelSize.height,point.y+12)));item.text=""
            document.annotations.append(item);selectedID=item.id;beginText(item.id);dragging = .none;invalidate();return
        }
        dragging = .pendingCreate(tool)
    }
    override func mouseDragged(with event: NSEvent) {
        if viewPanning {
            let point=convert(event.locationInWindow,from:nil)
            let delta=NSPoint(x:point.x-lastPanPoint.x,y:point.y-lastPanPoint.y)
            lastPanPoint=point;panHistoryImage(by:delta);NSCursor.closedHand.set();return
        }
        if ocrMode {
            let point=ocrPoint(convert(event.locationInWindow,from:nil))
            if ocrDraggingText {
                if showingOCRTranslation {translatedOCRText.extend(to:point,in:document.sourceRect)}
                else {ocrText.extend(to:point,in:document.sourceRect)}
            }
            needsDisplay=true;return
        }
        guard !processing,let original else{return}
        let movingCrop: Bool
        switch dragging { case .cropMove,.cropResize: movingCrop=true; default: movingCrop=false }
        let point=convert(event.locationInWindow,from:nil),delta=NSPoint(x:point.x-dragStart.x,y:point.y-dragStart.y)
        if case .pendingCreate(let requestedTool)=dragging {
            guard hypot(delta.x,delta.y)>=3 else{return}
            guard document.annotations.count<200 else{status.stringValue="最多保留 200 个标注；请撤销或输出后继续。";dragging = .none;layoutControls();return}
            document.checkpoint();var item=style
            if naturalImageSize != nil {item.scaleGeometry(by:viewportZoom)}
            item.id=UUID();item.tool=requestedTool;item.start=dragStart;item.end=dragStart;item.points=[dragStart]
            if requestedTool == .number {
                item.number=(document.annotations.filter{$0.tool == .number}.map(\.number).max() ?? 0)+1
                item.end=point;item.text=""
            }
            document.annotations.append(item);selectedID=item.id;dragging = .create(item.id)
        }
        if case .pendingManipulation(let id,let gesture)=dragging {
            guard hypot(delta.x,delta.y)>=3 else{return}
            document.checkpoint()
            switch gesture {
            case .move(let label):dragging = .objectMove(id,label)
            case .resize(let handle):dragging = .objectResize(id,handle)
            case .endpoint(let isStart):dragging = .lineEndpoint(id,isStart)
            }
        }
        switch dragging {
        case .none,.pendingManipulation:return
        case .pendingCreate:return
        case .cropMove:
            document.selection=document.clampSelection(original.selection.offsetBy(dx:delta.x,dy:delta.y))
            let offset=NSPoint(x:document.selection.minX-original.selection.minX,y:document.selection.minY-original.selection.minY)
            document.annotations=original.annotations.map {var item=$0;item.translate(offset);return item}
        case .cropResize(let index):
            var left=original.selection.minX,right=original.selection.maxX,top=original.selection.minY,bottom=original.selection.maxY
            if [0,6,7].contains(index){left=max(document.sourceRect.minX,min(right-2,left+delta.x))};if [2,3,4].contains(index){right=min(document.sourceRect.maxX,max(left+2,right+delta.x))}
            if [0,1,2].contains(index){top=max(document.sourceRect.minY,min(bottom-2,top+delta.y))};if [4,5,6].contains(index){bottom=min(document.sourceRect.maxY,max(top+2,bottom+delta.y))}
            document.selection=NSRect(x:left,y:top,width:right-left,height:bottom-top)
        case .objectMove(let id,let label):
            guard let index=document.annotations.firstIndex(where:{$0.id==id}),var item=original.annotations.first(where:{$0.id==id}) else{return}
            if item.tool == .number {if label {item.end.x+=delta.x;item.end.y+=delta.y}else{item.start.x+=delta.x;item.start.y+=delta.y}}
            else{item.translate(delta)};document.annotations[index]=item
        case .lineEndpoint(let id,let isStart):
            guard let index=document.annotations.firstIndex(where:{$0.id==id}),var item=original.annotations.first(where:{$0.id==id}) else{return}
            let clipped=NSPoint(x:max(document.selection.minX,min(document.selection.maxX,point.x)),y:max(document.selection.minY,min(document.selection.maxY,point.y)))
            if isStart {item.start=clipped}else{item.end=clipped};document.annotations[index]=item
        case .objectResize(let id,let handle):
            guard let index=document.annotations.firstIndex(where:{$0.id==id}),let before=original.annotations.first(where:{$0.id==id}) else{return}
            var item=before
            var frame=resizeFrame(for:before),left=frame.minX,right=frame.maxX,top=frame.minY,bottom=frame.maxY
            if [0,6,7].contains(handle){left=min(right-20,left+delta.x)}
            if [2,3,4].contains(handle){right=max(left+20,right+delta.x)}
            if [0,1,2].contains(handle){top=min(bottom-20,top+delta.y)}
            if [4,5,6].contains(handle){bottom=max(top+20,bottom+delta.y)}
            frame=NSRect(x:left,y:top,width:right-left,height:bottom-top)
            if item.tool == .number {
                item.textBoxWidthIsUserSet=true
                let width=min(frame.width,max(1,document.selection.maxX-frame.minX))
                let height=min(frame.height,max(1,document.selection.maxY-frame.minY))
                let targetHeight=min(height,max(1,document.selection.maxY-frame.minY))
                let needed=fitWrappedText(&item,width:width,height:targetHeight)
                item.end=frame.origin
                item.labelSize=NSSize(width:width,height:min(max(1,document.selection.maxY-frame.minY),max(targetHeight,needed.height)))
            }
            else {
                item.start=NSPoint(x:frame.minX,y:frame.minY);item.end=NSPoint(x:frame.maxX,y:frame.maxY)
                if item.tool == .text {
                    item.textBoxWidthIsUserSet=true
                    let width=min(frame.width,max(1,document.selection.maxX-frame.minX))
                    let height=min(frame.height,max(1,document.selection.maxY-frame.minY))
                    let targetHeight=min(height,max(1,document.selection.maxY-frame.minY))
                    let needed=fitWrappedText(&item,width:width,height:targetHeight)
                    item.end=NSPoint(x:frame.minX+width,y:frame.minY+min(max(1,document.selection.maxY-frame.minY),max(targetHeight,needed.height)))
                }
            }
            document.annotations[index]=item;syncStyle()
        case .create(let id):
            guard let index=document.annotations.firstIndex(where:{$0.id==id}) else{return}
            let clipped=NSPoint(x:max(document.selection.minX,min(document.selection.maxX,point.x)),y:max(document.selection.minY,min(document.selection.maxY,point.y)))
            document.annotations[index].end=clipped;if document.annotations[index].tool == .pen{document.annotations[index].points.append(clipped)}
        }
        if movingCrop {layoutControls();needsDisplay=true} else {updateOverlayDuringDrag()}
    }
    override func mouseUp(with event: NSEvent) {
        if viewPanning {
            viewPanning=false;((spaceHeld || panToolEnabled) ? NSCursor.openHand : NSCursor.arrow).set()
            window?.invalidateCursorRects(for:self);return
        }
        if ocrMode {
            ocrDraggingText=false
            if !showingOCRTranslation {
                ocrDetectedLanguage=ScreenshotOCRTranslationLanguage.source(for:ocrTranslationText)
                refreshOCRLanguages()
            }
            needsDisplay=true;return
        }
        let clickedNumberText:UUID? = {
            guard case .pendingManipulation(let id,.move(true))=dragging,
                  let item=document.annotations.first(where:{$0.id==id}),item.tool == .number,
                  item.textRect.contains(dragStart),!isNearEdge(item.textRect,point:dragStart) else{return nil}
            return id
        }()
        let createdNumber: UUID? = {
            guard case .create(let id)=dragging,document.annotations.first(where:{$0.id==id})?.tool == .number else{return nil}
            return id
        }()
        let wasDragging: Bool
        switch dragging {
        case .none,.pendingCreate,.pendingManipulation:wasDragging=false
        default:wasDragging=true
        }
        if wasDragging,let selectedID,let index=document.annotations.firstIndex(where:{$0.id==selectedID}),[.text,.number].contains(document.annotations[index].tool) {
            var item=document.annotations[index];fitTextBox(&item);document.annotations[index]=item
        }
        dragging = .none;original=nil;window?.invalidateCursorRects(for:self);NSCursor.arrow.set()
        if wasDragging {invalidate()} else {layoutControls()}
        if let id=createdNumber ?? clickedNumberText {beginText(id)}
    }
    override func rightMouseDown(with event: NSEvent) {
        guard ocrMode else{performAction("cancel");return}
        let menu=NSMenu()
        for (label,selector) in [
            ("复制选中文字",#selector(copyOCRSelectionAction)),
            ("复制全部文字",#selector(copyRecognizedText))
        ] {
            let item=menu.addItem(withTitle:label,action:selector,keyEquivalent:"")
            item.target=self
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    override func cancelOperation(_ sender: Any?) {
        if ocrMode {exitOCRMode()} else {performAction("cancel")}
    }
    override func keyDown(with event: NSEvent) {
        if showingOCRTranslation {
            switch event.keyCode {
            case 121:setOCRTranslationScroll(ocrTranslationScrollOffset+document.selection.height*0.8);return
            case 116:setOCRTranslationScroll(ocrTranslationScrollOffset-document.selection.height*0.8);return
            case 125:setOCRTranslationScroll(ocrTranslationScrollOffset+24);return
            case 126:setOCRTranslationScroll(ocrTranslationScrollOffset-24);return
            case 115:setOCRTranslationScroll(0);return
            case 119:setOCRTranslationScroll(ocrTranslationScrollMaximum);return
            default:break
            }
        }
        if naturalImageSize != nil && event.keyCode == 49 {
            spaceHeld=true;NSCursor.openHand.set();return
        }
        let key=event.charactersIgnoringModifiers ?? ""
        if ocrMode && event.modifierFlags.contains(.command) && key.lowercased()=="c" {
            copyOCRSelectionAction();return
        }
        if ocrMode && event.modifierFlags.contains(.command) && key.lowercased()=="a" {
            if showingOCRTranslation {translatedOCRText.selectAll()} else {ocrText.selectAll()}
            needsDisplay=true;return
        }
        if naturalImageSize != nil && key.lowercased()=="h" && !event.modifierFlags.contains(.command) {
            togglePanTool();return
        }
        if naturalImageSize != nil && event.modifierFlags.contains(.command) {
            switch key {
            case "0":fitImageToViewport();return
            case "1":zoomViewport(to:1);return
            case "+","=":zoomViewport(to:viewportZoom*1.25);return
            case "-","_":zoomViewport(to:viewportZoom/1.25);return
            default:break
            }
        }
        if event.keyCode == 53 {
            if ocrMode {exitOCRMode()} else {performAction("cancel")}
        }
        else if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers=="z" {performAction("undo")}
        else if event.keyCode==51,let id=selectedID {document.checkpoint();document.annotations.removeAll{$0.id==id};selectedID=nil;invalidate()}
    }
    override func keyUp(with event:NSEvent) {
        if event.keyCode == 49 && naturalImageSize != nil {
            spaceHeld=false;if !viewPanning {(panToolEnabled ? NSCursor.openHand : NSCursor.arrow).set()};return
        }
        super.keyUp(with:event)
    }
    private func beginText(_ id: UUID) {
        guard let index=document.annotations.firstIndex(where:{$0.id==id}) else{return}
        var item=document.annotations[index];fitTextBox(&item);document.annotations[index]=item
        let field=ScreenshotAnnotationTextField(string:item.text);field.passesPointerEvents=[.text,.number].contains(item.tool);field.frame=item.textRect;field.font=item.font;field.textColor=item.color;field.backgroundColor=item.background ? item.backgroundColor : NSColor(calibratedWhite:0.15,alpha:0.95)
        field.drawsBackground=true;field.focusRingType = .none;field.delegate=self;field.cell?.wraps=true;field.cell?.isScrollable=false;field.target=self;field.action = #selector(textAccepted)
        input=field;inputID=id;addSubview(field);window?.makeFirstResponder(field);syncStyle();layoutControls()
    }
    @objc private func textAccepted() {commitText();window?.makeFirstResponder(self)}
    func controlTextDidEndEditing(_ obj: Notification) {commitText()}
    private func fittedTextSize(_ text:String,font:NSFont,maxWidth:CGFloat,maxHeight:CGFloat)->NSSize {
        let paddingX:CGFloat=12,paddingY:CGFloat=8
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
        let measured=((text.isEmpty ? " " : text) as NSString).boundingRect(
            with:NSSize(width:max(1,maxWidth-paddingX),height:maxHeight),
            options:[.usesLineFragmentOrigin,.usesFontLeading],
            attributes:[.font:font,.paragraphStyle:paragraph]
        ).integral
        let lineHeight=ceil(font.ascender-font.descender+font.leading)
        return NSSize(width:min(maxWidth,max(1,ceil(measured.width)+paddingX)),height:min(maxHeight,max(lineHeight+paddingY,ceil(measured.height)+paddingY)))
    }
    private func wrappedTextSize(_ text:String,font:NSFont,width:CGFloat,maxHeight:CGFloat)->NSSize {
        let paddingX:CGFloat=12,paddingY:CGFloat=8
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
        let lineHeight=ceil(font.ascender-font.descender+font.leading)
        let measurementHeight=max(maxHeight,CGFloat(max(1,text.count+1))*lineHeight+paddingY)
        let measured=((text.isEmpty ? " " : text) as NSString).boundingRect(
            with:NSSize(width:max(1,width-paddingX),height:measurementHeight),
            options:[.usesLineFragmentOrigin,.usesFontLeading],
            attributes:[.font:font,.paragraphStyle:paragraph]
        ).integral
        return NSSize(width:min(width,max(1,ceil(measured.width)+paddingX)),height:max(lineHeight+paddingY,ceil(measured.height)+paddingY))
    }
    private func fitWrappedText(_ item:inout ScreenshotAnnotation,width:CGFloat,height:CGFloat)->NSSize {
        guard !item.text.isEmpty else {return wrappedTextSize(item.text,font:item.font,width:width,maxHeight:height)}
        var lower:CGFloat=1,upper=max(144,item.fontSize)
        for _ in 0..<16 {
            let candidate=(lower+upper)/2
            item.fontSize=candidate
            if wrappedTextSize(item.text,font:item.font,width:width,maxHeight:height).height<=height {lower=candidate}
            else {upper=candidate}
        }
        item.fontSize=lower
        return wrappedTextSize(item.text,font:item.font,width:width,maxHeight:height)
    }
    private func fitTextBox(_ item:inout ScreenshotAnnotation) {
        let origin=item.tool == .number ? item.end:item.start
        let maxHeight=max(1,document.selection.maxY-origin.y)
        let size: NSSize
        if item.textBoxWidthIsUserSet {
            let width=item.tool == .number ? item.labelSize.width:item.rect.width
            let boxHeight=item.tool == .number ? item.labelSize.height:item.rect.height
            let wrapped=fitWrappedText(&item,width:min(width,max(1,document.selection.maxX-origin.x)),height:min(maxHeight,boxHeight))
            size=NSSize(width:wrapped.width,height:min(maxHeight,wrapped.height))
        } else {
            size=fittedTextSize(item.text,font:item.font,maxWidth:max(1,document.selection.maxX-origin.x),maxHeight:maxHeight)
        }
        if item.tool == .number {item.labelSize=size}
        else {item.end=NSPoint(x:origin.x+size.width,y:origin.y+size.height)}
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field=obj.object as? NSTextField,field === input,let id=inputID,
              let index=document.annotations.firstIndex(where:{$0.id==id}) else{return}
        var item=document.annotations[index];item.text=field.stringValue
        let origin=item.tool == .number ? item.end : item.start
        let maxWidth=max(1,document.selection.maxX-origin.x),maxHeight=max(1,document.selection.maxY-origin.y)
        let currentWidth=item.tool == .number ? item.labelSize.width:item.rect.width
        var measuredSize=item.textBoxWidthIsUserSet
            ? wrappedTextSize(field.stringValue,font:item.font,width:min(currentWidth,maxWidth),maxHeight:maxHeight)
            : fittedTextSize(field.stringValue,font:item.font,maxWidth:maxWidth,maxHeight:maxHeight)
        if item.textBoxWidthIsUserSet && measuredSize.height>maxHeight {
            measuredSize=fitWrappedText(&item,width:min(currentWidth,maxWidth),height:maxHeight)
        }
        let size=NSSize(width:item.textBoxWidthIsUserSet ? min(currentWidth,maxWidth):measuredSize.width,height:min(maxHeight,measuredSize.height))
        if item.tool == .number {item.labelSize=size}
        else {item.end=NSPoint(x:item.start.x+size.width,y:item.start.y+size.height)}
        document.annotations[index]=item;field.font=item.font;field.frame=item.textRect;needsDisplay=true
    }
    private func commitText() {
        guard let field=input,let id=inputID else{return};input=nil;inputID=nil
        if let index=document.annotations.firstIndex(where:{$0.id==id}) {
            var item=document.annotations[index];item.text=field.stringValue
            if field.stringValue.isEmpty,item.tool == .text {document.annotations.remove(at:index);selectedID=nil}
            else {fitTextBox(&item);document.annotations[index]=item}
        }
        field.removeFromSuperview();invalidate()
    }
    func performAction(_ action: String) {
        if action == "cancel" {ocrSettingsWindow?.close();clearOCRTranslation();finished=true;renderQueue.cancelAllOperations();onFinish?(nil,"cancel");return}
        if action == "ocr" && ocrMode {exitOCRMode();return}
        if action == "translate",ocrTranslationTask != nil {return}
        guard !processing,!finished else{return};commitText()
        if action == "undo" {document.undo();selectedID=nil;syncStyle();invalidate();return}
        if action == "translate",ocrMode,!ocrText.boxes.isEmpty {
            translationMode=true
            if !ocrTranslationOverlays.isEmpty {toggleOCRTranslation()}
            else {translateOCR(copyResult:false)}
            return
        }
        if action == "ocr" || action == "translate" {
            ocrMode=true;selectedID=nil
            translationMode=action == "translate"
            translateAfterRecognition=translationMode
            status.stringValue="正在识别… 完成后可选择文字复制。"
            layoutControls();recognize(in:document.selection)
            return
        }
        if action == "long",let onLongCapture {
            let source=document.sourceRect, selection=document.selection
            let sx=CGFloat(document.raster.image.width)/source.width
            let sy=CGFloat(document.raster.image.height)/source.height
            let pixels=CGRect(x:floor((selection.minX-source.minX)*sx),
                              y:floor((selection.minY-source.minY)*sy),
                              width:ceil(selection.width*sx),height:ceil(selection.height*sy))
            guard let first=document.raster.image.cropping(to:pixels) else {return}
            ocrSettingsWindow?.close();clearOCRTranslation()
            finished=true;renderQueue.cancelAllOperations()
            onLongCapture(selection,first)
            return
        }
        guard ["save","copy","pin"].contains(action) else{return}
        processing=true;status.stringValue="正在处理图片…";layoutControls()
        let copy=snapshotDocument()
        renderQueue.cancelAllOperations();renderQueue.addOperation { [weak self] in
            let image=copy.render()
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.finished else{return}
                self.processing=false
                guard let image else{self.status.stringValue="图片输出失败，请缩小截图范围。";self.layoutControls();return}
                self.ocrSettingsWindow?.close();self.clearOCRTranslation()
                self.finished=true
                if action == "pin" {self.onPin?(image,self.document.selection)}
                self.onFinish?(image,action)
            }
        }
    }
    private func exitOCRMode() {
        clearOCRTranslation()
        translationMode=false;translateAfterRecognition=false
        ocrGeneration=UUID();ocrMode=false
        ocrDraggingText=false
        ocrText.clear();ocrBoxes=[];processing=false
        status.stringValue="";layoutControls();window?.invalidateCursorRects(for:self);needsDisplay=true
    }
    private func recognize(in screenRegion:NSRect) {
        guard ocrMode,!processing else{return}
        let area=screenRegion.intersection(document.selection).intersection(document.sourceRect)
        guard area.width>=2,area.height>=2 else {
            status.stringValue="识别区域太小。";layoutControls();return
        }
        let source=document.sourceRect,raster=document.raster
        let local=area.offsetBy(dx:-source.minX,dy:-source.minY)
        let region=NSRect(x:local.minX/source.width,y:local.minY/source.height,
                          width:local.width/source.width,height:local.height/source.height)
        ocrGeneration=UUID();let token=ocrGeneration
        clearOCRTranslation()
        processing=true;status.stringValue="正在本机识别文字…"
        ocrText.clear();ocrBoxes=[];layoutControls();needsDisplay=true
        renderQueue.addOperation { [weak self] in
            do {
                // Analyze the native source pixels, not the scaled editing
                // viewport or a composited image containing blue crop handles.
                guard let image=raster.crop(local,viewSize:source.size) else {throw CocoaError(.fileReadUnknown)}
                let boxes=try ScreenshotEditDocument.recognize(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.ocrMode,!self.finished,self.ocrGeneration==token else{return}
                    self.processing=false
                    self.ocrText.install(boxes,region:region);self.ocrBoxes=self.ocrText.boxes
                    self.ocrText.selectAll()
                    self.ocrDetectedLanguage=ScreenshotOCRTranslationLanguage.source(for:self.ocrText.allText())
                    self.status.stringValue=boxes.isEmpty ? "当前区域未识别到文字，请更换截屏范围。" :
                        "识别到 \(boxes.count) 行：拖动选择、双击选词、三击选段、⌘C 复制。"
                    self.layoutControls();self.needsDisplay=true
                    if self.translateAfterRecognition {
                        self.translateAfterRecognition=false
                        if !boxes.isEmpty {self.translateOCR(copyResult:false)}
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.ocrGeneration==token else{return}
                    self.processing=false;self.translateAfterRecognition=false
                    self.status.stringValue="OCR 识别失败：\(error.localizedDescription)"
                    self.layoutControls()
                }
            }
        }
    }
    @objc private func ocrButtonClicked(_ sender:NSButton) {
        switch sender.identifier?.rawValue {
        case "copyOCRSelection":copyOCRSelectionAction()
        case "translateOCR":
            if !ocrTranslationOverlays.isEmpty {toggleOCRTranslation()}
            else {translateOCR(copyResult:false)}
        case "translateAndCopyOCR":translateOCR(copyResult:true)
        default:break
        }
    }
    @objc private func openOCRTranslationSettings() {
        if let settings=ocrSettingsWindow,settings.window?.isVisible == true {
            settings.showWindow(nil);settings.window?.makeKeyAndOrderFront(nil);return
        }
        let settings=ScreenshotOCRTranslationSettingsWindow(preferences:translationPreferences)
        settings.onSave={ [weak self] in
            guard let self else{return}
            self.clearOCRTranslation()
            let configuration=self.translationPreferences.settings
            ScreenshotOCRLocalSession.shared.reconcile(modelPath:configuration.selectedID == nil ? configuration.localModelPath:nil)
            let selected=self.translationPreferences.settings.serviceName
            self.status.stringValue="翻译服务：\(selected)。"
            self.layoutControls()
        }
        ocrSettingsWindow=settings
        settings.showWindow(nil);settings.window?.makeKeyAndOrderFront(nil)
    }
    private var ocrTranslationText:String {
        let selected=ocrText.selectedText()
        return selected.isEmpty ? ocrText.allText() : selected
    }
    private func clearOCRTranslation() {
        ocrTranslationTask?.cancel();ocrTranslationTask=nil
        ocrRevealTask?.cancel();ocrRevealTask=nil
        ocrBackgroundTask?.cancel();ocrBackgroundTask=nil
        ocrTranslationToken=UUID()
        ocrTranslationOverlays=[]
        ocrTranslationScrollOffset=0;ocrTranslationScroller.isHidden=true
        translatedOCRText.clear()
        showingOCRTranslation=false;ocrReplacingOriginal=false
        ocrTranslateButton.title="翻译"
        ocrTranslateButton.toolTip="按上方语言翻译原文"
        needsDisplay=true
    }
    private func toggleOCRTranslation() {
        showingOCRTranslation.toggle()
        ocrTranslateButton.title=showingOCRTranslation ? "显示原文":"显示译文"
        ocrTranslateButton.toolTip=showingOCRTranslation ? "切回原文" : "重新显示已有译文"
        if showingOCRTranslation {translatedOCRText.selectAll();ocrText.deselect()}
        else {ocrText.selectAll();translatedOCRText.deselect()}
        status.stringValue=showingOCRTranslation ? "当前显示译文，可拖动选中复制。" :
            "当前显示原文；点击「显示译文」可切回。"
        layoutControls();needsDisplay=true
    }
    private var ocrSourceCode:String {ocrTranslationSourceOverride ?? ocrDetectedLanguage}
    private var ocrTargetCode:String {
        ocrTranslationTargetOverride ?? ScreenshotOCRTranslationLanguage.defaultTarget(source:ocrSourceCode)
    }
    private func refreshOCRLanguages() {
        ocrSourceLanguage.item(at:0)?.title=ocrText.boxes.isEmpty ? "自动识别":
            "自动识别（\(ScreenshotOCRTranslationLanguage.name(ocrDetectedLanguage))）"
        let targetName=ScreenshotOCRTranslationLanguage.name(ScreenshotOCRTranslationLanguage.defaultTarget(source:ocrSourceCode))
        ocrTargetLanguage.item(at:0)?.title="\(targetName)（默认）"
        for (popup,code) in [(ocrSourceLanguage,ocrTranslationSourceOverride ?? ""),
                             (ocrTargetLanguage,ocrTranslationTargetOverride ?? "")] {
            if let index=popup.itemArray.firstIndex(where:{$0.representedObject as? String == code}) {
                popup.selectItem(at:index)
            }
        }
    }
    @objc private func ocrLanguageChanged(_ sender:NSPopUpButton) {
        let code=sender.selectedItem?.representedObject as? String ?? ""
        clearOCRTranslation()
        if sender === ocrSourceLanguage {ocrTranslationSourceOverride=code.isEmpty ? nil:code}
        else {ocrTranslationTargetOverride=code.isEmpty ? nil:code}
        if !ocrText.hasSelection {ocrText.selectAll()}
        status.stringValue="\(ScreenshotOCRTranslationLanguage.name(ocrSourceCode)) → \(ScreenshotOCRTranslationLanguage.name(ocrTargetCode))"
        layoutControls()
    }
    @objc private func chooseOCRTranslationTarget(_ sender:NSMenuItem) {
        let code=sender.representedObject as? String ?? ""
        let next=code.isEmpty ? nil:code
        if next != ocrTranslationTargetOverride {clearOCRTranslation()}
        ocrTranslationTargetOverride=next
        status.stringValue=code.isEmpty ? "翻译目标语言：自动选择。" :
            "翻译目标语言：\(sender.title)。"
        layoutControls()
    }
    private func applyOCRTranslation(_ overlays:[ScreenshotOCRTranslationOverlay],
                                     copyResult:Bool,restoreBackground:Bool=true,streamingTarget:String?=nil) {
        var restored=overlays
        if restoreBackground {
            let originalBitmap=NSBitmapImageRep(cgImage:document.raster.image)
            let recognizedLines=ocrText.boxes.indices.map{ocrText.frame(for:$0,in:document.sourceRect)}
            let background=ScreenshotOCRTranslationBackground.color(from:originalBitmap,in:document.sourceRect,
                within:document.selection,excluding:recognizedLines)
            restored=overlays.map {
                var result=$0.withRestoredBackground(from:originalBitmap,in:document.sourceRect,excluding:recognizedLines)
                result.backgroundColor=background;return result
            }
        }
        guard let layout=ScreenshotOCRTranslationLayout.arrange(restored,within:document.selection,streamingTarget:streamingTarget) else {
            ocrTranslationOverlays=[];showingOCRTranslation=false;translatedOCRText.clear()
            status.stringValue="译文无法完整排入截图区域，请扩大截屏范围后重试。"
            layoutControls()
            return
        }
        displayOCRTranslation(layout,selectAll:true)
        if copyResult {
            NSPasteboard.general.clearContents()
            let text=ocrTranslationOverlays.map(\.text).joined(separator:"\n")
            let copied=NSPasteboard.general.setString(text,forType:.string)
            status.stringValue=copied ? "译文已覆盖原文并复制。" :
                "译文已覆盖原文，但写入剪贴板失败。"
        } else {
            status.stringValue="译文已显示并全选，可拖动重新选择或点击「显示原文」。"
        }
        if ocrTranslationScrollMaximum>0 {
            status.stringValue="译文较长，可在选区内滚动查看全文，也可复制全部译文。"
        }
        layoutControls()
    }
    private func displayOCRTranslation(_ layout:[ScreenshotOCRTranslationOverlay],selectAll:Bool) {
        ocrTranslationOverlays=layout
        let source=document.sourceRect
        let boxes=ocrTranslationOverlays.flatMap { overlay in
            overlay.lines.map { line in
                let frame=line.rect
                return ScreenshotOCRBox(text:line.text,rect:NSRect(
                x:(frame.minX-source.minX)/source.width,
                y:(frame.minY-source.minY)/source.height,
                width:frame.width/source.width,height:frame.height/source.height))
            }
        }
        translatedOCRText.install(boxes,region:NSRect(x:0,y:0,width:1,height:1))
        if selectAll {translatedOCRText.selectAll()}
        showingOCRTranslation=true
        updateOCRTranslationScroller()
        ocrTranslateButton.title=selectAll ? "显示原文":"翻译中…"
        ocrTranslateButton.toolTip="切回原文"
        ocrText.deselect()
        needsDisplay=true
    }
    private func translateOCR(copyResult:Bool) {
        if !ocrTranslationOverlays.isEmpty && copyResult {
            if !showingOCRTranslation {toggleOCRTranslation()}
            NSPasteboard.general.clearContents()
            let text=ocrTranslationOverlays.map(\.text).joined(separator:"\n")
            status.stringValue=NSPasteboard.general.setString(text,forType:.string) ?
                "已复制显示的译文。" : "写入剪贴板失败。"
            layoutControls()
            return
        }
        let segments=ScreenshotOCRTranslationSegment.make(from:ocrText,in:document.sourceRect)
        guard !segments.isEmpty else {
            status.stringValue="没有可翻译的识别文字。";layoutControls();return
        }
        clearOCRTranslation()
        ocrReplacingOriginal=true
        ocrDetectedLanguage=ScreenshotOCRTranslationLanguage.source(for:segments.map(\.text).joined(separator:"\n"))
        let token=ocrTranslationToken
        let target=ocrTargetCode,source=ocrTranslationSourceOverride
        let translationPreferences=self.translationPreferences,client=self.translationClient
        let serviceName=translationPreferences.settings.serviceName
        let raster=document.raster.image,sourceRect=document.sourceRect,area=document.selection
        let recognized=ocrText.boxes.indices.map{ocrText.frame(for:$0,in:sourceRect)}
        let backgrounds=Task.detached(priority:.userInitiated) {
            let bitmap=NSBitmapImageRep(cgImage:raster)
            let background=ScreenshotOCRTranslationBackground.color(from:bitmap,in:sourceRect,
                within:area,excluding:recognized)
            return segments.enumerated().map { index,segment -> ScreenshotOCRTranslationOverlay in
                var overlay=ScreenshotOCRTranslationOverlay(text:segment.text,sourceRect:segment.rect,
                    sourceLineHeight:segment.lineHeight,sourceLines:segment.sourceLines,sourceLineTexts:segment.sourceLineTexts,sourceText:segment.text)
                overlay.backgroundColor=background
                overlay.segmentIndex=index
                return Task.isCancelled ? overlay:overlay.withRestoredBackground(from:bitmap,in:sourceRect,excluding:recognized)
            }
        }
        ocrBackgroundTask=backgrounds
        status.stringValue="正在通过\(serviceName)翻译…"
        ocrTranslationTask=Task { @MainActor [weak self] in
            defer {
                if let self,self.ocrTranslationToken==token {
                    self.ocrTranslationTask=nil;self.ocrBackgroundTask=nil
                    self.ocrRevealTask?.cancel();self.ocrRevealTask=nil;self.layoutControls()
                }
            }
            let progress=ScreenshotOCRRevealProgress()
            let playback=Task { @MainActor [weak self] in
                let prepared=await backgrounds.value
                var lastFinished=Set<Int>()
                while !Task.isCancelled {
                    guard let self,self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                    let available=prepared.indices.map{progress.available($0)}
                    var changed=lastFinished != progress.finished
                    if let next=progress.next(count:prepared.count),progress.shown[next,default:0]<available[next].count {
                        progress.advance(next);changed=true
                    }
                    if changed {
                        lastFinished=progress.finished
                        let current=prepared.enumerated().map { index,base -> ScreenshotOCRTranslationOverlay in
                            var overlay=base
                            overlay.text=String(available[index].prefix(progress.shown[index,default:0]))
                            overlay.sourceFullyReplaced=(progress.completed || progress.finished.contains(index)) &&
                                progress.shown[index,default:0]>=available[index].count
                            return overlay
                        }
                        if let layout=ScreenshotOCRTranslationLayout.arrange(current,within:self.document.selection,streamingTarget:target) {
                            self.displayOCRTranslation(layout.filter{!$0.text.isEmpty},selectAll:false)
                            self.status.stringValue="正在通过\(serviceName)翻译 · \(progress.received.count)/\(segments.count) 段"
                            self.layoutControls()
                        }
                    } else if progress.completed {return}
                    do {try await Task.sleep(nanoseconds:16_000_000)} catch{return}
                }
            }
            self?.ocrRevealTask=playback
            _ = await backgrounds.value
            guard let self,self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
            do {
                let overlays=try await ScreenshotOCRTranslationRouter.translate(
                    segments,target:target,preferences:translationPreferences,client:client,source:source,onProgress:{ [weak self] index,text in
                        guard let self,self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                        progress.received[index]=text.trimmingCharacters(in:.whitespacesAndNewlines)
                        let message="正在通过\(serviceName)翻译第 \(index+1)/\(segments.count) 段，正在逐步替换原文…"
                        if self.ocrTranslationOverlays.isEmpty,self.status.stringValue != message {
                            self.status.stringValue=message;self.layoutControls()
                        }
                    },onSegmentComplete:{ [weak self] index in
                        guard let self,self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                        progress.finished.insert(index)
                    })
                guard self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                for (index,overlay) in overlays.enumerated() {
                    progress.received[index]=overlay.text
                }
                progress.completed=true
                await playback.value
                guard self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                let prepared=await backgrounds.value
                guard self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                let restored=zip(overlays,prepared).map { overlay,base -> ScreenshotOCRTranslationOverlay in
                    var result=overlay;result.restoredPatches=base.restoredPatches
                    result.backgroundColor=base.backgroundColor;result.segmentIndex=base.segmentIndex;return result
                }
                self.ocrReplacingOriginal=false
                self.applyOCRTranslation(restored,copyResult:copyResult,restoreBackground:false,streamingTarget:target)
            } catch {
                guard self.ocrMode,!self.finished,self.ocrTranslationToken==token else{return}
                self.clearOCRTranslation();self.ocrText.selectAll()
                self.status.stringValue="翻译失败：\(error.localizedDescription)"
                self.layoutControls()
            }
        }
        layoutControls()
    }
    private func ocrPoint(_ point:NSPoint)->NSPoint {
        NSPoint(x:point.x,y:point.y+(showingOCRTranslation ? ocrTranslationScrollOffset:0))
    }
    private func updateOCRTranslationScroller() {
        let maximum=ocrTranslationScrollMaximum
        ocrTranslationScrollOffset=max(0,min(maximum,ocrTranslationScrollOffset))
        ocrTranslationScroller.isHidden = !ocrMode || !showingOCRTranslation || maximum<=0
        ocrTranslationScroller.frame=NSRect(x:document.selection.maxX-17,y:document.selection.minY,
            width:15,height:document.selection.height)
        ocrTranslationScroller.knobProportion=document.selection.height/max(1,ocrTranslationContentRect.height)
        ocrTranslationScroller.doubleValue=maximum>0 ? Double(ocrTranslationScrollOffset/maximum):0
        let color=ScreenshotOCRTranslationBackground.textColor(on:ocrTranslationOverlays.first?.backgroundColor ?? .white)
        ocrTranslationScroller.knobStyle=(color.usingColorSpace(.deviceRGB)?.redComponent ?? 0)>0.5 ? .light:.dark
    }
    private func setOCRTranslationScroll(_ offset:CGFloat) {
        ocrTranslationScrollOffset=offset;updateOCRTranslationScroller()
        window?.invalidateCursorRects(for:self);needsDisplay=true
    }
    @objc private func scrollOCRTranslation(_ sender:NSScroller) {
        switch sender.hitPart {
        case .decrementPage:setOCRTranslationScroll(ocrTranslationScrollOffset-document.selection.height*0.8)
        case .incrementPage:setOCRTranslationScroll(ocrTranslationScrollOffset+document.selection.height*0.8)
        default:setOCRTranslationScroll(CGFloat(sender.doubleValue)*ocrTranslationScrollMaximum)
        }
    }
    private func pasteRecognized(_ text:String,_ feedback:String) {
        guard !text.isEmpty else {
            status.stringValue="请先在图片中点选或拖动文字。";layoutControls();return
        }
        NSPasteboard.general.clearContents()
        let copied=NSPasteboard.general.setString(text,forType:.string)
        status.stringValue=copied ? feedback : "写入剪贴板失败。"
        layoutControls()
    }
    @objc private func copyOCRSelectionAction() {
        pasteRecognized(visibleOCRSelection.selectedText(),
                        showingOCRTranslation ? "已复制选中译文。":"已复制选中文字。")
    }
    @objc func copy(_ sender:Any?) {
        if ocrMode {copyOCRSelectionAction()}
    }
    @objc private func copyRecognizedText() {
        if showingOCRTranslation {
            pasteRecognized(ocrTranslationOverlays.map(\.text).joined(separator:"\n"),"已复制全部译文。")
        } else {
            pasteRecognized(ocrText.allText(),"已复制全部识别文字。")
        }
    }
    private func handles(_ rect: NSRect) -> [NSPoint] { [NSPoint(x:rect.minX,y:rect.minY),NSPoint(x:rect.midX,y:rect.minY),NSPoint(x:rect.maxX,y:rect.minY),NSPoint(x:rect.maxX,y:rect.midY),NSPoint(x:rect.maxX,y:rect.maxY),NSPoint(x:rect.midX,y:rect.maxY),NSPoint(x:rect.minX,y:rect.maxY),NSPoint(x:rect.minX,y:rect.midY)] }
    private func drawFrozenSelection(_ rect:NSRect) {
        let radius=min(document.cornerRadius,min(rect.width,rect.height)/2)
        let rounded=NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius)
        if document.shadow {
            NSGraphicsContext.saveGraphicsState()
            let shade=NSShadow();shade.shadowColor=NSColor.black.withAlphaComponent(0.5);shade.shadowBlurRadius=ScreenshotEditDocument.selectionShadowBlurRadius;shade.shadowOffset=NSSize(width:0,height:-ScreenshotEditDocument.selectionShadowOffset);shade.set()
            NSColor.black.setFill();rounded.fill();NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState();rounded.addClip()
        NSImage(cgImage:document.raster.image,size:document.sourceRect.size).draw(in:document.sourceRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func draw(_ dirtyRect: NSRect) {
        if document.sourceRect == bounds {
            // Region capture: the frozen full display stays visible under the mask.
            NSImage(cgImage:document.raster.image,size:bounds.size).draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            NSColor.black.withAlphaComponent(0.45).setFill();bounds.fill()
        } else {
            // Screenshot history: dim the desktop, not a stretched copy of the image.
            NSColor.black.withAlphaComponent(0.70).setFill();bounds.fill()
        }
        let rect=document.selection
        drawFrozenSelection(rect)
        if let preview,previewSelection==rect {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect:rect,xRadius:min(document.cornerRadius,rect.width/2),yRadius:min(document.cornerRadius,rect.height/2)).addClip()
            NSImage(cgImage:preview,size:rect.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.systemCyan.setStroke();let outlineRadius=min(document.cornerRadius,min(rect.width,rect.height)/2);let outline=NSBezierPath(roundedRect:rect,xRadius:outlineRadius,yRadius:outlineRadius);outline.lineWidth=1.5;outline.stroke()
        NSColor.systemCyan.setFill();for point in handles(rect) {NSRect(x:point.x-4,y:point.y-4,width:8,height:8).fill()}
        if let id=selectedID,let item=document.annotations.first(where:{$0.id==id}),
           [.rectangle,.ellipse,.mask,.text,.number,.highlight].contains(item.tool) {
            NSColor.white.withAlphaComponent(0.8).setStroke();let outline=NSBezierPath(rect:resizeFrame(for:item));outline.lineWidth=1;outline.setLineDash([3,3],count:2,phase:0);outline.stroke()
            NSColor.systemCyan.setFill();let points=[.text,.number].contains(item.tool) ? [handles(resizeFrame(for:item))[4]]:handles(resizeFrame(for:item));for point in points {NSRect(x:point.x-4,y:point.y-4,width:8,height:8).fill()}
        } else if let id=selectedID,let item=document.annotations.first(where:{$0.id==id}),item.tool == .line || item.tool == .arrow {
            NSColor.systemCyan.setFill()
            for point in [item.start,item.end] {NSBezierPath(ovalIn:NSRect(x:point.x-5,y:point.y-5,width:10,height:10)).fill()}
        }
        if ocrMode {
            if showingOCRTranslation {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect:document.selection,xRadius:outlineRadius,yRadius:outlineRadius).addClip()
                (ocrTranslationOverlays.first?.backgroundColor ?? .white).setFill()
                if !ocrReplacingOriginal {document.selection.fill()}
                NSGraphicsContext.current?.cgContext.translateBy(x:0,y:-ocrTranslationScrollOffset)
                if ocrReplacingOriginal {
                    let sourceRows=ocrText.boxes.indices.map{ocrText.frame(for:$0,in:document.sourceRect)}
                    for overlay in ocrTranslationOverlays {
                        for rect in overlay.replacementRects(sourceRows:sourceRows) {rect.fill()}
                    }
                }
                for overlay in ocrTranslationOverlays {overlay.draw(in:ocrTranslationContentRect)}
                for frame in translatedOCRText.selectedRects(in:document.sourceRect) {
                    NSColor.systemBlue.withAlphaComponent(0.36).setFill()
                    NSBezierPath(roundedRect:frame,xRadius:2,yRadius:2).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                for index in ocrText.boxes.indices {
                    let frame=ocrText.frame(for:index,in:document.sourceRect)
                    NSColor.systemBlue.withAlphaComponent(0.10).setFill()
                    NSBezierPath(roundedRect:frame,xRadius:3,yRadius:3).fill()
                }
            }
            if !showingOCRTranslation {
                for frame in ocrText.selectedRects(in:document.sourceRect) {
                    NSColor.systemBlue.withAlphaComponent(0.36).setFill()
                    NSBezierPath(roundedRect:frame,xRadius:2,yRadius:2).fill()
                }
            }
        }
    }
}

private final class ScreenshotEditingColorWell: NSColorWell {
    var compactCircularMode=false {
        didSet { if compactCircularMode != oldValue {needsDisplay=true} }
    }
    override var color:NSColor {didSet {needsDisplay=true}}
    override func draw(_ dirtyRect:NSRect) {
        if compactCircularMode {
            // Keep the native colour panel behaviour, but replace the
            // dropdown chrome with the same-sized round swatch as presets.
            let center=NSPoint(x:bounds.midX,y:bounds.midY)
            let radius=max(1,min(bounds.width,bounds.height)/2-2)
            for step in 0..<60 {
                NSColor(calibratedHue:CGFloat(step)/60,
                        saturation:0.82,brightness:0.98,alpha:1).setStroke()
                let arc=NSBezierPath()
                arc.appendArc(withCenter:center,radius:radius,
                              startAngle:CGFloat(step)*6,
                              endAngle:CGFloat(step+1)*6+0.6)
                arc.lineWidth=max(1.3,radius*0.30)
                arc.stroke()
            }
            let dotRadius=radius*0.48
            color.setFill()
            NSBezierPath(ovalIn:NSRect(x:center.x-dotRadius,y:center.y-dotRadius,
                                      width:dotRadius*2,height:dotRadius*2)).fill()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let rim=NSBezierPath(ovalIn:NSRect(x:center.x-dotRadius,y:center.y-dotRadius,
                                               width:dotRadius*2,height:dotRadius*2))
            rim.lineWidth=0.65
            rim.stroke()
            return
        }
        ScreenshotEditorChrome.controlFill.setFill()
        let background=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
        background.fill();NSColor.white.withAlphaComponent(0.13).setStroke();background.lineWidth=1;background.stroke()
        let center=NSPoint(x:16,y:bounds.midY),radius:CGFloat=9
        for index in 0..<60 {
            NSColor(calibratedHue:CGFloat(index)/60,saturation:0.65,brightness:0.94,alpha:1).setStroke()
            let arc=NSBezierPath();arc.appendArc(withCenter:center,radius:radius,startAngle:CGFloat(index)*6,endAngle:CGFloat(index+1)*6+1)
            arc.lineWidth=3;arc.stroke()
        }
        color.setFill();NSBezierPath(ovalIn:NSRect(x:center.x-6,y:center.y-6,width:12,height:12)).fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let arrow=NSBezierPath();arrow.move(to:NSPoint(x:bounds.width-10,y:bounds.midY+2));arrow.line(to:NSPoint(x:bounds.width-7,y:bounds.midY-2));arrow.line(to:NSPoint(x:bounds.width-4,y:bounds.midY+2));arrow.lineWidth=1;arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        presentColorPanel()
    }

    private func presentColorPanel() {
        let panel=NSColorPanel.shared
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isContinuous=true
        panel.color=color
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        color=sender.color
        if let action { _ = NSApp.sendAction(action,to:target,from:self) }
    }
}

private enum ScreenshotEditorChrome {
    static let accent=NSColor(calibratedRed:100/255,green:170/255,blue:1,alpha:1)
    static let controlFill=NSColor.white.withAlphaComponent(0.095)
}

private final class ScreenshotEditorToggle:NSButton {
    var compactScale:CGFloat=1 {
        didSet {if compactScale != oldValue {needsDisplay=true}}
    }
    override class var cellClass:AnyClass? {
        get {ScreenshotEditorToggleCell.self}
        set {}
    }
    override func draw(_ dirtyRect:NSRect) {
        if let kind=identifier?.rawValue,kind.hasPrefix("format-") {
            let background=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
            (state == .on ? ScreenshotEditorChrome.accent.withAlphaComponent(0.21):ScreenshotEditorChrome.controlFill).setFill();background.fill()
            NSColor.white.withAlphaComponent(0.13).setStroke();background.lineWidth=1;background.stroke()
            let letter=kind=="format-bold" ? "B":(kind=="format-italic" ? "I":"U")
            let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
            let compact=bounds.height<=20
            (letter as NSString).draw(in:bounds.insetBy(dx:2,dy:compact ? 1:4),
                withAttributes:[.font:NSFont.systemFont(ofSize:compact ? 10:12,
                                                         weight:kind=="format-bold" ? .bold:.medium),
                                .foregroundColor:state == .on ? ScreenshotEditorChrome.accent:NSColor.white,
                                .paragraphStyle:paragraph])
        } else {
            let scale=compactScale
            let width=24*scale,height=14*scale
            let track=NSRect(x:bounds.maxX-width-1,y:bounds.midY-height/2,
                             width:width,height:height)
            (state == .on ? ScreenshotEditorChrome.accent:NSColor.white.withAlphaComponent(0.20)).setFill()
            NSBezierPath(roundedRect:track,xRadius:height/2,yRadius:height/2).fill()
            NSColor.white.setFill()
            let knob=10*scale,inset=2*scale
            NSBezierPath(ovalIn:NSRect(x:track.minX+(state == .on ? width-knob-inset:inset),
                                       y:track.minY+inset,width:knob,height:knob)).fill()
            let labelHeight=18*scale
            let labelWidth=scale<1 ? max(0,track.minX-1) : max(0,bounds.width-31)
            (title as NSString).draw(in:NSRect(x:0,y:bounds.midY-labelHeight/2,
                                                width:labelWidth,height:labelHeight),
                withAttributes:[.font:NSFont.systemFont(ofSize:scale<1 ? 8 : min(font?.pointSize ?? 11,11)),
                                .foregroundColor:NSColor.labelColor])
        }
        if window?.firstResponder === self {
            ScreenshotEditorChrome.accent.setStroke()
            let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:5,yRadius:5);focus.lineWidth=2;focus.stroke()
        }
    }
}

// OCR is the only toolbar that uses an icon+text button. AppKit's default
// NSButtonCell places these against the left edge (roughly 1pt of padding).
// Shift the *content* as a group without moving/resizing its hit area,
// changing image/title styles, or altering any OCR action.
private final class ScreenshotOCRButton: NSButton {
    override class var cellClass: AnyClass? {
        get { ScreenshotOCRPaddedCell.self }
        set {}
    }
}

private final class ScreenshotOCRPaddedCell: NSButtonCell {
    private let leftPadding: CGFloat = 7
    override func drawImage(_ image:NSImage,withFrame frame:NSRect,in controlView:NSView) {
        super.drawImage(image,withFrame:frame.offsetBy(dx:leftPadding,dy:0),in:controlView)
    }
    override func drawTitle(_ title:NSAttributedString,withFrame frame:NSRect,in controlView:NSView)->NSRect {
        super.drawTitle(title,withFrame:frame.offsetBy(dx:leftPadding,dy:0),in:controlView)
    }
}

private final class ScreenshotEditorToggleCell:NSButtonCell {
    override func hitTest(for event:NSEvent,in cellFrame:NSRect,of controlView:NSView)->NSCell.HitResult {
        // The switch is custom-drawn; its entire visible control must track clicks.
        cellFrame.contains(controlView.convert(event.locationInWindow,from:nil)) ? [.contentArea,.trackableArea]:[]
    }
}

private final class ScreenshotEditorOptionsView:NSView {
    override var isFlipped:Bool {true}
}

private final class ScreenshotEditorDivider:NSView {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer=true
        layer?.backgroundColor=NSColor.white.withAlphaComponent(0.16).cgColor
        toolTip="设置分隔线"
    }
    required init?(coder:NSCoder) {nil}
}
