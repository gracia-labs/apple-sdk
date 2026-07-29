#if os(macOS)

//
//  Content-agnostic MTKView base that knows how to *not* draw; subclasses override
//  ``render(target:descriptor:commandBuffer:)``. AppKit/MetalKit stop here so
//  `GraciaSDK`/`GraciaCamera` stay portable.
//

import AppKit
import CoreGraphics
import ImageIO
import MetalKit
import UniformTypeIdentifiers

/// Base view: pacing, command queue, frames in flight, snapshots. Pauses while the window is
/// inactive; `.onDemand` draws only on request.
open class GraciaMetalView: MTKView, MTKViewDelegate {
    public enum RenderMode: Sendable {
        /// Drive the display link, for animating content.
        case continuous
        /// Draw only on ``requestFrame()``, for static content.
        case onDemand
    }

    /// Matches the SDK renderer's ring buffers: a fourth queued frame would overwrite one the GPU
    /// is still reading.
    public static let maxFramesInFlight = 3

    public let commandQueue: any MTLCommandQueue

    /// Seconds since the previous frame, clamped so a hitch cannot jump an animation forward.
    public private(set) var frameTime: CFTimeInterval = 0
    public var maxFrameTime: CFTimeInterval = 0.25

    /// True once there is something to draw. Nothing is drawn before it.
    public private(set) var hasContent = false

    public var renderMode: RenderMode = .onDemand {
        didSet { if renderMode != oldValue { applyRenderState() } }
    }

    /// Keeps a window that never becomes key (e.g. a headless snapshot run) from being paused
    /// before it draws.
    public var ignoresWindowActivation = false {
        didSet { refreshWindowState() }
    }

    /// Lets the host suspend playback while the window is hidden and resume after.
    public var onWindowActiveChanged: ((Bool) -> Void)?

    /// True while a snapshot is pending, which forces `.continuous` regardless of ``renderMode``.
    public var isSnapshotting: Bool { snapshot != nil }

