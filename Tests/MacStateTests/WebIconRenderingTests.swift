import AppKit
import WebKit
import Testing
@testable import MacState

@Test @MainActor func offlineIconsRenderInNativeWebView() async throws {
    let root = try #require(Bundle.module.url(forResource: "Web", withExtension: nil))
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 660))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)

    var loaded = false
    for _ in 0..<200 {
        loaded = (try? await view.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('.i-layout-dashboard')")) as? Bool == true
        if loaded { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(loaded, "The packaged offline page must load in WKWebView")
    try await Task.sleep(nanoseconds: 200_000_000)

    for light in [false, true] {
        _ = try await view.evaluateJavaScript("document.body.classList.toggle('light', \(light))")
        let rect = try #require(try await view.evaluateJavaScript("(()=>{const r=document.querySelector('.i-layout-dashboard').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()") as? [String: Double])
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: rect["x"]!, y: rect["y"]!, width: rect["width"]!, height: rect["height"]!)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        var paintedPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = max(abs(color.redComponent - background.redComponent), abs(color.greenComponent - background.greenComponent), abs(color.blueComponent - background.blueComponent))
                if difference > 0.15 { paintedPixels += 1 }
            }
        }
        #expect(paintedPixels > 10, "Icon strokes must be visible in the native file:// page, light=\(light)")
        #expect(paintedPixels < bitmap.pixelsWide * bitmap.pixelsHigh * 3 / 4, "The icon must retain its SVG shape rather than a solid rectangle")
    }
}
