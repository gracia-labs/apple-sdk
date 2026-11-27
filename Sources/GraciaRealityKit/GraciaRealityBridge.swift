//
//  Compact, bandwidth-optimal RealityKit ↔ GraciaSDK bridge.
//
//  Defaults to .rgba8Unorm (4 B/px) + .d16Unorm (2 B/px). Hardware depth comes straight from the
//  splats tile pass (no DepthResolver), composited against RealityKit in one half4 compute dispatch.
//

import Foundation
import GraciaSDK
import Metal
import QuartzCore
import RealityKit
import simd

/// Scene input loaded on the render thread by ``GraciaRealityBridge``.
public enum GraciaSceneSource: Sendable, Equatable {
    case file(URL, head: Data? = nil, needMesh: Bool = false)
    case mintStream(url: String, token: String? = nil)
    case grvStream(url: String, head: Data? = nil)
}

/// Thread-safe bridge owning a `GraciaContext`, `Scene`, `SplatsRenderer`, and 3-frame ring budget.
public final class GraciaRealityBridge: @unchecked Sendable {
    public static let maxFramesInFlight = 3

    public let colorFormat: ColorFormat
    public let depthFormat: DepthFormat
    public let vr: Bool
    public let audio: AudioOutput
    public let cacheDirectory: URL?

    private struct State {
        var source: GraciaSceneSource?
        var generation = 0
        var model = matrix_identity_float4x4
        var cameraToWorld = matrix_identity_float4x4
        var hasCamera = false
        var isPlaying = true
        var playbackSpeed: Double = 1
        var seek: Double?
        var bounds: GraciaSDK.BoundingBox = .empty
    }

    private let lock = NSLock()
    private var state = State()

    private var device: (any MTLDevice)?
    private var context: GraciaContext?
    private var compositor: Compositor?
    private var scene: GraciaSDK.Scene?
    private var renderer: SplatsRenderer?
    private var loadedGeneration = -1
    private var appliedSettle = true
    private var isReady = true
    private var playhead: Double = 0
    private var lastTime: CFTimeInterval = 0
    private var offscreenColor: (any MTLTexture)?
    private var offscreenDepth: (any MTLTexture)?
    private let frameBudget = DispatchSemaphore(value: maxFramesInFlight)

    public init(
        colorFormat: ColorFormat = .rgba8Unorm,
        depthFormat: DepthFormat = .d16Unorm,
        vr: Bool = false,
        audio: AudioOutput = .device,
        cacheDirectory: URL? = nil
    ) {
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.vr = vr
        self.audio = audio
        self.cacheDirectory = cacheDirectory
    }

    deinit { invalidate() }

    // MARK: - Controls (thread-safe)

    public func load(url: URL, head: Data? = nil, needMesh: Bool = false) {
        setSource(.file(url, head: head, needMesh: needMesh))
    }

    public func load(streamURL: String, token: String? = nil) {
        setSource(.mintStream(url: streamURL, token: token))
    }

    public func load(grvURL: String, head: Data? = nil) {
        setSource(.grvStream(url: grvURL, head: head))
    }

    public func unload() { setSource(nil) }

    public func setSource(_ source: GraciaSceneSource?) {
        lock.withLock { state.source = source; state.generation &+= 1 }
    }

    public func setModelMatrix(_ m: simd_float4x4) { lock.withLock { state.model = m } }

    public func setCameraToWorld(_ m: simd_float4x4) {
        lock.withLock { state.cameraToWorld = m; state.hasCamera = true }
    }

    public var isPlaying: Bool {
        get { lock.withLock { state.isPlaying } }
        set { lock.withLock { state.isPlaying = newValue } }
    }

    public var playbackSpeed: Double {
        get { lock.withLock { state.playbackSpeed } }
        set { lock.withLock { state.playbackSpeed = min(max(newValue, 0), 8) } }
    }

    public func seek(to time: Double) { lock.withLock { state.seek = max(0, time) } }

    public var boundingBox: GraciaSDK.BoundingBox { lock.withLock { state.bounds } }

    @MainActor
    public func sync(entity: Entity, camera: Entity? = nil) {
        setModelMatrix(entity.transformMatrix(relativeTo: nil))
        if let camera { setCameraToWorld(camera.transformMatrix(relativeTo: nil)) }
    }

    // MARK: - Lifecycle

    public func prepare(device: any MTLDevice, commandQueue: (any MTLCommandQueue)? = nil) {
        if self.device === device, context != nil, compositor != nil { return }
        invalidate()
        guard let queue = commandQueue ?? device.makeCommandQueue(),
            let ctx = try? GraciaContext(
                device: device, commandQueue: queue, cacheDirectory: cacheDirectory, audio: audio),
            let comp = try? Compositor(device: device)
        else { return }
        self.device = device
        self.context = ctx
        self.compositor = comp
    }

