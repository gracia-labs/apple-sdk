//
//  The immersive stereo player: a Compositor Services render loop that draws a Gracia scene into the
//  Vision Pro display, one eye per texture-array slice, driven by the head pose from ARKit.
//
//  This is the visionOS counterpart to the iOS `SplatsMetalView`. Where iOS builds one `RenderView`
//  from a touch camera, here the two `RenderView`s (left/right eye) come straight from the drawable:
//  per-eye projection from `computeProjection`, per-eye camera-to-world from the device anchor times
//  the eye transform. The SDK's `vr: true` renderer and `StereoMode.multipass` do the rest.
//
//  Threading: Compositor Services calls the `CompositorLayer` render closure on the main actor, so
//  `start()` immediately hands off to a dedicated thread. Everything below runs there; it talks to
//  the UI only through the lock-guarded ``RenderLink``.
//
//  Lifetime rules (see AGENTS.md): draw-call `Frame`s hold GPU state until their command buffer
//  retires, so each frame's `Frame`s are captured in the command buffer's completion handler, and
//  the context is drained (`waitUntilIdle`) before a scene or renderer is torn down.
//

import ARKit
import CompositorServices
import GraciaSDK
import Metal
import QuartzCore
import simd

final class ImmersiveRenderer {
    private let layerRenderer: LayerRenderer
    private let link: RenderLink

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    /// Nil only if the GPU context can't be created (e.g. a GPU debugger is attached); the loop then
    /// just clears the display and reports the error.
    private let context: GraciaContext?

    /// Matched to the layer's colour/depth formats in ``makePass()``. Reverse-Z to match the
    /// drawable's reverse-Z depth range; multipass so we get one draw-call set per eye.
    private let pass: SplatsPassDescriptor

    /// Bounds Gracia frames in flight to its internal 3-frame ring (as the production renderer does):
    /// a fourth queued frame would overwrite ring buffers the GPU is still reading.
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    /// Called on the render thread when the loop exits (the space closed) so the window can resync.
    private let onExit: (@Sendable () -> Void)?

    // MARK: Scene / renderer (render-thread owned)

    private var scenes: [Scene] = []
    private var renderer: SplatsRenderer?
    /// The generation currently loaded, so we reload only when the window picks a different file.
    private var loadedGeneration = -1
    private var statusError: String?

    // MARK: Playback

    private var playhead: Double = 0
    private var isReady = true
    /// False until a video stream's real metadata (budget, bounds, duration) has landed and the
    /// renderer has been rebuilt to its real size.
    private var appliedSettle = true

    // MARK: Placement / gestures

    /// Drives the scene's model matrix from hand pinches. The App feeds it `layerRenderer.onSpatialEvent`.
    let gestureController = SpatialGestureController()
    /// Set on load and on Recenter; re-drops the scene in front of the head once its bounds are valid.
    private var needsPlacement = false

    // MARK: Frame clock

    private var lastTime: CFTimeInterval = 0
    private var smoothedDt: CFTimeInterval = 1.0 / 90
    private var smoothedFPS: Double = 0

    // MARK: ARKit

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    init(layerRenderer: LayerRenderer, link: RenderLink, onExit: (@Sendable () -> Void)? = nil) {
        self.layerRenderer = layerRenderer
        self.link = link
        self.onExit = onExit

        // Render on the same device the drawable textures are created on.
        let device = layerRenderer.device
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.context = try? GraciaContext(device: device, commandQueue: queue)

        self.pass = ImmersiveRenderer.makePass(for: layerRenderer)
    }

    /// The Gracia pass, built to match the layer's actual colour/depth formats. Kept in lock-step
    /// with ``GraciaLayerConfiguration`` so the pipeline and the drawable textures agree.
    private static func makePass(for layerRenderer: LayerRenderer) -> SplatsPassDescriptor {
        let cfg = layerRenderer.configuration
        let color: ColorFormat = {
            switch cfg.colorFormat {
            case .rgba16Float: .rgba16Float
            case .rgba8Unorm: .rgba8Unorm
            case .rgba8Unorm_srgb: .rgba8Srgb
            case .rgba32Float: .rgba32Float
            default: .rgba16Float
            }
        }()
        let depth: DepthFormat = {
            switch cfg.depthFormat {
            case .depth32Float: .d32Float
            case .depth16Unorm: .d16Unorm
            case .depth32Float_stencil8: .d32FloatS8Uint
            default: .d32Float
            }
        }()
        return SplatsPassDescriptor(
            colorFormat: color,
            depth: .splats(format: depth, reverseZ: true),
            sampleCount: 1,
            stereo: .multiview,
            depthStereo: .multiview)
    }

