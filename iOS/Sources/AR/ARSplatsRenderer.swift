//
//  Composites a Gracia scene over the live ARKit camera feed.
//
//  Per frame: draw the camera image (a full-screen quad), then blend the splats on top using
//  ARKit's own camera pose and projection. The scene sits at a world-space anchor the user taps to
//  place, scaled to a comfortable real-world size.
//
//  ARKit's `projectionMatrix(for:…)` is a conventional right-handed [0,1] projection (near→0,
//  far→1), so the splat pass is configured non-reverse-Z to match. `cameraToWorld` is
//  `viewMatrix(for:).inverse`: GraciaSDK inverts it back to exactly `viewMatrix(for:)`, so the
//  render stays aligned with the displayed image regardless of interface orientation.
//

import ARKit
import GraciaSDK
import Metal
import QuartzCore
import UIKit
import simd

struct ARStatus {
    var isPlaced: Bool
    var visibleSplats: UInt32
    var hasVideo: Bool
}

final class ARSplatsRenderer {
    static let maxFramesInFlight = 3

    /// Conventional-depth pass, to agree with ARKit's projection (near→0, far→1, clear 1, compare
    /// less). The depth attachment also selects the SDK's tile path.
    private let pass = SplatsPassDescriptor(
        colorFormat: .rgba8Unorm, depth: .splats(format: .d16Unorm, reverseZ: false))
    private let pixelFormat: MTLPixelFormat = .rgba8Unorm

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let layer: CAMetalLayer
    let context: GraciaContext
    private let background: CameraBackground
    private let environment: EnvironmentProbe

    private var scene: Scene?
    private var renderer: SplatsRenderer?
    private var depthTexture: (any MTLTexture)?

    // Environment lighting (opt-in), driven by the preset bar. `forcedPreset` (16 floats) overrides
    // the live probe when set. Off by default so it never disturbs the base AR path.
    private(set) var environmentLightingEnabled = false
    private var forcedPreset: [Float]?
    private var worldSH: [SIMD3<Float>]?
    private var envApplied = false

    /// True when env lighting is on and following the live probe (not a forced preset).
    var usingProbe: Bool { environmentLightingEnabled && forcedPreset == nil }

    // Placement + manipulation, all in world space.
    private var anchor: SIMD3<Float>?
    private var userYaw: Float = 0
    private var userScale: Float = 1
    /// Bounding-sphere radius the scene is scaled to, in metres.
    private let targetRadius: Float = 0.3

    // Playback.
    var isPlaying = true
    private var playhead: Double = 0
    private var lastTime: CFTimeInterval = 0
    private var appliedSettle = true

    // Frames in flight — same rule as the viewer: at most three, freed deterministically.
    private let frameBudget = DispatchSemaphore(value: maxFramesInFlight)
    private var inFlight = [[Frame]](repeating: [], count: maxFramesInFlight)
    private var frameIndex = 0

    var onStatus: ((ARStatus) -> Void)?
    var hasPlacement: Bool { anchor != nil }
    /// World position the scene is anchored at, for picking the nearest environment probe.
    var scenePosition: SIMD3<Float>? { anchor }

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { throw GraciaError.contextCreationFailed }
        self.device = device
        self.queue = queue
        self.layer = layer

        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.framebufferOnly = true

