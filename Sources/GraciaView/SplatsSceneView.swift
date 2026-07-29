#if os(macOS)

//
//  Drop-in NSView that plays Gracia scenes. Host drives it via `camera`, `load(urls:layout:)`,
//  and callbacks.
//

import AppKit
import GraciaCamera
import GraciaSDK
import MetalKit
import simd

/// How several scenes share the viewport.
public enum SceneLayout: String, Sendable, CaseIterable {
    /// One renderer, all scenes composited into one image.
    case mix
    /// One renderer per scene, drawn into scissored columns — an A/B wipe sharing one camera.
    case split
}

/// What the host needs to draw a HUD. Published once per rendered frame.
public struct SceneStatus: Sendable {
    public var sceneNames: [String]
    public var layout: SceneLayout
    public var visibleSplats: UInt32
    /// Per scene, in `.split` (one renderer each); a single total in `.mix`.
    public var visibleSplatsPerScene: [UInt32]
    public var splatsBudget: UInt32
    public var fps: Double
    public var hasVideo: Bool
    public var isPlaying: Bool
    public var isBuffering: Bool
    public var playhead: Double
    public var duration: Double
    public var gpuBytes: UInt64
}

public final class SplatsSceneView: GraciaMetalView {
    /// Colour + depth; no motion or mesh pass. `GraciaSDK` owns pipeline, formats and clear value.
    private let pass = SplatsPassDescriptor.viewer

    public let context: GraciaContext
    public let camera: SceneCamera
    public let input: CameraInput

    public private(set) var group: SceneGroup?
    public private(set) var sceneLayout: SceneLayout = .mix

    /// Layout for files dropped on the view (default `.split`); a single file is always `.mix`.
    public var droppedFilesLayout: SceneLayout = .split
    public var acceptsDroppedFiles = true {
        didSet { registerForDraggedTypes(acceptsDroppedFiles ? [.fileURL] : []) }
    }

    public var isPlaying = true { didSet { requestFrame() } }

    /// Playback rate; 1 is real time. Clamped to a sane range.
    public var playbackSpeed: Double = 1 {
        didSet { playbackSpeed = min(max(playbackSpeed, 0), 8) }
    }

    public private(set) var playhead: Double = 0

    /// Seconds. With several scenes, the shortest — see README.
    public var duration: Double { group?.duration ?? 0 }

    public var hasVideo: Bool { group?.hasVideo ?? false }

    /// Clamped to `0..<duration`. Works while paused.
    public func seek(to time: Double) {
        guard let group, group.duration > 0 else { return }
        // Range is exclusive and the clock is float32, so back off a millisecond from `duration`
        // to stay before the last frame.
        let end = Swift.max(0, group.duration - 0.001)
        playhead = Swift.min(Swift.max(0, time), end)
        // Hold drawing until the new frame decodes.
        isReady = false
        requestFrame()
    }

    public var onSceneLoaded: (([URL]) -> Void)?
    public var onError: ((any Error) -> Void)?
    public var onStatus: ((SceneStatus) -> Void)?
    /// Keys the host wants for itself, by physical key code. Return true when consumed. Movement
    /// keys are taken by the camera first and never reach this.
    public var onCommandKey: ((UInt16) -> Bool)?

    /// One renderer in `.mix`, one per pane in `.split`. Panes can't share one: its sort/preprocess
    /// buffers are overwritten by every `render(...)`.
    private var renderers: [SplatsRenderer] = []

    private let split = SplitLayout()
    private var draggingDivider: Int?

    private var playingBeforeDeactivation: Bool?
    private var smoothedFPS: Double = 0
    /// The scene's world placement. Pushed onto the scenes in `encodeScenes`, folded into the world
    /// bounds handed to `camera.setBBox` by `reframe`; the camera never sees it directly.
    private var model = matrix_identity_float4x4
    /// Cleared when `model` changes or a scene loads, so `encodeScenes` re-pushes it once.
    private var modelApplied = false
    /// Whether a fresh box frames the camera. `place` (a spawn) turns it off to keep the pose; a
    /// new scene turns it back on.
    private var autoFrames = true
    /// Renderer and camera rebuilt against the scenes' real numbers.
    private var appliedSettle = true
    /// Any scene still waiting on data. The clock does not advance while set.
    public private(set) var isBuffering = false
    private var isReady = true

