import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo

private struct LensUniforms {
    var viewport: SIMD4<Float>
    var sourceRect: SIMD4<Float>
    var optics: SIMD4<Float>
    var tone: SIMD4<Float>
}
private struct LensShape {
    var box: SIMD4<Float>
    var clip: SIMD4<Float>
    var parameters: SIMD4<Float>
    init(_ shape: NSRect, clip: NSRect, radius: Double, root: Bool = false) {
        box = SIMD4(Float(shape.minX), Float(shape.minY), Float(shape.width), Float(shape.height))
        self.clip = SIMD4(Float(clip.minX), Float(clip.minY), Float(clip.width), Float(clip.height))
        parameters = SIMD4(Float(radius), root ? 1 : 0, 0, 0)
    }
}

/// Metal surfaces are decorative only; the H5 foreground stays above them.
final class LensRendererView: MTKView, MTKViewDelegate {
    private let renderer: LensRenderer
    private var source: MTLTexture?
    private var sourceFrame = NSRect.zero
    private var sourceOwner: AnyObject?
    private var cache: CVMetalTextureCache?
    private var opacity = 0.35
    private var dark = true
    private var components: [GlassComponentGeometry] = []
    var onFailure: ((String) -> Void)?

    init?(lensFrame frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? LensRenderer(device: device) else { return nil }
        self.renderer = renderer
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        delegate = self
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(opacity: Double, dark: Bool) {
        self.opacity = opacity; self.dark = dark
        redraw()
    }
    func update(_ components: [GlassComponentGeometry]) {
        self.components = Array(components.prefix(256))
        redraw()
    }
    @discardableResult func receive(_ buffer: CVPixelBuffer, screen: NSRect) -> Bool {
        guard let cache else { return false }
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { return false }
        source = texture; sourceOwner = wrapper; sourceFrame = screen
        return true
    }
    func clearFrame() {
        source = nil; sourceOwner = nil
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }
    func redraw() { if source != nil, !isHidden, window?.isVisible == true { draw() } }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        guard let source, let window, let drawable = currentDrawable else { return }
        do {
            let command = try renderer.encode(source: source, target: drawable.texture, size: bounds.size,
                sourceRect: LensOptics.sourceRect(window: window.frame, screen: sourceFrame),
                opacity: opacity, dark: dark, components: components)
            // Keep the IOSurface alive until the GPU has finished reading it.
            let owner = sourceOwner
            command.addCompletedHandler { _ in withExtendedLifetime(owner) {} }
            command.present(drawable); command.commit()
        } catch { onFailure?(error.localizedDescription) }
    }
}

enum LensRenderError: Error { case unavailable, allocation }

/// Also used by offscreen pixel tests: exactly the production pipelines.
final class LensRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lens: MTLRenderPipelineState
    private let copy: MTLRenderPipelineState
    private var scenes: [MTLTexture] = []
    private var blurredSource: MTLTexture?
    private var gaussian: MPSImageGaussianBlur?
    private var sigma: Float = -1

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "Lens", withExtension: "metal", subdirectory: "Lens") else { throw LensRenderError.unavailable }
        self.queue = queue
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "lensVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        lens = try pipeline("lensFragment"); copy = try pipeline("copyFragment")
    }

    private func texture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]; d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else { throw LensRenderError.allocation }
        return texture
    }

    func encode(source: MTLTexture, target: MTLTexture, size: NSSize, sourceRect: SIMD4<Float>,
                opacity: Double, dark: Bool, components: [GlassComponentGeometry]) throws -> MTLCommandBuffer {
        guard size.width > 0, size.height > 0, let command = queue.makeCommandBuffer() else { throw LensRenderError.unavailable }
        if scenes.first?.width != target.width || scenes.first?.height != target.height {
            scenes = try (0..<2).map { _ in try texture(width: target.width, height: target.height) }
        }
        let profile = LensOptics(opacity: opacity)
        let newSigma = Float(profile.blurPoints) * Float(source.width) * sourceRect.z / Float(size.width)
        var backdrop = source
        if newSigma > 0.05 {
            if blurredSource?.width != source.width || blurredSource?.height != source.height {
                blurredSource = try texture(width: source.width, height: source.height)
            }
            if abs(newSigma - sigma) > 0.01 {
                gaussian = MPSImageGaussianBlur(device: device, sigma: newSigma)
                gaussian?.edgeMode = .clamp; sigma = newSigma
            }
            if let blurredSource {
                gaussian?.encode(commandBuffer: command, sourceTexture: source, destinationTexture: blurredSource)
                backdrop = blurredSource
            }
        }
        var u = LensUniforms(viewport: SIMD4(Float(size.width), Float(size.height), Float(target.width), Float(target.height)),
            sourceRect: sourceRect, optics: SIMD4(Float(profile.refraction), Float((1-profile.transparency)*3), Float(profile.transparency), Float(profile.tint)),
            tone: SIMD4(dark ? 1 : 0, 0, 0, 0))
        let viewport = NSRect(origin: .zero, size: size)
        func paint(_ shapes: [LensShape], source: MTLTexture, target: MTLTexture, clear: Bool, pipeline: MTLRenderPipelineState) throws {
            guard !shapes.isEmpty else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = clear ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass),
                  let buffer = device.makeBuffer(bytes: shapes, length: shapes.count * MemoryLayout<LensShape>.stride) else { throw LensRenderError.allocation }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<LensUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<LensUniforms>.stride, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: shapes.count)
            encoder.endEncoding()
        }
        let root = LensShape(viewport, clip: viewport, radius: 24, root: true)
        try paint([root], source: backdrop, target: scenes[0], clear: true, pipeline: lens)
        // Non-overlapping lenses share a pass; overlapping descendants read
        // their parent's completed scene, avoiding read/write feedback.
        var rects: [(NSRect, Int)] = []
        var groups: [[LensShape]] = []
        for c in components.prefix(256) {
            guard let r = c.rectangles(in: viewport) else { continue }
            let depth = rects.filter { $0.0.intersects(r.clip) }.map { $0.1 + 1 }.max() ?? 0
            while groups.count <= depth { groups.append([]) }
            groups[depth].append(LensShape(r.shape, clip: r.clip, radius: c.radius))
            rects.append((r.clip, depth))
        }
        var current = 0
        for group in groups {
            let next = 1-current
            guard let blit = command.makeBlitCommandEncoder() else { throw LensRenderError.allocation }
            blit.copy(from: scenes[current], to: scenes[next]); blit.endEncoding()
            try paint(group, source: scenes[current], target: scenes[next], clear: false, pipeline: lens)
            current = next
        }
        try paint([root], source: scenes[current], target: target, clear: true, pipeline: copy)
        return command
    }
}
