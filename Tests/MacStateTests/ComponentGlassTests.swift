import Testing
import AppKit
@testable import MacState

private func component(_ id: String, x: Double = 20, y: Double = -15, width: Double = 200, height: Double = 100) -> GlassComponentGeometry {
    GlassComponentGeometry(id: id, x: x, y: y, width: width, height: height, clipX: x, clipY: max(0,y), clipWidth: width, clipHeight: height, radius: 13)
}

@Test @MainActor func componentGlassClipsScrollingCardsWithoutChangingTheirCurvature() throws {
    let host = ComponentGlassHost(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
    host.configure(opacity: 0.5, nativeLensEnabled: true)
    host.update([component("card"), component("button",x:40,y:20,width:60,height:24)])
    let card = try #require(host.planes["card"])
    #expect(card.frame == NSRect(x: 20, y: 0, width: 200, height: 85))
    if #available(macOS 26.0, *) {
        let glass = try #require(card.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.frame == NSRect(x: 0, y: -15, width: 200, height: 100))
        #expect(glass.cornerRadius == 13)
        #expect(glass.style == .regular)
    }
    #expect(host.hitTest(NSPoint(x: 50, y: 30)) == nil)
    #expect(card.hitTest(.zero) == nil)
    host.update([component("card",y:10)])
    #expect(host.planes["card"] === card)
    #expect(host.planes["button"] == nil)
    #expect(card.frame.minY == 10)
}

@Test @MainActor func zeroTransparencyRemovesEveryComponentLens() {
    let host = ComponentGlassHost(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
    host.update([component("card"),component("control")])
    host.configure(opacity: 1) // User-facing transparency is 1 - opacity.
    #expect(host.planes.values.allSatisfy { $0.isFrosted })
    if #available(macOS 26.0, *) {
        #expect(host.planes.values.allSatisfy { $0.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty })
        host.configure(opacity: 0, nativeLensEnabled: true)
        #expect(host.planes.values.allSatisfy { !$0.isFrosted })
        #expect(host.planes.values.allSatisfy { $0.subviews.compactMap { $0 as? NSGlassEffectView }.count == 1 })
        host.configure(opacity: 0, nativeLensEnabled: false)
        #expect(host.planes.values.allSatisfy { $0.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty })
    }
}

@Test @MainActor func economicalComponentsShareTheWindowBlurWithoutPerCardEffects() {
    let host = ComponentGlassHost(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
    host.update([component("card"), component("control")])
    for plane in host.planes.values {
        #expect(plane.subviews.count == 1)
        #expect(plane.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
        #expect(plane.subviews.first?.layer?.backgroundColor != nil)
        if #available(macOS 26.0, *) {
            #expect(plane.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty)
        }
    }
}

@Test @MainActor func componentGlassRejectsInvalidAndInvisibleGeometry() {
    let host = ComponentGlassHost(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
    host.update([component("invalid",x:.nan),component("outside",x:800),component("oversized",width:100_001),component("valid"),component("valid")])
    #expect(Set(host.planes.keys) == ["valid"])
    host.update([])
    #expect(host.subviews.isEmpty)
}