    /// Draw-call handles hold GPU state until their command buffer retires. Slot `frameIndex % 3`
    /// holds frames from three commits ago, guaranteed complete by the frame budget, so overwriting
    /// it frees them deterministically on this thread.
    private var inFlight = [[Frame]](repeating: [], count: GraciaMetalView.maxFramesInFlight)
    private var frameIndex = 0

    public init(device: any MTLDevice, cacheDirectory: URL? = nil) throws {
        // Context must share this view's queue: `waitUntilIdle()` drains the queue we render on.
        guard let queue = device.makeCommandQueue() else {
            throw GraciaError.contextCreationFailed
        }
        context = try GraciaContext(
            device: device, commandQueue: queue, cacheDirectory: cacheDirectory)
        camera = SceneCamera()
        input = CameraInput(sceneCamera: camera)
        super.init(device: device, commandQueue: queue)

        colorPixelFormat = pass.metalColorPixelFormat
        depthStencilPixelFormat = pass.metalDepthPixelFormat
        sampleCount = Int(pass.sampleCount)
        clearDepth = pass.clearDepth
        // Splats blend premultiplied, so the background is the host's to choose.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Projection Z direction must match the pass's depth compare op.
        camera.reverseZ = pass.usesReverseZ
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("unavailable") }

    /// Drain before release: freeing scenes/renderers with frames still running on the GPU is a
    /// use-after-free (see README). `isolated` because the class is main-actor.
    isolated deinit {
        context.waitUntilIdle()
        inFlight = []
    }

    // MARK: - Scenes

    public var hasScenes: Bool { !(group?.isEmpty ?? true) }

    /// Loads one or more scenes, replacing whatever is showing. A single scene is always `.mix`.
    public func load(urls: [URL], layout: SceneLayout = .mix) throws {
        guard !urls.isEmpty else { return }
        // Built before teardown, so a bad file leaves the current scenes alone.
        try load(scenes: urls.map { try Scene(url: $0, context: context) }, layout: layout)
    }

    /// Opens an HTTP(S) MINT stream — streaming counterpart to ``load(urls:layout:)``. `token` is an
    /// optional bearer credential. Metadata lands after opening; the view re-frames then (see README).
    public func load(streamURL: String, token: String? = nil) throws {
        try load(scenes: [Scene(streamURL: streamURL, context: context, token: token)])
    }

    /// Shows scenes the caller built. Build them against this view's ``context``; scenes from
    /// another one render nothing.
    public func load(scenes: [Scene], layout: SceneLayout = .mix) throws {
        guard !scenes.isEmpty else { return }

        let group = SceneGroup(scenes)
        try swapContent {
            self.group = group
            sceneLayout = scenes.count > 1 ? layout : .mix
            try rebuildRenderers()
        }

        playhead = 0
        isBuffering = false
        isReady = !group.hasVideo
        appliedSettle = group.isSettled
        if group.duration > 0 { group.setPlaybackRange(0...group.duration) }

        model = matrix_identity_float4x4
        modelApplied = false
        camera.aspect = aspect
        // Reset so a previous spawn scene doesn't leave auto-framing off.
        autoFrames = true
        // Unsettled scenes have no box, so nothing frames or draws until `beforeFrame`.
        reframe()

        split.reset(paneCount: sceneLayout == .split ? scenes.count : 0)
        window?.invalidateCursorRects(for: self)
        contentDidChange()
        onSceneLoaded?(scenes.map(\.url))
    }

    /// Places the scene in the world. The transform lives on the scenes; the camera is told only the
    /// world bounds it produces, via `reframe`, so it stays pure view + projection.
    public func setSceneTransform(_ t: SceneTransform?) {
        model =
            t.map { simd_float4x4(translation: $0.translation, rotation: $0.rotation, scale: $0.scale) }
            ?? matrix_identity_float4x4
        modelApplied = false
        reframe()
    }

    /// The scene's world placement, for a host that needs it — e.g. to place its own camera.
    public var modelMatrix: simd_float4x4 { model }

    /// Places the camera explicitly; the box then only sets movement scale until the next scene.
    /// Use for a spawn — see `SplatsViewController`.
    public func place(eye: SIMD3<Float>, forward: SIMD3<Float>) {
        autoFrames = false
        camera.place(eye: eye, forward: forward)
    }