    /// Drains all in-flight command buffers and frees GPU resources.
    public func invalidate() {
        drain {
            context?.waitUntilIdle()
            scene = nil; renderer = nil
            offscreenColor = nil; offscreenDepth = nil
            compositor = nil; context = nil; device = nil
            loadedGeneration = -1; appliedSettle = true; isReady = true
            playhead = 0; lastTime = 0
        }
    }

    // MARK: - Render (render thread)

    /// Renders splats (`.rgba8Unorm` + direct `.d16Unorm` depth, no `DepthResolver`) and composites
    /// against RealityKit colour and depth into `targetColor` (must have `.shaderWrite`).
    /// The compositor converts splat RGB from sRGB to linear before it blends the colors.
    public func encodeComposite(
        sourceColor: any MTLTexture,
        sourceDepth: (any MTLTexture)?,
        targetColor: any MTLTexture,
        projection: simd_float4x4,
        cameraToWorld: simd_float4x4? = nil,
        commandBuffer: any MTLCommandBuffer
    ) {
        if context == nil { prepare(device: commandBuffer.device) }
        guard let compositor else { return }

        let s = takeState()
        stepLifecycle(s)

        let cam = cameraToWorld ?? s.cameraToWorld
        let w = targetColor.width, h = targetColor.height
        guard (cameraToWorld != nil || s.hasCamera), w > 0, h > 0,
            ensureOffscreen(width: w, height: h),
            let spColor = offscreenColor, let spDepth = offscreenDepth
        else {
            compositor.copy(from: sourceColor, to: targetColor, commandBuffer: commandBuffer)
            return
        }

        let view = RenderView(projection: projection, cameraToWorld: cam)
        let drew = encodeSplats(
            state: s, colorTexture: spColor, depthTexture: spDepth, views: [view],
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
            rasterizationRateMap: nil, commandBuffer: commandBuffer)

        if drew {
            compositor.composite(
                realityColor: sourceColor, realityDepth: sourceDepth,
                splatColor: spColor, splatDepth: spDepth, targetColor: targetColor,
                reverseZ: GraciaMatrix.isReverseZ(projection), commandBuffer: commandBuffer)
        } else {
            compositor.copy(from: sourceColor, to: targetColor, commandBuffer: commandBuffer)
        }
    }

    /// Renders splats directly into a caller-owned RGBA colour + depth target (mono or stereo
    /// multiview) with zero offscreen copy. Supports `.memoryless` depth attachments.
    @discardableResult
    public func encodeDirect(
        colorTexture: any MTLTexture,
        depthTexture: any MTLTexture,
        views: [RenderView],
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
        rasterizationRateMap: (any MTLRasterizationRateMap)? = nil,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        if context == nil { prepare(device: commandBuffer.device) }
        let s = takeState()
        stepLifecycle(s)
        return encodeSplats(
            state: s, colorTexture: colorTexture, depthTexture: depthTexture, views: views,
            clearColor: clearColor, rasterizationRateMap: rasterizationRateMap,
            commandBuffer: commandBuffer)
    }

    // MARK: - Internals

    private func encodeSplats(
        state s: State,
        colorTexture: any MTLTexture,
        depthTexture: any MTLTexture,
        views: [RenderView],
        clearColor: MTLClearColor,
        rasterizationRateMap: (any MTLRasterizationRateMap)?,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard let first = views.first else { return false }
        let reverseZ = GraciaMatrix.isReverseZ(first.projection)
        let stereo: StereoMode = views.count > 1 ? .multiview : .multipass
        let pass = SplatsPassDescriptor(
            colorFormat: colorFormat,
            depth: .splats(format: depthFormat, reverseZ: reverseZ),
            stereo: stereo, depthStereo: stereo)

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = colorTexture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .store
        desc.colorAttachments[0].clearColor = clearColor
        desc.depthAttachment.texture = depthTexture
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = depthTexture.storageMode == .memoryless ? .dontCare : .store
        desc.depthAttachment.clearDepth = pass.clearDepth
        if views.count > 1, colorTexture.textureType == .type2DArray {
            desc.renderTargetArrayLength = views.count
        }
        if let rasterizationRateMap { desc.rasterizationRateMap = rasterizationRateMap }

        guard appliedSettle, let scene, let renderer,
            frameBudget.wait(timeout: .now() + .milliseconds(100)) == .success
        else {
            commandBuffer.makeRenderCommandEncoder(descriptor: desc)?.endEncoding()
            return false
        }

        var handedOff = false
        defer { if !handedOff { frameBudget.signal() } }

        scene.setTransform(s.model)
        context?.setListener(cameraToWorld: first.cameraToWorld)

        let frame = renderer.render(
            scenes: [scene], views: views,
            targetWidth: UInt32(max(colorTexture.width, 1)),
            targetHeight: UInt32(max(colorTexture.height, 1)),
            pass: pass, commandBuffer: commandBuffer)

        if let enc = renderer.makeRenderCommandEncoder(commandBuffer, descriptor: desc, pass: pass) {
            if views.count > 1 {
                let vp = MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(colorTexture.width), height: Double(colorTexture.height),
                    znear: 0, zfar: 1)
                enc.setViewports([vp, vp])
                enc.setVertexAmplificationCount(2, viewMappings: [
                    .init(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                    .init(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1),
                ])
            }
            frame.color.mono?.execute(into: enc)
            enc.endEncoding()
        }

        let budget = frameBudget
        commandBuffer.addCompletedHandler { _ in _ = frame; budget.signal() }
        handedOff = true
        return true
    }

