import AppKit
import CoreImage
import ImageIO
import MetalKit
import QuartzCore

/// Native host for the supported subset of Wallpaper Engine scene projects.
/// Metal renders image layers, masked water-wave effects and procedural rain.
final class SceneWallpaperView: NSView {
    private let metalView: MTKView
    private let renderer: SceneMetalRenderer

    init(
        frame: NSRect,
        scene: SceneWallpaper
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SceneWallpaperError.metalUnavailable
        }

        metalView = MTKView(frame: frame, device: device)
        renderer = try SceneMetalRenderer(
            view: metalView,
            scene: scene
        )
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
    }

    func setPaused(_ paused: Bool) {
        renderer.setPaused(paused)
        metalView.isPaused = paused
    }

    func captureNextFrame(
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        renderer.captureNextFrame(to: url, completion: completion)
    }

}

private struct SceneEffectUniforms {
    var time: Float
    var direction: Float
    var speed: Float
    var scale: Float
    var strength: Float
    var perspective: Float
    var sourceScaleX: Float
    var sourceScaleY: Float
    var usesMask: UInt32
    var showsRain: UInt32
    var isFinalPass: UInt32
}

private final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOutput {
        float4 position [[position]];
        float2 uv;
    };

    struct EffectUniforms {
        float time;
        float direction;
        float speed;
        float scale;
        float strength;
        float perspective;
        float sourceScaleX;
        float sourceScaleY;
        uint usesMask;
        uint showsRain;
        uint isFinalPass;
    };

    vertex VertexOutput liveWallSceneVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 coordinates[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };

        VertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.uv = coordinates[vertexID];
        return output;
    }

    fragment float4 liveWallSceneFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> sourceTexture [[texture(0)]],
        texture2d<float> maskTexture [[texture(1)]],
        sampler textureSampler [[sampler(0)]],
        constant EffectUniforms &uniforms [[buffer(0)]]
    ) {
        float2 scale = float2(uniforms.sourceScaleX, uniforms.sourceScaleY);
        float2 textureCoordinate = (input.uv - 0.5) * scale + 0.5;

        if (uniforms.strength > 0.0) {
            float sineDirection = sin(uniforms.direction);
            float cosineDirection = cos(uniforms.direction);
            float2 direction = float2(-sineDirection, cosineDirection);
            float position = abs(dot(textureCoordinate - 0.5, direction));
            float distance =
                uniforms.time * uniforms.speed
                + dot(textureCoordinate, direction)
                    * (uniforms.scale + uniforms.perspective * position);
            float mask = uniforms.usesMask == 1
                ? maskTexture.sample(textureSampler, input.uv).r
                : 1.0;
            float2 offset = float2(direction.y, -direction.x);
            float strength =
                uniforms.strength * uniforms.strength
                + uniforms.perspective * position;
            textureCoordinate += sin(distance) * offset * strength * mask;
        }

        float4 color = sourceTexture.sample(textureSampler, textureCoordinate);
        if (uniforms.showsRain == 1 && uniforms.isFinalPass == 1) {
            float columns = 150.0;
            float column = floor(input.uv.x * columns);
            float columnPosition = fract(input.uv.x * columns);
            float randomValue = fract(sin(column * 91.3458) * 47453.5453);
            float head = fract(randomValue + uniforms.time * (0.78 + randomValue * 0.75));
            float trailDistance = fract(input.uv.y - head);
            float horizontal = 1.0 - smoothstep(0.025, 0.12, abs(columnPosition - 0.5));
            float vertical = 1.0 - smoothstep(0.0, 0.095, trailDistance);
            float visibility = step(0.68, fract(randomValue * 19.17));
            float rain = horizontal * vertical * visibility;
            color.rgb += rain * float3(0.34, 0.48, 0.58);
        }
        return color;
    }
    """

    private weak var view: MTKView?
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let sourceTexture: MTLTexture
    private let maskTextures: [MTLTexture?]
    private let whiteMaskTexture: MTLTexture
    private let effects: [SceneWaveEffect]
    private let showsRain: Bool
    private var intermediateTextures: [MTLTexture] = []
    private var drawableSize = CGSize.zero
    private var startTime = CACurrentMediaTime()
    private var pauseStartedAt: CFTimeInterval?
    private var pausedDuration: CFTimeInterval = 0
    private var snapshotRequest: (
        url: URL,
        completion: (Result<Void, Error>) -> Void
    )?

    init(
        view: MTKView,
        scene: SceneWallpaper
    ) throws {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else {
            throw SceneWallpaperError.metalUnavailable
        }

        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        do {
            let library = try device.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
            guard let vertex = library.makeFunction(
                name: "liveWallSceneVertex"
            ),
            let fragment = library.makeFunction(
                name: "liveWallSceneFragment"
            ) else {
                throw SceneWallpaperError.rendererInitialization(
                    "The Metal shader functions were not created."
                )
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "LiveWall Scene Pipeline"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineState = try device.makeRenderPipelineState(
                descriptor: descriptor
            )
        } catch let error as SceneWallpaperError {
            throw error
        } catch {
            throw SceneWallpaperError.rendererInitialization(
                error.localizedDescription
            )
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(
            descriptor: samplerDescriptor
        ) else {
            throw SceneWallpaperError.rendererInitialization(
                "The texture sampler was not created."
            )
        }

        let textureLoader = MTKTextureLoader(device: device)
        do {
            sourceTexture = try textureLoader.newTexture(
                cgImage: scene.image,
                options: [
                    .SRGB: true,
                    .origin: MTKTextureLoader.Origin.topLeft
                ]
            )
        } catch {
            throw SceneWallpaperError.rendererInitialization(
                "The scene image could not be uploaded: \(error.localizedDescription)"
            )
        }

        guard let whiteMask = Self.makeMaskTexture(
            device: device,
            mask: SceneMask(width: 1, height: 1, pixels: Data([255]))
        ) else {
            throw SceneWallpaperError.rendererInitialization(
                "The fallback effect mask was not created."
            )
        }

        self.view = view
        self.commandQueue = commandQueue
        self.samplerState = sampler
        self.effects = Array(scene.waveEffects.prefix(8))
        self.showsRain = scene.showsRain
        self.maskTextures = self.effects.map {
            guard let mask = $0.mask else { return nil }
            return Self.makeMaskTexture(device: device, mask: mask)
        }
        self.whiteMaskTexture = whiteMask
        super.init()
        view.delegate = self
    }

    func setPaused(_ paused: Bool) {
        if paused {
            if pauseStartedAt == nil {
                pauseStartedAt = CACurrentMediaTime()
            }
        } else if let pauseStartedAt {
            pausedDuration += CACurrentMediaTime() - pauseStartedAt
            self.pauseStartedAt = nil
        }
    }

    func captureNextFrame(
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        snapshotRequest = (url, completion)
        requestSnapshotDraw(attempt: 0)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        intermediateTextures.removeAll()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              drawable.texture.width > 0,
              drawable.texture.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        ensureIntermediateTextures(
            device: drawable.texture.device,
            width: drawable.texture.width,
            height: drawable.texture.height,
            pixelFormat: view.colorPixelFormat
        )

        let now = pauseStartedAt ?? CACurrentMediaTime()
        let time = Float(now - startTime - pausedDuration)
        let passes: [SceneWaveEffect?] = effects.isEmpty
            ? [nil]
            : effects.map(Optional.some)

        var source = sourceTexture
        for index in passes.indices {
            let isLast = index == passes.index(before: passes.endIndex)
            let target: MTLTexture
            if isLast {
                target = drawable.texture
            } else {
                target = intermediateTextures[index % 2]
            }

            let sourceScale = index == 0
                ? Self.aspectFillScale(source: source, destination: target)
                : SIMD2<Float>(1, 1)
            let effect = passes[index]
            var uniforms = SceneEffectUniforms(
                time: time,
                direction: effect?.direction ?? 0,
                speed: effect?.speed ?? 0,
                scale: effect?.scale ?? 0,
                strength: effect?.strength ?? 0,
                perspective: effect?.perspective ?? 0,
                sourceScaleX: sourceScale.x,
                sourceScaleY: sourceScale.y,
                usesMask: effect?.mask == nil ? 0 : 1,
                showsRain: showsRain ? 1 : 0,
                isFinalPass: isLast ? 1 : 0
            )
            let mask = index < maskTextures.count
                ? maskTextures[index] ?? whiteMaskTexture
                : whiteMaskTexture

            encodePass(
                commandBuffer: commandBuffer,
                source: source,
                mask: mask,
                target: target,
                uniforms: &uniforms
            )
            source = target
        }

        commandBuffer.present(drawable)
        let snapshot = snapshotRequest
        snapshotRequest = nil
        if let snapshot {
            let device = commandQueue.device
            commandBuffer.addCompletedHandler { buffer in
                let result: Result<Void, Error>
                if let error = buffer.error {
                    result = .failure(error)
                } else {
                    result = Self.writePNG(
                        texture: drawable.texture,
                        device: device,
                        url: snapshot.url
                    )
                }
                DispatchQueue.main.async {
                    snapshot.completion(result)
                }
            }
        }
        commandBuffer.commit()
    }

    private func requestSnapshotDraw(attempt: Int) {
        guard snapshotRequest != nil else { return }
        view?.draw()
        guard snapshotRequest != nil else { return }
        guard attempt < 40 else {
            let completion = snapshotRequest?.completion
            snapshotRequest = nil
            completion?(.failure(
                SceneWallpaperError.snapshotFailed(
                    "No Metal drawable became available."
                )
            ))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.requestSnapshotDraw(attempt: attempt + 1)
        }
    }

    private func encodePass(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        mask: MTLTexture,
        target: MTLTexture,
        uniforms: inout SceneEffectUniforms
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor
        ) else {
            return
        }

        encoder.label = "LiveWall Scene Effect Pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(mask, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<SceneEffectUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        encoder.endEncoding()
    }

    private func ensureIntermediateTextures(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) {
        let requiredCount = effects.count > 1 ? 2 : 0
        guard requiredCount > 0 else {
            intermediateTextures.removeAll()
            return
        }
        if intermediateTextures.count == requiredCount,
           drawableSize.width == CGFloat(width),
           drawableSize.height == CGFloat(height) {
            return
        }

        drawableSize = CGSize(width: width, height: height)
        intermediateTextures = (0..<requiredCount).compactMap { index in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .renderTarget]
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = "LiveWall Scene Intermediate \(index)"
            return texture
        }
    }

    private static func makeMaskTexture(
        device: MTLDevice,
        mask: SceneMask
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: mask.width,
            height: mask.height,
            mipmapped: false
        )
        descriptor.storageMode = .managed
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        mask.pixels.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, mask.width, mask.height),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: mask.width
            )
        }
        return texture
    }

    private static func aspectFillScale(
        source: MTLTexture,
        destination: MTLTexture
    ) -> SIMD2<Float> {
        let sourceAspect = Float(source.width) / Float(source.height)
        let destinationAspect = Float(destination.width) / Float(destination.height)
        if sourceAspect > destinationAspect {
            return SIMD2<Float>(destinationAspect / sourceAspect, 1)
        }
        return SIMD2<Float>(1, sourceAspect / destinationAspect)
    }

    private static func writePNG(
        texture: MTLTexture,
        device: MTLDevice,
        url: URL
    ) -> Result<Void, Error> {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let image = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: colorSpace]
        ) else {
            return .failure(
                SceneWallpaperError.snapshotFailed(
                    "Core Image could not read the Metal texture."
                )
            )
        }

        let context = CIContext(mtlDevice: device)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: texture.width,
            height: texture.height
        )
        let correctedImage = image.oriented(.downMirrored)
        guard let cgImage = context.createCGImage(correctedImage, from: bounds),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.png" as CFString,
                  1,
                  nil
              ) else {
            return .failure(
                SceneWallpaperError.snapshotFailed(
                    "The rendered image could not be encoded."
                )
            )
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(
                SceneWallpaperError.snapshotFailed(
                    "The PNG encoder did not finish."
                )
            )
        }
        return .success(())
    }
}