    /// Re-derives world-space bounds from the scene box and `model` and frames the camera on them —
    /// unless the host has `place`d it, when only movement scale updates. Call after the box settles
    /// or the transform changes.
    public func reframe() {
        guard let group else { return }
        let full = group.boundingBox
        guard full.isValid else {
            // Unsettled: hand the camera the empty box so it un-frames until it settles.
            camera.setBBox(full)
            return
        }
        let subject = group.adaptiveBBox.isValid ? group.adaptiveBBox : full
        camera.setBBox(
            worldBounds(of: full, model: model),
            adaptive: worldBounds(of: subject, model: model),
            reposition: autoFrames)
    }

    /// Only meaningful with more than one scene.
    public func setLayout(_ layout: SceneLayout) throws {
        guard let group, group.scenes.count > 1, layout != sceneLayout else { return }
        try swapContent {
            sceneLayout = layout
            try rebuildRenderers()
        }

        split.reset(paneCount: layout == .split ? group.scenes.count : 0)
        window?.invalidateCursorRects(for: self)
        requestFrame()
    }

    public func toggleLayout() throws { try setLayout(sceneLayout == .mix ? .split : .mix) }

    /// Sets an internal flag on the loaded scene(s), then redraws. For other per-scene knobs, reach
    /// ``group`` and ``requestFrame()``.
    public func setSceneFlag(_ key: String, _ value: Bool) {
        group?.setFlag(key, value)
        requestFrame()
    }

    /// Swaps scenes/renderers with nothing of ours running on the GPU. Order is load-bearing: drain
    /// frames, `waitUntilIdle()`, release draw-call handles, then `body`. Any other order is a
    /// use-after-free when a scene is swapped mid-flight (see README).
    private func swapContent(_ body: () throws -> Void) throws {
        try withDrainedFrames {
            // The SDK submits its own uploads and readbacks on our queue too.
            context.waitUntilIdle()
            releaseInFlightFrames()
            try body()
        }
    }

    /// Renderers sized to the scenes they draw (summed budget in `.mix`, per-scene in `.split`).
    /// Only ever called from ``swapContent(_:)``.
    private func rebuildRenderers() throws {
        guard let group else { return renderers = [] }
        let budgets = sceneLayout == .mix ? [group.splatsBudget] : group.scenes.map(\.splatsBudget)
        // Free the old set first: holding both costs ~1 GB on a large scene.
        renderers = []
        renderers = try budgets.map { budget in
            let renderer = try SplatsRenderer(context: context, maxSplatsCount: max(budget, 1))
            // Without this the visible-splat counter always reads back 0.
            renderer.setFlag("splats_count_readback", true)
            return renderer
        }
    }

    // MARK: - Frame

    /// `drawableSize` is reported only once the view has a layer; `bounds` covers that gap.
    private var aspect: Float {
        let size = drawableSize.height > 0 ? drawableSize : bounds.size
        return size.height > 0 ? Float(size.width / size.height) : 1
    }

    public override func drawableSizeChanged(_ size: CGSize) {
        camera.aspect = aspect
    }

    public override func render(
        target: any MTLTexture, descriptor: MTLRenderPassDescriptor,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let dt = frameTime
        if dt > 0 { smoothedFPS += (1 / dt - smoothedFPS) * 0.1 }

        // Pacing first: `requestFrame()` is a no-op while `.continuous`, so settle the mode before
        // asking for the camera's next frame — otherwise the frame a video pauses/stops buffering
        // strands the camera mid-gesture with nothing scheduled to drain its inertia.
        advancePlayback(dt: dt)
        updateRenderMode()

        // Inertia keeps the camera moving after the gesture ends, so keep asking for frames.
        if camera.update(dt: Float(dt)) { requestFrame() }

        let size = CGSize(width: target.width, height: target.height)
        let frames = encodeScenes(commandBuffer: commandBuffer, size: size)

        // Buffering if any scene is: `.mix` folds frames into one, so `isReady` catches a single
        // lagging scene there.
        isBuffering = !isReady || frames.contains { $0.buffering }

        guard let encoder = makeEncoder(commandBuffer, descriptor: descriptor) else { return false }
        execute(frames, in: encoder, size: size)
        encoder.endEncoding()

        retire(frames)
        publishStatus()

        // Re-settle pacing now that this frame's `isBuffering` is current (the pass above saw the
        // previous frame's), so a stream that starts buffering while paused stays pumped.
        updateRenderMode()

        return true
    }