    private func takeState() -> State {
        lock.withLock { let copy = state; state.seek = nil; return copy }
    }

    private func stepLifecycle(_ s: State) {
        if s.generation != loadedGeneration { reload(s.source, generation: s.generation) }

        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : min(now - lastTime, 0.25)
        lastTime = now

        guard let scene, scene.isVideo else { return }
        if let seek = s.seek, scene.duration > 0 {
            playhead = min(max(0, seek), max(0, scene.duration - 0.001))
            isReady = false
        }
        let moves = s.isPlaying && isReady && scene.duration > 0
        if moves {
            playhead += dt * s.playbackSpeed
            if playhead >= scene.duration { playhead = 0 }
        }
        scene.setTime(playhead)
        scene.setSpeed(moves ? s.playbackSpeed : 0)
        isReady = scene.pump()

        if !appliedSettle, scene.isSettled {
            appliedSettle = true
            drain { context?.waitUntilIdle(); rebuildRenderer() }
            if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
            publishBounds()
        }
    }

    private func reload(_ source: GraciaSceneSource?, generation: Int) {
        loadedGeneration = generation
        drain {
            context?.waitUntilIdle()
            scene = nil; renderer = nil
            playhead = 0; isReady = true; appliedSettle = true
            guard let context, let source else { publishBounds(); return }
            switch source {
            case .file(let url, let head, let needMesh):
                scene = try? GraciaSDK.Scene(url: url, context: context, head: head, needMesh: needMesh)
            case .mintStream(let url, let token):
                scene = try? GraciaSDK.Scene(streamURL: url, context: context, token: token)
            case .grvStream(let url, let head):
                scene = try? GraciaSDK.Scene(grvURL: url, context: context, head: head)
            }
            if let scene {
                isReady = !scene.isVideo
                appliedSettle = scene.isSettled
                if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
                rebuildRenderer()
            }
            publishBounds()
        }
    }

    private func rebuildRenderer() {
        guard let context, let scene else { renderer = nil; return }
        renderer = nil
        renderer = try? SplatsRenderer(
            context: context, maxSplatsCount: max(scene.splatsBudget, 1), vr: vr)
    }

    private func publishBounds() {
        let box = scene.map { $0.adaptiveBBox.isValid ? $0.adaptiveBBox : $0.boundingBox } ?? .empty
        lock.withLock { state.bounds = box }
    }

    private func ensureOffscreen(width: Int, height: Int) -> Bool {
        guard let device else { return false }
        let cf = colorFormat.metalPixelFormat, df = depthFormat.metalPixelFormat
        if let c = offscreenColor, let d = offscreenDepth,
            c.width == width, c.height == height, c.pixelFormat == cf, d.pixelFormat == df
        { return true }
        let make = { (fmt: MTLPixelFormat) -> (any MTLTexture)? in
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        guard let c = make(cf), let d = make(df) else { return false }
        offscreenColor = c; offscreenDepth = d
        return true
    }

    private func drain(_ body: () -> Void) {
        for _ in 0..<Self.maxFramesInFlight { frameBudget.wait() }
        defer { for _ in 0..<Self.maxFramesInFlight { frameBudget.signal() } }
        body()
    }
}

// MARK: - Embedded half4 Metal compute compositor

extension GraciaRealityBridge {
    final class Compositor {
        let device: any MTLDevice
        private let depthPSO: any MTLComputePipelineState
        private let colorPSO: any MTLComputePipelineState
        private let copyPSO: any MTLComputePipelineState

