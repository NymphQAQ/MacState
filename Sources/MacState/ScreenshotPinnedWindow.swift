import AppKit

final class ScreenshotPinnedWindow: NSPanel {
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
    var onClosed: (() -> Void)?
    init(image: CGImage,frame: NSRect) {
        super.init(contentRect:frame,styleMask:[.borderless,.resizable],backing:.buffered,defer:false)
        isReleasedWhenClosed=false;level = .floating;collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        isOpaque=false;backgroundColor = .clear;hasShadow=true;isMovableByWindowBackground=true;minSize=NSSize(width:64,height:48)
        let view=ScreenshotPinnedImageView(frame:NSRect(origin:.zero,size:frame.size),image:image)
        view.autoresizingMask=[.width,.height];view.closeAction = {[weak self] in self?.close()};contentView=view
    }
    override func close() {super.close();onClosed?()}
}
private final class ScreenshotPinnedImageView: NSView {
    let image: NSImage
    var closeAction: (() -> Void)?
    private let closeButton=NSButton(image:NSImage(systemSymbolName:"xmark.circle.fill",accessibilityDescription:"关闭固定截图") ?? NSImage(),target:nil,action:nil)
    override var mouseDownCanMoveWindow: Bool {true}
    init(frame: NSRect,image: CGImage) {
        self.image=NSImage(cgImage:image,size:frame.size);super.init(frame:frame)
        closeButton.target=self;closeButton.action = #selector(closeImage);closeButton.isBordered=false;closeButton.contentTintColor = .systemRed;closeButton.toolTip="关闭固定截图";addSubview(closeButton)
    }
    required init?(coder:NSCoder){nil}
    override func layout(){super.layout();closeButton.frame=NSRect(x:bounds.maxX-27,y:bounds.maxY-27,width:24,height:24)}
    @objc private func closeImage(){closeAction?()}
    override func draw(_ dirtyRect:NSRect){image.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1)}
}