    /// Every `render(...)` opens its own compute encoders on the command buffer, so all run before
    /// any render encoder exists.
    private func encodeScenes(commandBuffer: any MTLCommandBuffer, size: CGSize) -> [Frame] {
        guard let group, !group.isEmpty, camera.isFramed else { return [] }

        // Push the scene transform once whenever it changes.
        if !modelApplied {
            group.setTransform(model)
            modelApplied = true
        }

        let view3D = camera.renderView(aspect: aspect, viewHeightPoints: Float(bounds.height))
        let w = UInt32(size.width)
        let h = UInt32(size.height)

        func render(_ renderer: SplatsRenderer, _ scenes: [Scene]) -> Frame {
            renderer.render(
                scenes: scenes, view: view3D, targetWidth: w, targetHeight: h, pass: pass,
                commandBuffer: commandBuffer)
        }

        switch sceneLayout {
        case .mix:
            guard let renderer = renderers.first else { return [] }
            return [render(renderer, group.scenes)]
        case .split:
            guard renderers.count == group.scenes.count else { return [] }
            return zip(renderers, group.scenes).map { render($0, [$1]) }
        }
    }

    private func execute(
        _ frames: [Frame], in encoder: any MTLRenderCommandEncoder, size: CGSize
    ) {
        guard sceneLayout == .split, frames.count > 1 else {
            frames.first?.color.mono?.execute(into: encoder)
            return
        }
        // Each pane resolves its imageblock into its column; the scissor clips the tile pipeline's
        // full-screen resolve. The SDK never touches the scissor itself.
        let rects = split.scissorRects(width: Int(size.width), height: Int(size.height))
        for (frame, rect) in zip(frames, rects) where rect.width > 0 {
            encoder.setScissorRect(rect)
            frame.color.mono?.execute(into: encoder)
        }
    }

    /// The SDK configures the render pass for the pipeline it picked. With no renderer yet the
    /// drawable is simply cleared.
    private func makeEncoder(
        _ commandBuffer: any MTLCommandBuffer, descriptor: MTLRenderPassDescriptor
    ) -> (any MTLRenderCommandEncoder)? {
        guard let renderer = renderers.first else {
            return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        }
        return renderer.makeRenderCommandEncoder(commandBuffer, descriptor: descriptor, pass: pass)
    }

    /// Continuous while a video needs a clock, is buffering, or is still settling; else on-demand.
    /// Buffering keeps ticking even while paused, since `pump()` (the only network check) runs only
    /// in the loop. Run twice per `render(...)` — before the camera step, then again once
    /// `isBuffering` is current.
    private func updateRenderMode() {
        let videoNeedsFrames =
            group?.hasVideo == true && (isPlaying || !isReady || isBuffering || !appliedSettle)
        renderMode = videoNeedsFrames ? .continuous : .onDemand
    }

    /// Gated on `hasVideo`, not duration: a stream must be pumped to learn its duration.
    private func advancePlayback(dt: CFTimeInterval) {
        guard let group, group.hasVideo else { return }

        // Stall the clock while buffering so playback doesn't skip ahead.
        if isPlaying, !isBuffering, isReady, group.duration > 0 {
            playhead += dt * playbackSpeed
            if playhead >= group.duration { playhead = 0 }
        }
        group.setTime(playhead)
        isReady = group.pump()
    }

    /// Metadata landed. Renderer and camera were built against placeholders, so rebuild both here
    /// where draining is still allowed. See README, "Late metadata".
    public override func beforeFrame() {
        guard let group, !appliedSettle, group.isSettled else { return }
        appliedSettle = true

        do {
            try swapContent { try rebuildRenderers() }
        } catch {
            onError?(error)
            return
        }
        group.setPlaybackRange(0...group.duration)
        reframe()
        contentDidChange()
    }

    private func retire(_ frames: [Frame]) {
        inFlight[frameIndex % GraciaMetalView.maxFramesInFlight] = frames
        frameIndex &+= 1
    }

    /// Frees every outstanding draw-call handle. Safe only once the GPU is idle.
    private func releaseInFlightFrames() {
        inFlight = [[Frame]](repeating: [], count: GraciaMetalView.maxFramesInFlight)
        frameIndex = 0
    }

    /// Summed across renderers, so it means the same in `.mix` and `.split`.
    public var visibleSplatsCount: UInt32 {
        renderers.reduce(0) { $0 &+ $1.visibleSplatsCount }
    }