    private let frameBudget = DispatchSemaphore(value: GraciaMetalView.maxFramesInFlight)
    private var lastTimestamp: CFTimeInterval = 0
    private var windowActive = false
    private var snapshot: PendingSnapshot?
    /// Touched from `deinit`, which is nonisolated. `NotificationCenter` is thread-safe.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// - Parameter commandQueue: the queue frames are submitted on. Pass the one the
    ///   `GraciaContext` was created with, or `waitUntilIdle()` drains the wrong queue and frees
    ///   GPU state the renderer is still reading.
    public init(device: any MTLDevice, commandQueue: (any MTLCommandQueue)? = nil) {
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            preconditionFailure("failed to create a Metal command queue")
        }
        self.commandQueue = queue
        super.init(frame: .zero, device: device)
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
    }

    /// Follows the display the view is on (120 on ProMotion, 60 on most externals). Override by
    /// setting `preferredFramesPerSecond` after the view has a window.
    private func matchDisplayRefreshRate() {
        guard let rate = window?.screen?.maximumFramesPerSecond, rate > 0 else { return }
        preferredFramesPerSecond = rate
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("unavailable") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Subclass hooks

    /// Encode this frame; return true to present the drawable. Called with no encoder open on
    /// `commandBuffer`, which the base class commits either way.
    open func render(
        target: any MTLTexture, descriptor: MTLRenderPassDescriptor,
        commandBuffer: any MTLCommandBuffer
    ) -> Bool { false }

    open func drawableSizeChanged(_ size: CGSize) {}

    /// Window became key and visible, or stopped being so. Called before ``onWindowActiveChanged``;
    /// a subclass should call `super`.
    open func windowActiveChanged(_ active: Bool) {}

    /// Top of a frame, before the budget is taken — the only point where ``withDrainedFrames(_:)``
    /// may be called.
    open func beforeFrame() {}

    // MARK: - Pacing

    /// There is something to draw now. Safe to call repeatedly.
    public func contentDidChange() {
        hasContent = true
        applyRenderState()
    }

    /// Schedules one frame. No-op in `.continuous` mode and before there is content.
    public func requestFrame() {
        guard effectiveRenderMode == .onDemand, hasContent else { return }
        needsDisplay = true
    }

    /// Runs `body` with no frames in flight — when a retired frame's GPU resources may be freed.
    /// Blocks the main thread for up to a frame; call when swapping content, never per frame.
    public func withDrainedFrames<T>(_ body: () throws -> T) rethrows -> T {
        for _ in 0..<Self.maxFramesInFlight { frameBudget.wait() }
        defer { for _ in 0..<Self.maxFramesInFlight { frameBudget.signal() } }
        return try body()
    }

    private var effectiveRenderMode: RenderMode { isSnapshotting ? .continuous : renderMode }

    private func applyRenderState() {
        switch effectiveRenderMode {
        case .continuous:
            let run = hasContent && windowActive
            isPaused = !run
            enableSetNeedsDisplay = !run
        case .onDemand:
            isPaused = true
            enableSetNeedsDisplay = true
            if hasContent { needsDisplay = true }
        }
    }

    // MARK: - Window tracking

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        guard let window else {
            windowActive = false
            applyRenderState()
            return
        }

        let center = NotificationCenter.default
        let track = { [weak self] (name: Notification.Name, object: Any?) in
            self?.observers.append(
                center.addObserver(forName: name, object: object, queue: .main) { _ in
                    MainActor.assumeIsolated { self?.refreshWindowState() }
                })
        }
        track(NSWindow.didBecomeKeyNotification, window)
        track(NSWindow.didResignKeyNotification, window)
        track(NSWindow.didChangeOcclusionStateNotification, window)
        // Dragging to a display with a different refresh rate.
        track(NSWindow.didChangeScreenNotification, window)
        track(NSApplication.didHideNotification, nil)
        track(NSApplication.didUnhideNotification, nil)

        matchDisplayRefreshRate()
        refreshWindowState()
        window.makeFirstResponder(self)
    }

    private func refreshWindowState() {
        matchDisplayRefreshRate()
        let active =
            ignoresWindowActivation
            || (window?.isKeyWindow == true
                && window?.occlusionState.contains(.visible) == true
                && !NSApp.isHidden)
        guard active != windowActive else { return }
        windowActive = active
        applyRenderState()
        windowActiveChanged(active)
        onWindowActiveChanged?(active)
    }

    // MARK: - Snapshot

    /// Renders `frames` more frames, then writes the drawable to `url` as a PNG. Forces
    /// `.continuous` (so it works from a non-key window) and clears `framebufferOnly` so the
    /// drawable is readable.
    public func snapshot(
        to url: URL, afterFrames frames: Int = 1,
        then completion: @escaping (Result<URL, any Error>) -> Void
    ) {
        framebufferOnly = false
        snapshot = PendingSnapshot(
            url: url, remainingFrames: max(1, frames), completion: completion)
        applyRenderState()
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSizeChanged(size)
    }

    public func draw(in view: MTKView) {
        // Metal drawables are autoreleased; without a pool they pile up for a run-loop turn.
        autoreleasepool { drawFrame() }
    }

    private func drawFrame() {
        let now = CACurrentMediaTime()
        frameTime = lastTimestamp == 0 ? 1.0 / 60 : Swift.min(now - lastTimestamp, maxFrameTime)
        lastTimestamp = now

        // Draining wants every permit; below this line we hold one.
        beforeFrame()

        frameBudget.wait()
        var handedOff = false
        defer { if !handedOff { frameBudget.signal() } }

        guard let drawable = currentDrawable,
            let descriptor = currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let present = render(
            target: drawable.texture, descriptor: descriptor, commandBuffer: commandBuffer)

        if let snapshot {
            snapshot.encodeIfLastFrame(from: drawable.texture, in: commandBuffer)
            snapshot.remainingFrames -= 1
            if snapshot.remainingFrames <= 0 {
                self.snapshot = nil
                framebufferOnly = true
                commandBuffer.addCompletedHandler { _ in
                    Task { @MainActor in snapshot.write() }
                }
                applyRenderState()
            }
        }

        let budget = frameBudget
        commandBuffer.addCompletedHandler { _ in budget.signal() }
        handedOff = true

        if present { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }
}

// MARK: - Snapshot writing

/// Blits the drawable into a CPU-readable texture and writes it as a PNG.
@MainActor
private final class PendingSnapshot {
    let url: URL
    var remainingFrames: Int
    private let completion: (Result<URL, any Error>) -> Void
    private var texture: (any MTLTexture)?

    init(
        url: URL, remainingFrames: Int,
        completion: @escaping (Result<URL, any Error>) -> Void
    ) {
        self.url = url
        self.remainingFrames = remainingFrames
        self.completion = completion
    }

    func encodeIfLastFrame(from drawable: any MTLTexture, in commandBuffer: any MTLCommandBuffer) {
        guard remainingFrames <= 1 else { return }

        if texture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: drawable.pixelFormat, width: drawable.width, height: drawable.height,
                mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            texture = drawable.device.makeTexture(descriptor: d)
        }
        guard let texture, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: drawable, to: texture)
        blit.endEncoding()
    }

    func write() {
        guard let texture else { return completion(.failure(SnapshotError.nothingCaptured)) }

        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        // Drawable is opaque RGB. The tile path leaves splat coverage in alpha; honouring it would
        // un-premultiply silhouette edges into white halos, so skip it.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return completion(.failure(SnapshotError.encodingFailed)) }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return completion(.failure(SnapshotError.encodingFailed))
        }
        completion(.success(url))
    }
}

public enum SnapshotError: Error, CustomStringConvertible {
    case nothingCaptured
    case encodingFailed

    public var description: String {
        switch self {
        case .nothingCaptured: "no frame was captured"
        case .encodingFailed: "could not encode the snapshot"
        }
    }
}

#endif  // os(macOS)
