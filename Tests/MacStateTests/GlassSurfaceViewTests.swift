import Testing
import AppKit
@testable import MacState

@Test @MainActor func defaultGlassUsesExactlyOneNativeBlurAndNoCustomRenderer() {
    let content = NSView()
    let surface = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), contentView: content)
    #expect(surface.contentView === content)
    #expect(content.frame == surface.bounds)
    #expect(content.layer?.cornerRadius == 24)
    #expect(content.layer?.masksToBounds == true)
    #expect(surface.subviews.compactMap { $0 as? NSVisualEffectView }.count == 1)
    #expect((surface.subviews.first as? NSVisualEffectView)?.blendingMode == .behindWindow)
    #expect(!surface.subviews.contains { $0 is LensRendererView })
    #expect(content.superview === surface)
    #expect(surface.layer?.masksToBounds == true)
    #expect(surface.layer?.borderWidth == 0)
    #expect(content.layer?.backgroundColor == nil)
    if #available(macOS 14.0, *) { #expect(surface.clipsToBounds) }
    if #available(macOS 26.0, *) {
        #expect(surface.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty)
    }
}

@Test @MainActor func glassOpacityAdjustsTheSurfaceWithoutFadingContent() {
    let content = NSView()
    let surface = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 920, height: 660), contentView: content)
    let originalMaterial = surface.subviews.first
    let field = NSTextField(string: "保持输入与滚动状态")
    content.addSubview(field)
    surface.configure(theme: "dark", opacity: 0)
    surface.configure(theme: "dark", opacity: 1)
    #expect(surface.alphaValue == 1)
    #expect(content.alphaValue == 1)
    #expect(surface.subviews.first === originalMaterial)
    #expect(field.superview === content)
    #expect(!content.isHiddenOrHasHiddenAncestor)
    if #available(macOS 26.0, *) {
        #expect(content.layer?.backgroundColor == nil)
        #expect(originalMaterial?.isHidden == false, "The shared blur remains active in economical mode")
        #expect(content.superview === surface)
    }
    surface.configure(theme: "light", opacity: -1)
    #expect(surface.appearance?.name == .aqua)
    surface.configure(theme: "system", opacity: .nan)
    #expect(surface.appearance == nil)
    #expect(surface.subviews.first === originalMaterial)
    surface.setFrameSize(NSSize(width: 600, height: 420))
    surface.layoutSubtreeIfNeeded()
    #expect(surface.subviews.first?.frame == surface.bounds)
    #expect(content.frame == surface.bounds)
}

@Test func glassMaterialOpacityIsFiniteAndBounded() {
    #expect(GlassMaterialPreferences.normalizedOpacity(-0.5) == 0)
    #expect(GlassMaterialPreferences.normalizedOpacity(1.5) == 1)
    #expect(GlassMaterialPreferences.normalizedOpacity(.nan) == 1)
    #expect(GlassMaterialPreferences.normalizedOpacity(.infinity) == 1)
    #expect(GlassMaterialPreferences.normalizedOpacity(0.47) == 0.47)
}

@Test @MainActor func glassMaterialPreferenceDoesNotChangeSystemGlass() throws {
    let domain = "MacState.GlassTest.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let systemTint = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSGlassTintAmount"] as? NSNumber
    for amount in [0.0, 1, 0.35] {
        defaults.set(0.0, forKey: "NSGlassTintAmount")
        GlassMaterialPreferences.apply(opacity: amount, defaults: defaults)
        #expect(defaults.persistentDomain(forName: domain)?["NSGlassTintAmount"] == nil)
        #expect(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSGlassTintAmount"] as? NSNumber == systemTint)
    }
}

@Test @MainActor func optionalNativeGlassDoesNotReparentWebContentOrSurviveZeroTransparency() {
    let content = NSView()
    let surface = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 420), contentView: content)
    surface.configure(theme: "dark", opacity: 0.5, nativeLensEnabled: true)
    if #available(macOS 26.0, *) {
        #expect(surface.subviews.compactMap { $0 as? NSGlassEffectView }.count == 1)
        surface.configure(theme: "dark", opacity: 1, nativeLensEnabled: true)
        #expect(surface.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty)
        surface.configure(theme: "dark", opacity: 0, nativeLensEnabled: true)
        #expect(surface.subviews.compactMap { $0 as? NSGlassEffectView }.count == 1)
        surface.configure(theme: "dark", opacity: 0, nativeLensEnabled: false)
        #expect(surface.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty)
    }
    #expect(content.superview === surface)
    #expect(content.alphaValue == 1)
    #expect(!surface.subviews.contains { $0 is LensRendererView })
}
