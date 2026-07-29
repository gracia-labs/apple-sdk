//
//  A touch-driven MTKView that plays a single Gracia scene on iOS.
//
//  `GraciaView`/`SplatsSceneView` are macOS-only, so this is the iOS counterpart: it drives
//  `GraciaSDK` + `GraciaCamera` directly, exactly the "any platform" path from the README. It keeps
//  the same load-bearing rules as the mac view — three frames in flight, drain-before-swap, late
//  metadata re-framing, on-demand vs continuous pacing — trimmed to a single scene with no split
//  layout or drag-and-drop.
//

import GraciaCamera
import GraciaSDK
import Metal
import MetalKit
import UIKit
import simd

/// What the host needs to draw the HUD and transport. Published once per rendered frame.
struct ViewerStatus {
    var name: String
    var visibleSplats: UInt32
    var splatsBudget: UInt32
    var fps: Double
    var hasVideo: Bool
    var isPlaying: Bool
    var isBuffering: Bool
    var playhead: Double
    var duration: Double
    var gpuBytes: UInt64
}

final class SplatsMetalView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    /// Matches the SDK renderer's ring buffers: a fourth queued frame would overwrite one the GPU is
    /// still reading.
    static let maxFramesInFlight = 3

    /// Colour + reverse-Z depth; `GraciaSDK` owns pipeline, formats and clear value.
    private let pass = SplatsPassDescriptor.viewer

    let context: GraciaContext
    let camera: SceneCamera
    let input: CameraInput
    let queue: any MTLCommandQueue

    private(set) var scene: Scene?
    private var renderer: SplatsRenderer?

    // MARK: Playback

    var isPlaying = true { didSet { requestFrame() } }
    /// Playback rate; 1 is real time. Clamped to a sane range.
    var playbackSpeed: Double = 1 { didSet { playbackSpeed = min(max(playbackSpeed, 0), 8) } }
    private(set) var playhead: Double = 0
    var duration: Double { scene?.duration ?? 0 }
    var hasVideo: Bool { scene?.isVideo ?? false }
    var hasScene: Bool { scene != nil }

    /// Clamped to `0..<duration`. Works while paused.
    func seek(to time: Double) {
        guard let scene, scene.duration > 0 else { return }
        // Range is exclusive and the clock is float32, so back off a millisecond from `duration`.
        let end = max(0, scene.duration - 0.001)
        playhead = min(max(0, time), end)
        isReady = false  // hold drawing until the new frame decodes
        requestFrame()
    }

    // MARK: Callbacks

    var onSceneLoaded: ((URL) -> Void)?
    var onError: ((any Error) -> Void)?
    var onStatus: ((ViewerStatus) -> Void)?

    // MARK: Pacing / lifetime

    private enum RenderMode { case continuous, onDemand }
    private var renderMode: RenderMode = .onDemand {
        didSet { if renderMode != oldValue { applyRenderState() } }
    }
    private var hasContent = false
    private var appActive = true

    private let frameBudget = DispatchSemaphore(value: SplatsMetalView.maxFramesInFlight)
    /// Draw-call handles hold GPU state until their command buffer retires. Slot `frameIndex % 3`
    /// holds frames from three commits ago — complete by the frame budget — so overwriting it frees
    /// them deterministically on the main thread.
    private var inFlight = [[Frame]](repeating: [], count: SplatsMetalView.maxFramesInFlight)
    private var frameIndex = 0

    private var lastTimestamp: CFTimeInterval = 0
    private var frameTime: CFTimeInterval = 0
    /// Low-passed frame interval used to drive camera motion, so display-rate jitter doesn't shake it.
    private var smoothedDt: CFTimeInterval = 1.0 / 60
    private var smoothedFPS: Double = 0

    /// Renderer/camera rebuilt against the scene's real numbers once a stream's metadata lands.
    private var appliedSettle = true
    private var isReady = true
    private var isBuffering = false

    /// A touch gesture is in progress. Kept continuous while true (and while inertia settles), so
    /// interaction renders like the AR loop instead of jittery per-frame `setNeedsDisplay`.
    private var interacting = false
    /// The camera animated on the last frame (a gesture or its inertia tail).
    private var cameraMoving = false

    private var lastPinchScale: Float = 1
    /// Touch count of the drag gesture; when it changes we re-anchor so the centroid doesn't jump.
    private var dragTouchCount = 0
    /// Camera gestures currently active — the drag and the pinch can overlap, so count them.
    private var activeGestures = 0
    /// True while another Metal surface (AR) owns the screen — the view stops drawing entirely.
    private var suspended = false

    // MARK: Init

    init(device: any MTLDevice, cacheDirectory: URL? = nil) throws {
        // Context must share this view's queue: `waitUntilIdle()` drains the queue we render on.
        guard let queue = device.makeCommandQueue() else { throw GraciaError.contextCreationFailed }
        self.queue = queue
        context = try GraciaContext(device: device, commandQueue: queue, cacheDirectory: cacheDirectory)
        camera = SceneCamera()
        input = CameraInput(sceneCamera: camera)
        super.init(frame: .zero, device: device)

        delegate = self
        colorPixelFormat = pass.metalColorPixelFormat
        depthStencilPixelFormat = pass.metalDepthPixelFormat
        sampleCount = Int(pass.sampleCount)
        // Splats blend premultiplied, so the background is ours to choose.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        clearDepth = pass.clearDepth
        // Projection Z direction must match the pass's depth compare op.
        camera.reverseZ = pass.usesReverseZ

        isPaused = true
        enableSetNeedsDisplay = true
        isOpaque = true

        addGestures()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unavailable") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Drain before release: freeing scenes/renderers with frames still on the GPU is a
        // use-after-free (see AGENTS.md, "Lifetime rules").
        context.waitUntilIdle()
        inFlight = []
    }

    // MARK: - Scene

    /// Loads a scene, replacing whatever is showing. A bad file is built before teardown, so it
    /// leaves the current scene alone.
    func load(url: URL) throws {
        let scene = try Scene(url: url, context: context)
        try swapContent {
            self.scene = scene
            try rebuildRenderer()
        }

        playhead = 0
        isBuffering = false
        isReady = !scene.isVideo
        appliedSettle = scene.isSettled
        if scene.duration > 0 { scene.setPlaybackRange(0...scene.duration) }
        camera.aspect = aspect
        // Unsettled streams have no box, so nothing frames or draws until `settleIfNeeded`.
        reframe()
        contentDidChange()
        onSceneLoaded?(url)
    }

    /// Re-derives the world bounds from the scene box and frames the camera on them.
    private func reframe() {
        guard let scene else { return }
        let full = scene.boundingBox
        guard full.isValid else {
            // Unsettled: hand the camera the empty box so it un-frames until it settles.
            camera.setBBox(full)
            return
        }
        let subject = scene.adaptiveBBox.isValid ? scene.adaptiveBBox : full
        camera.setBBox(full, adaptive: subject, reposition: true)
    }

    func resetFraming() {
        camera.reset()
        requestFrame()
    }

    /// Renderer sized to the scene it draws. Only ever called from `swapContent`.
    private func rebuildRenderer() throws {
        guard let scene else { renderer = nil; return }
        // Free the old one first: holding both costs ~1 GB on a large scene.
        renderer = nil
        let r = try SplatsRenderer(context: context, maxSplatsCount: max(scene.splatsBudget, 1))
        // Without this the visible-splat counter always reads back 0.
        r.setFlag("splats_count_readback", true)
        renderer = r
    }

    /// Swaps scene/renderer with nothing of ours running on the GPU. Order is load-bearing: drain
    /// frames, `waitUntilIdle()`, release draw-call handles, then `body` (see AGENTS.md).
    private func swapContent(_ body: () throws -> Void) throws {
        try withDrainedFrames {
            context.waitUntilIdle()
            inFlight = [[Frame]](repeating: [], count: Self.maxFramesInFlight)
            frameIndex = 0
            try body()
        }
    }

    /// Runs `body` with no frames in flight. Blocks the main thread for up to a frame; call when
    /// swapping content, never per frame.
    private func withDrainedFrames<T>(_ body: () throws -> T) rethrows -> T {
        for _ in 0..<Self.maxFramesInFlight { frameBudget.wait() }
        defer { for _ in 0..<Self.maxFramesInFlight { frameBudget.signal() } }
        return try body()
    }

    // MARK: - Frame loop

    /// `drawableSize` is reported only once the view has a layer; `bounds` covers that gap.
    private var aspect: Float {
        let size = drawableSize.height > 0 ? drawableSize : bounds.size
        return size.height > 0 ? Float(size.width / size.height) : 1
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.aspect = size.height > 0 ? Float(size.width / size.height) : 1
        input.viewHeightChanged(Float(bounds.height))
    }

    func draw(in view: MTKView) {
        // Metal drawables are autoreleased; without a pool they pile up for a run-loop turn.
        autoreleasepool { drawFrame() }
    }

    private func drawFrame() {
        let now = CACurrentMediaTime()
        let nominal = preferredFramesPerSecond > 0 ? 1.0 / Double(preferredFramesPerSecond) : 1.0 / 60
        if lastTimestamp == 0 {
            // First frame, or the first after an idle gap — start from the display's nominal interval
            // rather than a stale multi-second delta that would lurch the camera on the first move.
            smoothedDt = nominal
        } else {
            let raw = min(now - lastTimestamp, 0.25)
            // Low-pass the interval so display-rate jitter — and the 120↔60 beating when the GPU
            // can't always hold 8.3 ms — doesn't turn into shaky per-frame camera motion.
            smoothedDt += (raw - smoothedDt) * 0.2
        }
        lastTimestamp = now
        frameTime = smoothedDt

        // Draining wants every permit; below the wait we hold one, so settle first.
        settleIfNeeded()

        frameBudget.wait()
        var handedOff = false
        defer { if !handedOff { frameBudget.signal() } }

        guard let drawable = currentDrawable,
            let descriptor = currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        let present = render(target: drawable.texture, descriptor: descriptor, commandBuffer: commandBuffer)

        let budget = frameBudget
        commandBuffer.addCompletedHandler { _ in budget.signal() }
        handedOff = true

        if present {
            // A minimum on-screen duration gives ProMotion a steady cadence to lock onto instead of
            // beating between refresh rates.
            commandBuffer.present(drawable, afterMinimumDuration: nominal)
        }
        commandBuffer.commit()
    }

    /// Forget the last frame time so the next frame uses the display's nominal interval, not a stale
    /// gap. Called when a gesture starts, so the first move after an idle scene doesn't lurch.
    private func resetFrameClock() { lastTimestamp = 0 }

    private func render(
        target: any MTLTexture, descriptor: MTLRenderPassDescriptor, commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let dt = frameTime
        if dt > 0 { smoothedFPS += (1 / dt - smoothedFPS) * 0.1 }

        // Settle pacing before asking the camera for its next frame, so a video that pauses/stops
        // buffering doesn't strand the camera mid-gesture with nothing scheduled to drain inertia.
        advancePlayback(dt: dt)

        // Inertia keeps the camera moving after the gesture ends, so stay continuous until it settles.
        cameraMoving = camera.update(dt: Float(dt))
        updateRenderMode()
        if cameraMoving { requestFrame() }

        let size = CGSize(width: target.width, height: target.height)
        let frame = encodeScene(commandBuffer: commandBuffer, size: size)
        isBuffering = !isReady || (frame?.buffering ?? false)

        guard let encoder = makeEncoder(commandBuffer, descriptor: descriptor) else { return false }
        frame?.color.mono?.execute(into: encoder)
        encoder.endEncoding()

        retire(frame.map { [$0] } ?? [])
        publishStatus()
        // Re-settle pacing now that this frame's `isBuffering` is current.
        updateRenderMode()
        return true
    }

    /// Every `render(...)` opens its own compute encoders on the command buffer, so it must run
    /// before any render encoder exists.
    private func encodeScene(commandBuffer: any MTLCommandBuffer, size: CGSize) -> Frame? {
        guard let scene, let renderer, camera.isFramed else { return nil }
        let view3D = camera.renderView(aspect: aspect, viewHeightPoints: Float(bounds.height))
        return renderer.render(
            scenes: [scene], view: view3D,
            targetWidth: UInt32(size.width), targetHeight: UInt32(size.height),
            pass: pass, commandBuffer: commandBuffer)
    }

    /// The SDK configures the render pass for the pipeline it picked. With no renderer yet the
    /// drawable is simply cleared.
    private func makeEncoder(
        _ commandBuffer: any MTLCommandBuffer, descriptor: MTLRenderPassDescriptor
    ) -> (any MTLRenderCommandEncoder)? {
        guard let renderer else {
            return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        }
        return renderer.makeRenderCommandEncoder(commandBuffer, descriptor: descriptor, pass: pass)
    }

    /// Continuous while a video needs a clock, or the camera is being driven (gesture + inertia);
    /// else on-demand, so a still scene sits idle. Continuous interaction paces far more smoothly
    /// than per-frame `setNeedsDisplay`, which is what made the view shaky when the rate dipped.
    private func updateRenderMode() {
        let videoNeedsFrames =
            (scene?.isVideo == true) && (isPlaying || !isReady || isBuffering || !appliedSettle)
        renderMode = (videoNeedsFrames || interacting || cameraMoving) ? .continuous : .onDemand
    }

    /// Gated on `isVideo`, not duration: a stream must be pumped to learn its duration.
    private func advancePlayback(dt: CFTimeInterval) {
        guard let scene, scene.isVideo else { return }
        // Stall the clock while buffering so playback doesn't skip ahead.
        if isPlaying, !isBuffering, isReady, scene.duration > 0 {
            playhead += dt * playbackSpeed
            if playhead >= scene.duration { playhead = 0 }
        }
        scene.setTime(playhead)
        isReady = scene.pump()
    }

    /// A stream's metadata lands late; renderer and camera were built against placeholders, so
    /// rebuild both here, before the budget is taken (draining is illegal once we hold a permit).
    private func settleIfNeeded() {
        guard let scene, !appliedSettle, scene.isSettled else { return }
        appliedSettle = true
        do {
            try swapContent { try rebuildRenderer() }
        } catch {
            onError?(error)
            return
        }
        scene.setPlaybackRange(0...scene.duration)
        reframe()
        contentDidChange()
    }

    private func retire(_ frames: [Frame]) {
        inFlight[frameIndex % Self.maxFramesInFlight] = frames
        frameIndex &+= 1
    }

    private func publishStatus() {
        guard let onStatus, let scene else { return }
        onStatus(
            ViewerStatus(
                name: scene.name,
                visibleSplats: renderer?.visibleSplatsCount ?? 0,
                splatsBudget: scene.splatsBudget,
                fps: smoothedFPS,
                hasVideo: scene.isVideo,
                isPlaying: isPlaying,
                isBuffering: isBuffering,
                playhead: playhead,
                duration: scene.duration,
                gpuBytes: context.gpuAllocatedBytes))
    }

    // MARK: - Pacing state

    private func contentDidChange() {
        hasContent = true
        applyRenderState()
    }

    /// Schedules one frame. No-op while suspended, in `.continuous` mode, and before there is content.
    func requestFrame() {
        guard !suspended, renderMode == .onDemand, hasContent else { return }
        setNeedsDisplay()
    }

    private func applyRenderState() {
        // While the AR view owns the screen, draw nothing at all.
        guard !suspended else {
            isPaused = true
            enableSetNeedsDisplay = false
            return
        }
        switch renderMode {
        case .continuous:
            let run = hasContent && appActive
            isPaused = !run
            enableSetNeedsDisplay = !run
        case .onDemand:
            isPaused = true
            enableSetNeedsDisplay = true
            if hasContent { setNeedsDisplay() }
        }
    }

    @objc private func appDidBecomeActive() {
        appActive = true
        applyRenderState()
    }

    @objc private func appWillResignActive() {
        appActive = false
        applyRenderState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Follow the display: 120 Hz on ProMotion, 60 otherwise. Needs
        // CADisableMinimumFrameDurationOnPhone in Info.plist to exceed 60.
        if let fps = window?.windowScene?.screen.maximumFramesPerSecond, fps > 0 {
            preferredFramesPerSecond = fps
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        input.viewHeightChanged(Float(bounds.height))
    }

    // MARK: - Touch input

    private func addGestures() {
        // One drag recognizer for both orbit (1 finger) and pan (2 fingers). Keeping it a single
        // recognizer — rather than one per finger count — is what lets us ride through the 1↔2
        // transition smoothly instead of handing off between recognizers as fingers lift.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 2
        drag.delegate = self
        addGestureRecognizer(drag)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    /// UIKit's coordinates already grow downward, which is exactly what `CameraInput` wants.
    private func point(_ g: UIGestureRecognizer) -> SIMD2<Float> {
        let p = g.location(in: self)
        return SIMD2(Float(p.x), Float(p.y))
    }

    /// A gesture began: render continuously (smooth) while any gesture is live, and reset the frame
    /// clock so the first move after an idle scene doesn't lurch on a stale dt.
    private func beginInteraction() {
        activeGestures += 1
        guard activeGestures == 1 else { return }
        interacting = true
        resetFrameClock()
        updateRenderMode()
    }

    /// A gesture ended: once every gesture is done, let the loop fall back to on-demand as the camera
    /// settles.
    private func endInteraction() {
        activeGestures = max(0, activeGestures - 1)
        guard activeGestures == 0 else { return }
        interacting = false
        requestFrame()
    }

    /// One recognizer for orbit (1 finger) and pan (2 fingers). When the touch count changes we
    /// re-anchor with no delta, so lifting a finger while keeping the other doesn't jump the picture.
    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            beginInteraction()
            dragTouchCount = g.numberOfTouches
            input.pointerDown(at: point(g), button: g.numberOfTouches >= 2 ? .secondary : .primary)
        case .changed:
            let touches = g.numberOfTouches
            if touches != dragTouchCount {
                // Finger added or lifted: the centroid jumps between fingers. Re-anchor here — no
                // delta this frame — and switch orbit⇄pan by the new count.
                dragTouchCount = touches
                input.pointerUp()
                input.pointerDown(at: point(g), button: touches >= 2 ? .secondary : .primary)
            } else {
                input.pointerDragged(to: point(g))
            }
        case .ended, .cancelled, .failed:
            input.pointerUp()
            dragTouchCount = 0
            endInteraction()
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            beginInteraction()
            lastPinchScale = 1
        case .changed:
            let s = Float(g.scale)
            // Relative delta (scale factor − 1); pinch scale is cumulative. Clamp per event so a
            // finger lifting off — which briefly warps the finger distance — can't spike the zoom.
            let rel = s / lastPinchScale - 1
            lastPinchScale = s
            input.magnify(max(-0.4, min(0.4, rel)))
        case .ended, .cancelled, .failed:
            endInteraction()
        default: break
        }
    }

    @objc private func handleDoubleTap() {
        resetFraming()
    }

    // Let the drag (orbit/pan) and the pinch (zoom) run together for combined two-finger control.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: - Suspend

    /// Stops all rendering — call when another Metal surface (the AR view) takes over the screen, so
    /// the two aren't drawing at once.
    func suspend() {
        suspended = true
        applyRenderState()
    }

    /// Resumes rendering after ``suspend()``.
    func resume() {
        suspended = false
        resetFrameClock()
        applyRenderState()
    }
}