        init(device: any MTLDevice) throws {
            self.device = device
            let lib = try device.makeLibrary(source: Self.msl, options: nil)
            depthPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "compositeDepth")!)
            colorPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "compositeColor")!)
            copyPSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "copyColor")!)
        }

        func copy(from src: any MTLTexture, to dst: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
            if src.pixelFormat == dst.pixelFormat, src.width == dst.width, src.height == dst.height,
                let blit = commandBuffer.makeBlitCommandEncoder()
            {
                blit.copy(from: src, to: dst); blit.endEncoding(); return
            }
            guard dst.usage.contains(.shaderWrite), let enc = commandBuffer.makeComputeCommandEncoder() else { return }
            enc.setComputePipelineState(copyPSO)
            enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1)
            dispatch(enc, copyPSO, dst.width, dst.height); enc.endEncoding()
        }

        func composite(
            realityColor: any MTLTexture, realityDepth: (any MTLTexture)?,
            splatColor: any MTLTexture, splatDepth: any MTLTexture,
            targetColor: any MTLTexture, reverseZ: Bool, commandBuffer: any MTLCommandBuffer
        ) {
            guard targetColor.usage.contains(.shaderWrite),
                let enc = commandBuffer.makeComputeCommandEncoder()
            else { return }
            var rev: UInt32 = reverseZ ? 1 : 0
            if let realityDepth {
                enc.setComputePipelineState(depthPSO)
                enc.setTexture(realityColor, index: 0); enc.setTexture(realityDepth, index: 1)
                enc.setTexture(splatColor, index: 2); enc.setTexture(splatDepth, index: 3)
                enc.setTexture(targetColor, index: 4)
                enc.setBytes(&rev, length: MemoryLayout<UInt32>.size, index: 0)
                dispatch(enc, depthPSO, targetColor.width, targetColor.height)
            } else {
                enc.setComputePipelineState(colorPSO)
                enc.setTexture(realityColor, index: 0); enc.setTexture(splatColor, index: 1)
                enc.setTexture(targetColor, index: 2)
                dispatch(enc, colorPSO, targetColor.width, targetColor.height)
            }
            enc.endEncoding()
        }

        private func dispatch(
            _ enc: any MTLComputeCommandEncoder, _ pso: any MTLComputePipelineState, _ w: Int, _ h: Int
        ) {
            let tw = pso.threadExecutionWidth
            let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }

        private static let msl = """
        #include <metal_stdlib>
        using namespace metal;

        inline half4 linearizeSplatColor(half4 splat) {
            // Remove premultiplication before the sRGB conversion, then restore it.
            half3 srgb = saturate(splat.rgb / splat.a);
            half3 linear = select(srgb / 12.92h,
                                  powr((srgb + 0.055h) / 1.055h, half3(2.4h)),
                                  srgb > 0.04045h);
            return half4(linear * splat.a, splat.a);
        }

        kernel void copyColor(
            texture2d<half, access::read> src [[texture(0)]],
            texture2d<half, access::write> dst [[texture(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            dst.write(src.read(gid), gid);
        }

        kernel void compositeDepth(
            texture2d<half, access::read> rkColor [[texture(0)]],
            depth2d<float, access::read> rkDepth [[texture(1)]],
            texture2d<half, access::read> spColor [[texture(2)]],
            depth2d<float, access::read> spDepth [[texture(3)]],
            texture2d<half, access::write> dst [[texture(4)]],
            constant uint &reverseZ [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            half4 sp = spColor.read(gid);
            half4 rk = rkColor.read(gid);
            if (sp.a < 1e-3h) { dst.write(rk, gid); return; }
            sp = linearizeSplatColor(sp);
            float rkD = rkDepth.read(gid);
            float spD = spDepth.read(gid);
            bool inFront = reverseZ ? (spD >= rkD) : (spD <= rkD);
            half4 out = inFront
                ? half4(sp.rgb + rk.rgb * (1.0h - sp.a), sp.a + rk.a * (1.0h - sp.a))
                : half4(rk.rgb + sp.rgb * (1.0h - rk.a), rk.a + sp.a * (1.0h - rk.a));
            dst.write(out, gid);
        }

        kernel void compositeColor(
            texture2d<half, access::read> rkColor [[texture(0)]],
            texture2d<half, access::read> spColor [[texture(1)]],
            texture2d<half, access::write> dst [[texture(2)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            half4 sp = spColor.read(gid);
            half4 rk = rkColor.read(gid);
            if (sp.a < 1e-3h) { dst.write(rk, gid); return; }
            sp = linearizeSplatColor(sp);
            dst.write(half4(sp.rgb + rk.rgb * (1.0h - sp.a), sp.a + rk.a * (1.0h - sp.a)), gid);
        }
        """
    }
}