    // MARK: - Thread

    /// Hands the render loop to a dedicated thread and returns. Called from the main-actor render
    /// closure, so it must not block.
    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "com.gracia.immersive-render"
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func run() {
        startTracking()
        loop: while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            case .invalidated:
                break loop
            @unknown default:
                break loop
            }
        }
        teardown()
        // Signal the window that the space closed (covers a system-initiated close via the Digital
        // Crown, which no window scenePhase reliably reports).
        onExit?()
    }

    private func startTracking() {
        guard WorldTrackingProvider.isSupported else { return }
        let session = arSession
        let provider = worldTracking
        // Device/head pose needs no authorization; just run the provider while the space is open.
        Task { try? await session.run([provider]) }
    }

    private func teardown() {
        context?.waitUntilIdle()
        scenes = []
        renderer = nil
        let session = arSession
        Task { session.stop() }
    }

    // MARK: - Frame

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        // Frame-independent CPU work: react to the window's controls, load/settle the scene, advance
        // the video clock. None of this needs the drawable.
        frame.startUpdate()
        let inputs = link.takeInputs()
        loadSceneIfNeeded(inputs)
        let dt = tickClock()
        advancePlayback(inputs: inputs, dt: dt)
        settleIfNeeded()
        frame.endUpdate()

        // Block until the ideal moment to sample input and start GPU work for this frame.
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        frame.startSubmission()

        // Usually one drawable (the headset); a second (`.capture`) appears during high-quality
        // recording. An empty array means the system chose not to render this frame (device off the
        // head, space tearing down): return *without* ending submission — calling endSubmission() on a
        // drawable-less frame trips "cp_frame_end_submission() failed because the frame is not valid".
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        // Past here the frame is valid and every drawable is presented below, so submission must end.
        defer { frame.endSubmission() }

        // One head pose per frame, at the primary drawable's on-screen time; reused for placement and
        // every eye. Setting it on each drawable lets Compositor Services reproject at scan-out.
        let deviceAnchor = worldTracking.queryDeviceAnchor(
            atTimestamp: drawables[0].frameTiming.presentationTime.timeInterval)
        placeScene(inputs: inputs, anchor: deviceAnchor)

        // Gate on Gracia's 3-frame ring. If the GPU is backed up, present without rendering rather
        // than blocking the compositor (matching the production renderer).
        let canRender = inFlightSemaphore.wait(timeout: .now() + .milliseconds(200)) == .success

        guard let commandBuffer = queue.makeCommandBuffer() else {
            if canRender { inFlightSemaphore.signal() }
            return
        }

        if canRender {
            var heldFrames: [GraciaSDK.Frame] = []
            for drawable in drawables {
                if let held = encode(
                    drawable, inputs: inputs, anchor: deviceAnchor, commandBuffer: commandBuffer)
                {
                    heldFrames.append(held)
                }
            }
            for drawable in drawables { drawable.encodePresent(commandBuffer: commandBuffer) }
            // Free the draw-call handles and release the ring slot once the GPU has finished.
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler { _ in
                _ = heldFrames
                semaphore.signal()
            }
        } else {
            // GPU backlog: keep the display cadence by presenting the (undrawn) drawables.
            for drawable in drawables { drawable.encodePresent(commandBuffer: commandBuffer) }
        }
        commandBuffer.commit()

        publishStatus()
    }

    /// Re-drops the scene in front of the head (on load / Recenter), applies this frame's hand
    /// gestures, and pushes the resulting model matrix to every scene.
    private func placeScene(inputs: RenderLink.Inputs, anchor deviceAnchor: DeviceAnchor?) {
        if inputs.recenter { needsPlacement = true; link.consumeRecenter() }

        if needsPlacement, let scene = scenes.first {
            let box = scene.adaptiveBBox.isValid ? scene.adaptiveBBox : scene.boundingBox
            // Wait for a real box — a video settles its bounds a few frames in.
            if box.isValid {
                let head = deviceAnchor?.isTracked == true ? deviceAnchor?.originFromAnchorTransform : nil
                gestureController.resetToMatrix(GesturePlacement.initial(box: box, head: head))
                needsPlacement = false
            }
        }

        // Apply this frame's pinch gestures, then hand the model matrix to the scene(s).
        gestureController.update()
        guard !scenes.isEmpty else { return }
        let model = gestureController.modelMatrix
        for scene in scenes { scene.setTransform(model) }
    }

    /// Encodes both eyes of one drawable. Returns the Gracia `Frame` whose draw-call handles must
    /// outlive the command buffer, or nil if nothing was drawn.
    private func encode(
        _ drawable: LayerRenderer.Drawable, inputs: RenderLink.Inputs,
        anchor: DeviceAnchor?, commandBuffer: any MTLCommandBuffer
    ) -> GraciaSDK.Frame? {
        // The frame's head pose (queried once in renderFrame). Setting it lets Compositor Services
        // reproject at scan-out.
        drawable.deviceAnchor = anchor
        let worldFromDevice = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // One RenderView per eye, straight from the drawable. `.rightUpBack` is exactly Gracia's
        // camera convention, so the projection needs no handedness or Y flip; the SDK inverts
        // cameraToWorld to the view matrix itself.
        let views: [RenderView] = drawable.views.indices.map { i in
            let projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
            let cameraToWorld = worldFromDevice * drawable.views[i].transform
            return RenderView(projection: projection, cameraToWorld: cameraToWorld)
        }

        // Both eyes are the same size; view 0 drives the render() target dimensions. Under foveation
        // this is the physical (reduced) per-eye viewport — the actual texture area rendered.
        let viewport = drawable.views[0].textureMap.viewport
        let width = UInt32(max(viewport.width, 1))
        let height = UInt32(max(viewport.height, 1))

        // Multiview stereo: one sort/preprocess for both eyes, then a single vertex-amplified draw into
        // the two-slice layered texture — the eyes never share a mid-frame buffer state. Opens its own
        // compute encoders, so no render encoder may be open yet. Gated on `appliedSettle` (like the
        // iOS renderers): until a video settles the renderer is placeholder-sized, so `held` stays nil
        // and we just clear (the buffering state).
        var held: GraciaSDK.Frame?
        if appliedSettle, let renderer, !scenes.isEmpty {
            held = renderer.render(
                scenes: scenes, views: views, targetWidth: width, targetHeight: height,
                pass: pass, commandBuffer: commandBuffer)
        }

        // A single render pass into the whole layered (2-slice) texture; vertex amplification routes
        // each eye to its own slice. Alpha 0 clears to passthrough (mixed); alpha 1 to opaque black (full).
        let clearAlpha = inputs.immersion.isPassthrough ? 0.0 : 1.0
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.colorTextures[0]
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clearAlpha)
        descriptor.depthAttachment.texture = drawable.depthTextures[0]
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .store
        descriptor.depthAttachment.clearDepth = pass.clearDepth  // 0 for reverse-Z
        // Render to every layer of the array texture (one per eye).
        descriptor.renderTargetArrayLength = drawable.views.count
        // Foveation: one rate map for the whole layered pass; the compositor un-warps at scan-out.
        if let rateMap = drawable.rasterizationRateMaps.first {
            descriptor.rasterizationRateMap = rateMap
        }

        // With a renderer, this applies the depth-tile imageblock geometry the splat path needs;
        // without one (buffering) we just clear the slices.
        let encoder: (any MTLRenderCommandEncoder)?
        if let renderer {
            encoder = renderer.makeRenderCommandEncoder(commandBuffer, descriptor: descriptor, pass: pass)
        } else {
            encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        }
        guard let encoder else { return held }

        // Multiview emits ONE vertex-amplified draw for both eyes. The SDK's shader amplifies each
        // vertex to two views (ampId 0/1), indexes the per-eye matrices by ampId, and relies on the
        // view mapping to route each view to its slice. The SDK does NOT set the encoder-side
        // amplification (its render backend does — see deps/fuji/.../metal/RenderPass.cpp), so we must:
        // two viewports (amp 1 uses viewport index 1) and mappings sending amp 1 to slice 1. Without
        // this, ampId stays 0 and only the left slice is drawn — the right eye is empty.
        if let calls = held?.color.mono {
            encoder.setViewports([viewport, viewport])
            let mappings = [
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1),
            ]
            encoder.setVertexAmplificationCount(2, viewMappings: mappings)
            calls.execute(into: encoder)
        }
        encoder.endEncoding()
        return held
    }

    // MARK: - Scene lifecycle

    private func loadSceneIfNeeded(_ inputs: RenderLink.Inputs) {
        guard inputs.sceneGeneration != loadedGeneration else { return }
        loadedGeneration = inputs.sceneGeneration

        // Drain before swapping content: freeing a scene/renderer with frames still on the GPU is a
        // use-after-free.
        context?.waitUntilIdle()
        scenes = []
        renderer = nil
        playhead = 0
        isReady = true
        appliedSettle = true
        statusError = nil

        guard let context, let url = inputs.sceneURL else { return }
        do {
            let scene = try Scene(url: url, context: context)
            scenes = [scene]
            needsPlacement = true  // drop it in front of the head on the next valid-bounds frame
            isReady = !scene.isVideo
            appliedSettle = scene.isSettled
            if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
            try rebuildRenderer()
        } catch {
            scenes = []
            renderer = nil
            statusError = "\(error)"
        }
    }

    /// A fresh `vr: true` renderer sized to the current scene. Frees the old one first.
    private func rebuildRenderer() throws {
        guard let context, let scene = scenes.first else { renderer = nil; return }
        renderer = nil
        let r = try SplatsRenderer(context: context, maxSplatsCount: max(scene.splatsBudget, 1), vr: true)
        // Without this the visible-splat counter always reads back 0.
        r.setFlag("splats_count_readback", true)
        renderer = r
    }

    /// A video stream's real numbers land a few frames in; the renderer was sized to placeholders,
    /// so rebuild it once they settle.
    private func settleIfNeeded() {
        guard let scene = scenes.first, !appliedSettle, scene.isSettled else { return }
        appliedSettle = true
        context?.waitUntilIdle()
        do {
            try rebuildRenderer()
        } catch {
            statusError = "\(error)"
            return
        }
        if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
    }

    private func advancePlayback(inputs: RenderLink.Inputs, dt: Double) {
        guard let scene = scenes.first, scene.isVideo else { return }
        if let seek = inputs.seek {
            let end = max(0, scene.duration - 0.001)
            playhead = min(max(0, seek), end)
            isReady = false
        }
        // Stall the clock while a frame is still decoding so playback doesn't skip ahead.
        if inputs.isPlaying, isReady, scene.duration > 0 {
            playhead += dt * inputs.playbackSpeed
            if playhead >= scene.duration { playhead = 0 }
        }
        scene.setTime(playhead)
        isReady = scene.pump()
    }

    // MARK: - Clock / status

    /// Low-passed frame interval, also feeding the FPS readout.
    private func tickClock() -> Double {
        let now = CACurrentMediaTime()
        if lastTime == 0 {
            smoothedDt = 1.0 / 90
        } else {
            let raw = min(now - lastTime, 0.25)
            smoothedDt += (raw - smoothedDt) * 0.2
        }
        lastTime = now
        if smoothedDt > 0 { smoothedFPS += (1 / smoothedDt - smoothedFPS) * 0.1 }
        return smoothedDt
    }

    private func publishStatus() {
        var status = ImmersiveStatus()
        if let scene = scenes.first {
            status.sceneName = scene.name
            status.loaded = true
            status.isVideo = scene.isVideo
            status.splatsBudget = scene.splatsBudget
            status.visibleSplats = renderer?.visibleSplatsCount ?? 0
            status.duration = scene.duration
            status.playhead = playhead
            status.buffering = scene.isVideo && !isReady
        }
        status.fps = smoothedFPS
        status.gpuBytes = context?.gpuAllocatedBytes ?? 0
        status.errorMessage = statusError
        link.publish(status)
    }
}

extension LayerRenderer.Clock.Instant {
    /// Absolute seconds in the `CACurrentMediaTime()` domain — the timestamp `queryDeviceAnchor`
    /// wants. Compositor Services exposes the clock as a `Duration` from the epoch; there's no
    /// built-in seconds accessor, so derive it from the components.
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
