import AppKit

/// Persisted opacity keeps its original meaning; the UI exposes transparency.
struct LensOptics {
    let transparency: Double
    var refraction: Double { pow(transparency, 1.2) * 0.85 }
    var blurPoints: Double { 24 * pow(1 - transparency, 1.1) }
    var tint: Double { 0.06 + 0.28 * (1 - transparency) }
    init(opacity: Double) {
        transparency = 1 - GlassMaterialPreferences.normalizedOpacity(opacity)
    }

    static func sourceRect(window: NSRect, screen: NSRect) -> SIMD4<Float> {
        SIMD4(Float((window.minX - screen.minX) / screen.width),
              Float((screen.maxY - window.maxY) / screen.height),
              Float(window.width / screen.width), Float(window.height / screen.height))
    }
}

enum GlassMask {
    static func image(size: NSSize, radius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}