    private func publishStatus() {
        guard let onStatus, let group else { return }
        onStatus(
            SceneStatus(
                sceneNames: group.scenes.map(\.name),
                layout: sceneLayout,
                visibleSplats: visibleSplatsCount,
                visibleSplatsPerScene: renderers.map(\.visibleSplatsCount),
                splatsBudget: group.splatsBudget,
                fps: smoothedFPS,
                hasVideo: group.hasVideo,
                isPlaying: isPlaying,
                isBuffering: isBuffering,
                playhead: playhead,
                duration: group.duration,
                gpuBytes: context.gpuAllocatedBytes))
    }

    // MARK: - Geometry

    public override var acceptsFirstResponder: Bool { true }

    public override func layout() {
        super.layout()
        input.viewHeightChanged(Float(bounds.height))
        window?.invalidateCursorRects(for: self)
    }

    /// A keyUp never reaches us while another app is frontmost, so release held keys or a movement
    /// key stays down forever. Playback is suspended too, and restored on the way back.
    public override func windowActiveChanged(_ active: Bool) {
        super.windowActiveChanged(active)
        input.releaseAllKeys()
        if active {
            if let was = playingBeforeDeactivation {
                isPlaying = was
                playingBeforeDeactivation = nil
            }
        } else if playingBeforeDeactivation == nil {
            playingBeforeDeactivation = isPlaying
            isPlaying = false
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        // Match the drag hit-test's grab band: ±dividerHitZone around the divider.
        for x in split.dividerPositions(width: bounds.width) {
            addCursorRect(
                NSRect(
                    x: x - SplitLayout.dividerHitZone, y: 0,
                    width: SplitLayout.dividerHitZone * 2, height: bounds.height),
                cursor: .resizeLeftRight)
        }
    }

    /// `CameraInput` wants y growing downward; AppKit's grows upward.
    private func point(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(bounds.height - p.y))
    }

    private func modifiers(_ event: NSEvent) -> InputModifiers {
        var m = InputModifiers()
        if event.modifierFlags.contains(.shift) { m.insert(.shift) }
        if event.modifierFlags.contains(.option) { m.insert(.option) }
        if event.modifierFlags.contains(.command) { m.insert(.command) }
        return m
    }

    // MARK: - Pointer

    public override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if split.isActive, let i = split.dividerIndex(nearX: x, width: bounds.width) {
            draggingDivider = i
            return
        }
        input.pointerDown(at: point(event), button: .primary, modifiers: modifiers(event))
    }

    public override func rightMouseDown(with event: NSEvent) {
        input.pointerDown(at: point(event), button: .secondary, modifiers: modifiers(event))
    }

    public override func mouseDragged(with event: NSEvent) {
        if let i = draggingDivider {
            split.drag(divider: i, dx: event.deltaX, width: bounds.width)
            window?.invalidateCursorRects(for: self)
            requestFrame()
            return
        }
        input.pointerDragged(to: point(event))
        requestFrame()
    }

    public override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

    public override func mouseUp(with event: NSEvent) {
        draggingDivider = nil
        input.pointerUp()
        requestFrame()
    }

    public override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    public override func scrollWheel(with event: NSEvent) {
        input.scroll(
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            modifiers: modifiers(event))
        requestFrame()
    }

    public override func magnify(with event: NSEvent) {
        input.magnify(Float(event.magnification))
        requestFrame()
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        // Held movement keys must swallow auto-repeat; commands must not.
        if input.keyDown(keyCode: event.keyCode) {
            requestFrame()
            return
        }
        if !event.isARepeat, onCommandKey?(event.keyCode) == true {
            requestFrame()
            return
        }
        super.keyDown(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if !input.keyUp(keyCode: event.keyCode) { super.keyUp(with: event) }
    }

    public override func flagsChanged(with event: NSEvent) {
        input.modifiersChanged(modifiers(event))
    }

    public override func resignFirstResponder() -> Bool {
        input.releaseAllKeys()
        return super.resignFirstResponder()
    }


    // MARK: - Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDroppedFiles && !droppedURLs(sender).isEmpty ? .copy : []
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard acceptsDroppedFiles, !urls.isEmpty else { return false }
        do {
            try load(urls: urls, layout: droppedFilesLayout)
        } catch {
            onError?(error)
        }
        return true
    }

    private func droppedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.filter { Scene.supportedExtensions.contains($0.pathExtension.lowercased()) }
            ?? []
    }
}

#endif  // os(macOS)
