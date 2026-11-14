import AppKit

struct GlassComponentGeometry: Decodable {
    let id: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let clipX: Double
    let clipY: Double
    let clipWidth: Double
    let clipHeight: Double
    let radius: Double

    func rectangles(in viewport: NSRect) -> (shape: NSRect, clip: NSRect)? {
        guard !id.isEmpty, id.count <= 512,
              [x, y, width, height, clipX, clipY, clipWidth, clipHeight, radius].allSatisfy(\.isFinite),
              width > 0, height > 0, width < 100_000, height < 100_000, radius >= 0 else { return nil }
        let shape = NSRect(x: x, y: y, width: width, height: height)
        let clip = NSRect(x: clipX, y: clipY, width: max(0, clipWidth), height: max(0, clipHeight)).intersection(shape).intersection(viewport)
        guard !clip.isEmpty else { return nil }
        return (shape, clip)
    }
}

struct GlassLayout: Decodable {
    let components: [GlassComponentGeometry]
    let dragRegion: GlassComponentGeometry?
    let sidebarDragRegion: GlassComponentGeometry?
}

/// Default components are ordinary tinted layers over one shared native blur.
/// Optional native lenses are created only while enhanced glass is enabled.
final class ComponentGlassHost: NSView {
    private(set) var planes: [String: ComponentGlassPlane] = [:]
    private var opacity: Double = 1
    private var nativeLensEnabled = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(opacity: Double, nativeLensEnabled: Bool = false) {
        self.opacity = GlassMaterialPreferences.normalizedOpacity(opacity)
        self.nativeLensEnabled = nativeLensEnabled
        for plane in planes.values { plane.configure(opacity: self.opacity, nativeLensEnabled: nativeLensEnabled) }
    }

    func update(_ components: [GlassComponentGeometry]) {
        var retained = Set<String>()
        var ordered: [ComponentGlassPlane] = []
        for component in components.prefix(256) {
            guard let rects = component.rectangles(in: bounds), retained.insert(component.id).inserted else { continue }
            let plane: ComponentGlassPlane
            if let existing = planes[component.id] { plane = existing }
            else {
                plane = ComponentGlassPlane(frame: .zero)
                planes[component.id] = plane
                addSubview(plane)
            }
            ordered.append(plane)
            if plane.frame != rects.clip { plane.frame = rects.clip }
            plane.update(shape: NSRect(x: rects.shape.minX - rects.clip.minX, y: rects.shape.minY - rects.clip.minY, width: rects.shape.width, height: rects.shape.height), radius: component.radius)
            plane.configure(opacity: opacity, nativeLensEnabled: nativeLensEnabled)
        }
        for id in Array(planes.keys) where !retained.contains(id) {
            planes.removeValue(forKey: id)?.removeFromSuperview()
        }
        // Re-adding unchanged native glass views resets their material/rim.
        // Only reorder when the actual DOM paint order changes.
        if subviews.map(ObjectIdentifier.init) != ordered.map(ObjectIdentifier.init) {
            for plane in ordered { addSubview(plane, positioned: .above, relativeTo: nil) }
        }
    }
}

final class ComponentGlassPlane: NSView {
    private let tint = NSView()
    private var lens: NSView?
    private(set) var isFrosted = true
    private var lastShape: NSRect?
    private var lastRadius: Double?
    private var lastOpacity: Double?
    private var lastLensEnabled = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        tint.wantsLayer = true
        tint.layer?.masksToBounds = true
        addSubview(tint)
    }
    required init?(coder: NSCoder) { nil }

    func update(shape: NSRect, radius: Double) {
        guard shape != lastShape || radius != lastRadius else { return }
        layer?.masksToBounds = true
        if #available(macOS 14.0, *) { clipsToBounds = true }
        lens?.frame = shape
        tint.frame = shape
        let bounded = min(radius, min(shape.width, shape.height) / 2)
        if shape != lastShape || radius != lastRadius {
            let mask = CAShapeLayer()
            mask.path = CGPath(roundedRect: shape, cornerWidth: bounded, cornerHeight: bounded, transform: nil)
            layer?.mask = mask
            lastShape = shape; lastRadius = radius
        }
        tint.layer?.cornerRadius = bounded
        tint.layer?.borderWidth = 0.5
        if #available(macOS 26.0, *), let glass = lens as? NSGlassEffectView { glass.cornerRadius = bounded }
    }

    func configure(opacity: Double, nativeLensEnabled: Bool = false) {
        let amount = GlassMaterialPreferences.normalizedOpacity(opacity)
        guard amount != lastOpacity || nativeLensEnabled != lastLensEnabled else { return }
        lastOpacity = amount
        lastLensEnabled = nativeLensEnabled
        isFrosted = true
        if nativeLensEnabled, amount < 1, #available(macOS 26.0, *) {
            isFrosted = false
            if lens == nil {
                let glass = NSGlassEffectView(frame: lastShape ?? bounds)
                glass.style = .regular
                glass.cornerRadius = min(lastRadius ?? 0, min(glass.frame.width, glass.frame.height) / 2)
                glass.contentView = NSView()
                addSubview(glass, positioned: .below, relativeTo: tint)
                lens = glass
            }
        } else {
            lens?.removeFromSuperview()
            lens = nil
        }
        updateTint()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }
    private func updateTint() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint.layer?.backgroundColor = NSColor(calibratedWhite: dark ? 1 : 0, alpha: 0.025 + (lastOpacity ?? 1) * 0.065).cgColor
        tint.layer?.borderColor = NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.13 : 0.08).cgColor
    }
}
