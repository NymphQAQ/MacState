import Testing
import AppKit
import MetalKit
@testable import MacState

private struct OpticalImage {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func channel(_ x: Int, _ y: Int, _ c: Int = 0) -> Double { Double(bytes[(y*width+x)*4+c]) }
    var stripeContrast: Double {
        // Away from rims: measure texture detail, not a difference in tint.
        var pairs: [Double] = []
        for y in 55..<135 { for x in 60..<195 { pairs.append(abs(channel(x,y)-channel(x+6,y))) } }
        return pairs.reduce(0,+)/Double(pairs.count)
    }
    func save(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MACSTATE_LENS_ARTIFACTS"] else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width*4, bitsPerPixel: 32)!
        // Metal source is premultiplied BGRA, NSBitmapImageRep is RGBA.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            rep.bitmapData![i] = bytes[i+2]; rep.bitmapData![i+1] = bytes[i+1]
            rep.bitmapData![i+2] = bytes[i]; rep.bitmapData![i+3] = bytes[i+3]
        }
        try rep.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent(name+".png"))
    }
}

private func opticalRender(transparency: Double, components: [GlassComponentGeometry] = []) throws -> OpticalImage {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try LensRenderer(device: device)
    let width = 256, height = 192
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .renderTarget]
    let source = try #require(device.makeTexture(descriptor: descriptor))
    let target = try #require(device.makeTexture(descriptor: descriptor))
    var input = [UInt8](repeating: 255, count: width*height*4)
    for y in 0..<height { for x in 0..<width {
        let i = (y*width+x)*4, stripe = (x/6)%2 == 0
        input[i] = stripe ? 230 : 20
        input[i+1] = UInt8(40+y)
        input[i+2] = stripe ? 35 : 235
    } }
    source.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: input, bytesPerRow: width*4)
    let command = try renderer.encode(source: source, target: target, size: NSSize(width: width,height: height),
        sourceRect: SIMD4(0,0,1,1), opacity: 1-transparency, dark: true, components: components)
    command.commit(); command.waitUntilCompleted()
    #expect(command.status == .completed, "GPU render must complete without validation errors")
    var output = [UInt8](repeating: 0,count: input.count)
    target.getBytes(&output, bytesPerRow: width*4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
    return OpticalImage(bytes: output,width: width,height: height)
}

@Test func lensContinuouslyBlursActualPixelsAndHasTransparentRoundedCorners() throws {
    let frost = try opticalRender(transparency: 0)
    let one = try opticalRender(transparency: 0.01)
    let middle = try opticalRender(transparency: 0.5)
    let clear = try opticalRender(transparency: 1)
    #expect(one.stripeContrast < clear.stripeContrast*0.15, "1% must be visibly frosted, not indistinguishable from 100%")
    #expect(middle.stripeContrast < clear.stripeContrast*0.5)
    #expect(clear.stripeContrast > 80)
    #expect(frost.bytes != middle.bytes && middle.bytes != clear.bytes)
    for image in [frost,one,middle,clear] {
        #expect(image.channel(0,0,3) == 0)
        #expect(image.channel(255,0,3) == 0)
        #expect(image.channel(0,191,3) == 0)
        #expect(image.channel(255,191,3) == 0)
        #expect(image.channel(128,96,3) == 255)
    }
    print("Lens stripe contrast: 0%=\(frost.stripeContrast), 1%=\(one.stripeContrast), 50%=\(middle.stripeContrast), 100%=\(clear.stripeContrast)")
    try frost.save("lens-0"); try one.save("lens-1"); try middle.save("lens-50"); try clear.save("lens-100")
}

@Test func independentLensDoesNotPaintSquareShadowsOutsideItsRoundedSurface() throws {
    let component = GlassComponentGeometry(id:"card", x:50,y:40,width:150,height:110,
        clipX:50,clipY:40,clipWidth:150,clipHeight:110,radius:22)
    let base = try opticalRender(transparency: 1)
    let card = try opticalRender(transparency: 1,components:[component])
    for (x,y) in [(50,40),(199,40),(50,149),(199,149),(49,80),(200,80)] {
        for channel in 0..<4 { #expect(base.channel(x,y,channel) == card.channel(x,y,channel)) }
    }
    #expect(base.bytes != card.bytes, "The component must independently refract the scene")
    try card.save("lens-component")
}

@Test func desktopTextureCoordinatesRespectNegativeDisplayOriginsAndTopEdge() {
    let screen = NSRect(x:-1440,y:100,width:1440,height:900)
    let window = NSRect(x:-1300,y:600,width:500,height:350)
    let uv = LensOptics.sourceRect(window: window,screen: screen)
    #expect(abs(uv.x - 140/1440) < 0.0001)
    #expect(abs(uv.y - 50/900) < 0.0001)
    #expect(abs(uv.z - 500/1440) < 0.0001)
    #expect(abs(uv.w - 350/900) < 0.0001)
    #expect(LensOptics(opacity: 1).refraction == 0)
    #expect(LensOptics(opacity: 0.99).blurPoints > 23)
    #expect(LensOptics(opacity: 0).blurPoints == 0)
}

@Test @MainActor func nativeEnhancementInterpolatesFrostWhileComponentsUseTintedLayers() throws {
    let surface = GlassSurfaceView(frame:NSRect(x:0,y:0,width:600,height:420),contentView:NSView())
    surface.layoutSubtreeIfNeeded()
    if #available(macOS 26.0, *) {
        let frost = try #require(surface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        for opacity in [0.01,0.25,0.5,0.99] {
            surface.configure(theme:"dark",opacity:opacity,nativeLensEnabled:true)
            #expect(abs(frost.alphaValue-opacity) < 0.0001)
            #expect(!frost.isHidden)
        }
        #expect(frost.maskImage != nil)
    }
    let host = ComponentGlassHost(frame:surface.bounds)
    host.update([GlassComponentGeometry(id:"pill",x:5,y:5,width:80,height:30,clipX:5,clipY:5,clipWidth:80,clipHeight:30,radius:15)])
    let plane = try #require(host.planes["pill"])
    #expect(plane.layer?.mask is CAShapeLayer)
    #expect(plane.layer?.masksToBounds == true)
    host.configure(opacity:0.99)
    #expect(plane.subviews.compactMap { $0 as? NSVisualEffectView }.isEmpty)
    #expect(plane.subviews.first?.layer?.cornerRadius == 15)
    #expect(plane.subviews.first?.layer?.borderWidth == 0.5)
}