        context = try GraciaContext(device: device, commandQueue: queue)
        background = try CameraBackground(device: device, colorPixelFormat: pixelFormat)
        environment = try EnvironmentProbe(device: device, queue: queue)
    }

    /// Projects a fresh environment-probe cube map into SH-L1 (world frame). Call when ARKit hands
    /// over a new/updated `environmentTexture`.
    func updateEnvironmentProbe(_ cube: any MTLTexture) {
        guard let raw = environment.project(cube) else {
            print("gracia AR: env probe projection failed (type=\(cube.textureType.rawValue))")
            return
        }
        let calibrated = calibrate(raw)
        worldSH = calibrated
        print("gracia AR: env DC=\(calibrated[0]) (raw DC=\(raw[0]))")
    }

    // MARK: - Environment presets

    /// The SDK's named lighting presets (radiance SH-L1), packed to the 16-float layout.
    static let presets: [(name: String, sh: [Float])] = [
        ("Daylight", envSH(3.62, 3.54, 3.37, 0.5, 0.45, 0.4)),
        ("Cloudy", envSH(3.19, 3.26, 3.44, 0.05, 0.05, 0.07)),
        ("Sunset", envSH(4.08, 3.01, 1.95, 0.25, 0.12, 0.02, 0.15, 0.06, 0, -0.3, -0.12, 0)),
        ("Indoor", envSH(3.72, 3.37, 2.84, 0.3, 0.25, 0.15)),
        ("Shade", envSH(3.12, 3.3, 3.72, 0.1, 0.15, 0.3)),
        ("Night", envSH(2.48, 2.66, 3.01, 0.08, 0.1, 0.15)),
    ]

    /// Mirrors the SDK's `envSH(...)`: up to 12 radiance coefficients [DC, Y, Z, X] (RGB each),
    /// zero-padded, laid out as `[DC.rgb, envScale, Y.rgb, 0, Z.rgb, 0, X.rgb, 0]`. The `envScale` in
    /// `w[0]` is what actually enables the effect.
    private static func envSH(_ values: Float...) -> [Float] {
        var c = values
        while c.count < 12 { c.append(0) }
        var out = [Float]()
        for k in 0..<4 {
            out.append(c[k * 3]); out.append(c[k * 3 + 1]); out.append(c[k * 3 + 2])
            out.append(k == 0 ? envScale : 0)
        }
        return out
    }

    /// Force a fixed preset, bypassing the probe.
    func applyPreset(_ sh: [Float]) {
        forcedPreset = sh
        environmentLightingEnabled = true
    }

    /// Follow the live environment probe.
    func useProbe() {
        forcedPreset = nil
        environmentLightingEnabled = true
    }

    /// Turn env lighting off.
    func disableEnvironment() {
        forcedPreset = nil
        environmentLightingEnabled = false
    }

    deinit {
        // Drain before release, as everywhere in this SDK.
        context.waitUntilIdle()
        inFlight = []
    }

    // MARK: - Scene

    func load(url: URL) throws {
        let scene = try Scene(url: url, context: context)
        try swapContent {
            self.scene = scene
            try rebuildRenderer()
        }
        playhead = 0
        appliedSettle = scene.isSettled
        if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
    }

    private func rebuildRenderer() throws {
        guard let scene else { renderer = nil; return }
        renderer = nil
        let r = try SplatsRenderer(context: context, maxSplatsCount: max(scene.splatsBudget, 1))
        r.setFlag("splats_count_readback", true)
        renderer = r
    }

    private func swapContent(_ body: () throws -> Void) throws {
        for _ in 0..<Self.maxFramesInFlight { frameBudget.wait() }
        defer { for _ in 0..<Self.maxFramesInFlight { frameBudget.signal() } }
        context.waitUntilIdle()
        inFlight = [[Frame]](repeating: [], count: Self.maxFramesInFlight)
        frameIndex = 0
        try body()
    }

    // MARK: - Placement

    /// Anchors the scene at a world-space point (e.g. a raycast hit), upright and world-aligned, and
    /// resets the user's scale/rotation.
    func place(at position: SIMD3<Float>) {
        anchor = position
        userYaw = 0
        userScale = 1
    }

    /// Fallback placement: one metre straight ahead of the camera, when a raycast finds no surface.
    func place(using frame: ARFrame, distance: Float = 1.0) {
        let t = frame.camera.transform
        let eye = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // The camera looks down its own -Z.
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        place(at: eye + normalized(forward, fallback: SIMD3(0, 0, -1)) * distance)
    }

    func addYaw(_ radians: Float) { userYaw += radians }
    func multiplyScale(_ factor: Float) { userScale = min(max(userScale * factor, 0.05), 20) }
    func togglePlayback() { isPlaying.toggle() }

    /// world = anchor + (R·S)·(object − centre): centres the scene box on the anchor, scaled to
    /// `targetRadius`, rotated by the user's yaw about world up.
    private func modelMatrix(anchor: SIMD3<Float>, scene: Scene) -> simd_float4x4 {
        let bb = scene.boundingBox
        let centre = bb.center
        let radius = max(bb.radius, 1e-4)
        let s = (targetRadius / radius) * userScale

        let rot = simd_float3x3(simd_quatf(angle: userYaw, axis: SIMD3(0, 1, 0)))
        let rs = simd_float3x3(rot.columns.0 * s, rot.columns.1 * s, rot.columns.2 * s)
        let translation = anchor - rs * centre
        return simd_float4x4(
            SIMD4(rs.columns.0, 0),
            SIMD4(rs.columns.1, 0),
            SIMD4(rs.columns.2, 0),
            SIMD4(translation, 1))
    }

    // MARK: - Frame

    func render(frame: ARFrame, orientation: UIInterfaceOrientation, viewportSize: CGSize) {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : min(now - lastTime, 0.25)
        lastTime = now

        advancePlayback(dt: dt)
        settleIfNeeded()
        if let scene { applyEnvironmentLighting(to: scene) }
        background.update(frame: frame, orientation: orientation, viewportSize: viewportSize)

        frameBudget.wait()
        var handedOff = false
        defer { if !handedOff { frameBudget.signal() } }

        guard let drawable = layer.nextDrawable(),
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let width = drawable.texture.width
        let height = drawable.texture.height
        ensureDepth(width: width, height: height)

        // 1) Splat compute + draw-call recording, with NO render encoder open (the SDK opens its own
        //    compute encoders).
        var frames: [Frame] = []
        if appliedSettle, let scene, let renderer, let anchor, scene.isSettled {
            scene.setTransform(modelMatrix(anchor: anchor, scene: scene))
            let view = RenderView(
                projection: frame.camera.projectionMatrix(
                    for: orientation, viewportSize: viewportSize, zNear: 0.05, zFar: 1000),
                cameraToWorld: frame.camera.viewMatrix(for: orientation).inverse)
            frames = [
                renderer.render(
                    scenes: [scene], view: view,
                    targetWidth: UInt32(width), targetHeight: UInt32(height),
                    pass: pass, commandBuffer: commandBuffer)
            ]
        }

        // 2) Splats into the drawable, cleared to TRANSPARENT. The SDK's tile resolve *replaces* the
        //    colour attachment (premultiplied RGB, coverage in alpha) rather than blending over it —
        //    so the camera cannot go first, or the splats would erase it and low-coverage pixels
        //    would come out black. Uncovered pixels keep alpha 0, marking where the camera shows.
        let splatDesc = MTLRenderPassDescriptor()
        splatDesc.colorAttachments[0].texture = drawable.texture
        splatDesc.colorAttachments[0].loadAction = .clear
        splatDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        splatDesc.colorAttachments[0].storeAction = .store
        if let renderer, let splatFrame = frames.first {
            splatDesc.depthAttachment.texture = depthTexture
            splatDesc.depthAttachment.loadAction = .clear
            splatDesc.depthAttachment.clearDepth = pass.clearDepth
            splatDesc.depthAttachment.storeAction = .dontCare
            if let encoder = renderer.makeRenderCommandEncoder(
                commandBuffer, descriptor: splatDesc, pass: pass)
            {
                splatFrame.color.mono?.execute(into: encoder)
                encoder.endEncoding()
            }
        } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: splatDesc) {
            // Nothing placed yet — just clear so the camera fills the whole screen below.
            encoder.endEncoding()
        }

        // 3) Camera image composited BEHIND the splats (destination-over blend, keyed on the coverage
        //    the splat pass left in alpha), stored to the drawable.
        let bgDesc = MTLRenderPassDescriptor()
        bgDesc.colorAttachments[0].texture = drawable.texture
        bgDesc.colorAttachments[0].loadAction = .load
        bgDesc.colorAttachments[0].storeAction = .store
        if let bgEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: bgDesc) {
            background.encode(into: bgEncoder, frame: frame)
            bgEncoder.endEncoding()
        }

        let budget = frameBudget
        commandBuffer.addCompletedHandler { _ in budget.signal() }
        handedOff = true
        commandBuffer.present(drawable)
        commandBuffer.commit()

        inFlight[frameIndex % Self.maxFramesInFlight] = frames
        frameIndex &+= 1

        publishStatus()
    }

    /// The SDK's DC basis constant (three.js `SH_C0`). `normalizeEnvSH1` scales the DC so its peak
    /// channel reaches `1 / SH_C0` ≈ 3.545 — a fully-lit white reference.
    private let shC0: Float = 0.28209479177387814
    /// TUNABLE: damps the directional (SH1) terms, matching the SDK's `contrast` (default 0.5). Lower
    /// for flatter lighting, higher toward the room's raw directionality.
    private let environmentContrast: Float = 0.5
    /// Blend weight stored in `envCoeffs[0].w`. The shader's `applyEnvLighting` skips env lighting
    /// entirely when this is 0 (`lerp(1, env, envScale)`), so it MUST be > 0. The SDK's `envSH`
    /// helper defaults it to 1.
    static let envScale: Float = 1.0

    /// Pushes the current environment SH onto the scene — a forced preset if set, else the calibrated
    /// probe SH — or clears it when the feature is off. Cheap enough to do every frame. The SH is
    /// world-space (the shader evaluates it against a world-space view direction), so no rotation.
    private func applyEnvironmentLighting(to scene: Scene) {
        guard environmentLightingEnabled else {
            if envApplied { scene.setEnvironmentSH(nil); envApplied = false }
            return
        }
        if let forcedPreset {
            scene.setEnvironmentSH(forcedPreset)
            envApplied = true
            return
        }
        guard let worldSH else { return }  // still waiting for the first probe
        scene.setEnvironmentSH(packSH(worldSH))
        envApplied = true
    }

    /// Port of the SDK's `normalizeEnvSH1`: scale the DC so its brightest channel hits `1 / SH_C0`,
    /// and carry SH1 along at `contrast`. Peak-normalized, so it's independent of ARKit's absolute
    /// radiance scale.
    private func calibrate(_ sh: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let peak = max(sh[0].x, sh[0].y, sh[0].z, 0.01)
        let s = 1 / (shC0 * peak)
        let d = s * environmentContrast
        return [sh[0] * s, sh[1] * d, sh[2] * d, sh[3] * d]
    }

    /// Four RGB coefficients → the SDK's 16-float layout `[DC.rgb, envScale, Y.rgb, 0, Z.rgb, 0,
    /// X.rgb, 0]`. The `envScale` in `w[0]` is the enable/blend weight — 0 there disables the effect.
    private func packSH(_ coeffs: [SIMD3<Float>]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(16)
        for (k, c) in coeffs.enumerated() {
            out.append(c.x)
            out.append(c.y)
            out.append(c.z)
            out.append(k == 0 ? Self.envScale : 0)
        }
        return out
    }

    private func advancePlayback(dt: CFTimeInterval) {
        guard let scene, scene.isVideo else { return }
        if isPlaying, scene.duration > 0 {
            playhead += dt
            if playhead >= scene.duration { playhead = 0 }
        }
        scene.setTime(playhead)
        _ = scene.pump()
    }

    /// A video's metadata can arrive after opening; rebuild the renderer against the real splat
    /// budget once it settles. Runs before the frame budget is taken (draining needs every permit).
    private func settleIfNeeded() {
        guard let scene, !appliedSettle, scene.isSettled else { return }
        appliedSettle = true
        try? swapContent { try rebuildRenderer() }
        scene.setPlaybackRange(0...scene.duration)
    }

    private func ensureDepth(width: Int, height: Int) {
        if let d = depthTexture, d.width == width, d.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pass.metalDepthPixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        // Transient: written and cleared within the one splat pass, never loaded or stored.
        desc.storageMode = .memoryless
        depthTexture = device.makeTexture(descriptor: desc)
    }

    private func publishStatus() {
        onStatus?(
            ARStatus(
                isPlaced: anchor != nil,
                visibleSplats: renderer?.visibleSplatsCount ?? 0,
                hasVideo: scene?.isVideo ?? false))
    }
}
