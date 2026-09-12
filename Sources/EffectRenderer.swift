import AppKit
import CoreImage
import MetalKit

private struct GPUUniforms {
    var progress: Float
    var topScale: Float
    var maxBlur: Float
    var falloff: Float
    var darkening: Float
    var frost: Float
    var reducedMotion: Float
    var maxLod: Float
}

final class EffectGPU {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let context: CIContext
    private let renderPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var input: MTLTexture?
    private var levels: [MTLTexture] = []
    private var horizontalLevels: [MTLTexture] = []

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { throw RendererError.noMetal }
        self.device = device
        self.commandQueue = commandQueue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])

        guard let shaderURL = Bundle.main.url(forResource: "fold-like-Duo", withExtension: "metal") else {
            throw RendererError.missingShader
        }
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "effectVertex"),
              let fragment = library.makeFunction(name: "effectFragment"),
              let downsample = library.makeFunction(name: "blurDownsample")
        else { throw RendererError.missingFunction }

        downsamplePipeline = try device.makeComputePipelineState(function: downsample)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func upload(_ image: CIImage, commandBuffer: MTLCommandBuffer) {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(1.0, 2880.0 / extent.width)
        let width = max(Int(extent.width * scale), 1)
        let height = max(Int(extent.height * scale), 1)
        ensureInput(width: width, height: height)
        guard let input else { return }

        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                               y: CGFloat(height) / extent.height))
        context.render(normalized,
                       to: input,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: colorSpace)

        guard levels.count > 1 else { return }
        for level in 1..<levels.count {
            encodeDownsample(commandBuffer,
                             source: levels[level - 1],
                             target: horizontalLevels[level - 1],
                             horizontal: true)
            encodeDownsample(commandBuffer,
                             source: horizontalLevels[level - 1],
                             target: levels[level],
                             horizontal: false)
        }
    }

    func encode(target: MTLTexture,
                commandBuffer: MTLCommandBuffer,
                parameters: EffectParameters,
                progress: Double,
                viewWidthPoints: CGFloat) {
        guard let input else { return }
        let pixelScale = Double(input.width) / max(Double(viewWidthPoints), 1)
        var uniforms = GPUUniforms(
            progress: Float(min(max(progress, 0), 1)),
            topScale: Float(parameters.topScale(for: progress)),
            maxBlur: Float(max(parameters.blurRadius, 0) * max(pixelScale, 0.5)),
            falloff: Float(parameters.blurFalloff),
            darkening: Float(parameters.darkening),
            frost: Float(parameters.frost),
            reducedMotion: parameters.reducedMotion ? 1 : 0,
            maxLod: Float(max(input.mipmapLevelCount - 1, 0))
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func ensureInput(width: Int, height: Int) {
        guard input?.width != width || input?.height != height else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                   width: width,
                                                                   height: height,
                                                                   mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        input = device.makeTexture(descriptor: descriptor)
        guard let input else { return }
        levels = (0..<input.mipmapLevelCount).compactMap { level in
            input.makeTextureView(pixelFormat: .rgba16Float,
                                  textureType: .type2D,
                                  levels: level..<(level + 1),
                                  slices: 0..<1)
        }
        horizontalLevels = (1..<levels.count).compactMap { level in
            let temporary = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                      width: levels[level].width,
                                                                      height: levels[level - 1].height,
                                                                      mipmapped: false)
            temporary.usage = [.shaderRead, .shaderWrite]
            temporary.storageMode = .private
            return device.makeTexture(descriptor: temporary)
        }
    }

    private func encodeDownsample(_ commandBuffer: MTLCommandBuffer,
                                  source: MTLTexture,
                                  target: MTLTexture,
                                  horizontal: Bool) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var direction: UInt32 = horizontal ? 1 : 0
        encoder.setComputePipelineState(downsamplePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&direction, length: MemoryLayout<UInt32>.stride, index: 0)
        let width = downsamplePipeline.threadExecutionWidth
        let height = max(downsamplePipeline.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }
}

final class EffectMetalView: MTKView, MTKViewDelegate {
    var parameters = EffectParameters() {
        didSet { isPaused = false }
    }
    var targetProgress: Double = 0 {
        didSet { isPaused = false }
    }
    var source: CIImage? {
        didSet {
            pendingSource = source
            isPaused = false
        }
    }
    var onPresented: (() -> Void)?

    private let gpu: EffectGPU?
    private var pendingSource: CIImage?
    private var hasSource = false
    private var motion = CriticallyDampedMotion()
    private var lastTimestamp: CFTimeInterval?
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var initializationError: String?

    init() {
        do {
            let gpu = try EffectGPU()
            self.gpu = gpu
            super.init(frame: .zero, device: gpu.device)
        } catch {
            self.gpu = nil
            self.initializationError = error.localizedDescription
            super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        }
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 120
        autoResizeDrawable = true
        delegate = self
        autoresizingMask = [.width, .height]
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (layer as? CAMetalLayer)?.displaySyncEnabled = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        preferredFramesPerSecond = min(window?.screen?.maximumFramesPerSecond ?? 60, 120)
        if window == nil { isPaused = true }
    }

    func resetMotion(to value: Double = 0) {
        motion.reset(to: value)
        lastTimestamp = nil
        isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        isPaused = false
    }

    func draw(in view: MTKView) {
        guard let gpu,
              hasSource || pendingSource != nil,
              drawableSize.width > 0,
              drawableSize.height > 0,
              inFlight.wait(timeout: .now()) == .success,
              let drawable = currentDrawable,
              let commandBuffer = gpu.commandQueue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { now - $0 } ?? 1.0 / Double(max(preferredFramesPerSecond, 60))
        lastTimestamp = now
        let progress = motion.step(target: targetProgress,
                                   dt: dt,
                                   reducedMotion: parameters.reducedMotion)
        if let pendingSource {
            gpu.upload(pendingSource, commandBuffer: commandBuffer)
            self.pendingSource = nil
            hasSource = true
        }
        gpu.encode(target: drawable.texture,
                   commandBuffer: commandBuffer,
                   parameters: parameters,
                   progress: progress,
                   viewWidthPoints: bounds.width)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlight.signal()
            DispatchQueue.main.async { self?.onPresented?() }
        }
        commandBuffer.commit()

        if abs(motion.value - targetProgress) < 0.0001, abs(motion.velocity) < 0.002 {
            isPaused = true
            lastTimestamp = nil
        }
    }
}

enum RendererError: LocalizedError {
    case noMetal
    case missingShader
    case missingFunction

    var errorDescription: String? {
        switch self {
        case .noMetal: L10n.text("A Metal-capable GPU is required.")
        case .missingShader: L10n.text("The fold-like-Duo shader is missing. Reinstall the app.")
        case .missingFunction: L10n.text("The fold-like-Duo shader could not be loaded.")
        }
    }
}
