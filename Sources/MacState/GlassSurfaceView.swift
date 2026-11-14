import AppKit

enum GlassMaterialPreferences {
    static func normalizedOpacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    static func apply(opacity: Double, defaults: UserDefaults = .standard) {
        // Retire the experimental application-domain override. Let AppKit
        // respect the user's system material and accessibility preferences.
        defaults.removeObject(forKey: "NSGlassTintAmount")
    }
}

/// One WindowServer-composited frost is the default. No desktop pixels,
/// capture stream, Metal device, render timer or texture are owned by the app.
final class GlassSurfaceView: NSView {
    let contentView: NSView
    var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    private let frostedView = NSVisualEffectView()
    private let tintView = NSView()
    private var nativeLens: NSView?
    private var glassOpacity: Double
    private var nativeLensEnabled = false
    private var maskSize = NSSize.zero

    init(frame: NSRect, contentView: NSView, opacity: Double = 1) {
        self.contentView = contentView
        glassOpacity = GlassMaterialPreferences.normalizedOpacity(opacity)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.masksToBounds = true
        if #available(macOS 14.0, *) { clipsToBounds = true }
        frostedView.material = .hudWindow
        frostedView.blendingMode = .behindWindow
        frostedView.state = .active
        frostedView.wantsLayer = true
        frostedView.layer?.cornerRadius = 24
        frostedView.layer?.masksToBounds = true
        tintView.wantsLayer = true
        for view in [frostedView, tintView, contentView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 24
        contentView.layer?.masksToBounds = true
        updateSurfaceColors()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if maskSize != bounds.size, bounds.width > 0, bounds.height > 0 {
            maskSize = bounds.size
            frostedView.maskImage = GlassMask.image(size: bounds.size, radius: 24)
        }
    }

    func configure(theme: String, opacity: Double, nativeLensEnabled: Bool = false) {
        glassOpacity = GlassMaterialPreferences.normalizedOpacity(opacity)
        self.nativeLensEnabled = nativeLensEnabled
        switch theme {
        case "dark": appearance = NSAppearance(named: .darkAqua)
        case "light": appearance = NSAppearance(named: .aqua)
        default: appearance = nil
        }
        updateSurfaceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColors()
    }

    private func updateSurfaceColors() {
        let enhanced = nativeLensEnabled && usesNativeGlass && glassOpacity < 1
        if enhanced, nativeLens == nil, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 24
            glass.contentView = NSView()
            glass.autoresizingMask = [.width, .height]
            addSubview(glass, positioned: .below, relativeTo: frostedView)
            nativeLens = glass
        } else if !enhanced {
            nativeLens?.removeFromSuperview()
            nativeLens = nil
        }
        // Native blur radius is controlled by macOS. In economical mode the
        // slider adjusts tint/translucency rather than running a custom blur.
        frostedView.isHidden = enhanced && glassOpacity == 0
        frostedView.alphaValue = enhanced ? glassOpacity : 1
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = NSColor(calibratedWhite: dark ? 0.075 : 0.98, alpha: 1)
        tintView.layer?.backgroundColor = color.withAlphaComponent(glassOpacity * 0.34).cgColor
        contentView.layer?.backgroundColor = nil
    }
}
