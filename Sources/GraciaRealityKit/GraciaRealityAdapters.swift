//
//  Thin RealityKit adapters over GraciaRealityBridge:
//    - GraciaPostProcessEffect  (RealityView, iOS 26 / macOS 26)
//    - GraciaARViewPostProcess  (ARView, iOS 16.4 / macOS 14)
//    - GraciaRealityHybrid      (RealityRenderer + MTLSharedEvent, iOS 18 / macOS 15 / visionOS 2+)
//    - GraciaTextureHost        (LowLevelTexture + memoryless depth, iOS 18 / macOS 15 / visionOS 2+)
//

import Foundation
import GraciaSDK
import Metal
import RealityKit
import simd

#if !os(visionOS)
import Combine

/// `RealityView` post-process effect (`content.renderingEffects.customPostProcessing = .effect(...)`).
@available(iOS 26.0, macOS 26.0, *)
public final class GraciaPostProcessEffect: PostProcessEffect, @unchecked Sendable {
    public let bridge: GraciaRealityBridge

    public init(bridge: GraciaRealityBridge = GraciaRealityBridge()) { self.bridge = bridge }

    public func prepare(for device: any MTLDevice) { bridge.prepare(device: device) }

    public func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        bridge.encodeComposite(
            sourceColor: context.sourceColorTexture,
            sourceDepth: context.sourceDepthTexture,
            targetColor: context.targetColorTexture,
            projection: context.projection,
            commandBuffer: context.commandBuffer)
    }
}

/// `ARView` post-process adapter (`arView.renderCallbacks.postProcess`).
public final class GraciaARViewPostProcess: @unchecked Sendable {
    public let bridge: GraciaRealityBridge
    private var subscription: (any Cancellable)?

    public init(bridge: GraciaRealityBridge = GraciaRealityBridge()) { self.bridge = bridge }

    @MainActor
    public func attach(to arView: ARView, entity: Entity) {
        arView.renderCallbacks.prepareWithDevice = { [weak self] in self?.bridge.prepare(device: $0) }
        arView.renderCallbacks.postProcess = { [weak self] ctx in
            self?.bridge.encodeComposite(
                sourceColor: ctx.sourceColorTexture,
                sourceDepth: ctx.sourceDepthTexture,
                targetColor: ctx.targetColorTexture,
                projection: ctx.projection,
                commandBuffer: ctx.commandBuffer)
        }
        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) {
            [weak self, weak arView, weak entity] _ in
            MainActor.assumeIsolated {
                guard let self, let arView, let entity else { return }
                self.bridge.sync(entity: entity)
                self.bridge.setCameraToWorld(arView.cameraTransform.matrix)
            }
        }
    }

    @MainActor
    public func detach(from arView: ARView) {
        subscription?.cancel()
        subscription = nil
        arView.renderCallbacks.postProcess = nil
        arView.renderCallbacks.prepareWithDevice = nil
        bridge.invalidate()
    }
}
#endif

/// Hybrid `RealityRenderer` + `GraciaRealityBridge` synchronized via `MTLSharedEvent`.
/// Uses `.rgba8Unorm` intermediate color (4 B/px) by default to minimize GPU bandwidth.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class GraciaRealityHybrid {
    public let device: any MTLDevice
    public let realityRenderer: RealityRenderer
    public let bridge: GraciaRealityBridge

    private let syncEvent: any MTLSharedEvent
    private var eventValue: UInt64 = 0
    private var realityColor: (any MTLTexture)?
    private var cameraOutput: RealityRenderer.CameraOutput?

    public init(
        device: any MTLDevice,
        commandQueue: (any MTLCommandQueue)? = nil,
        bridge: GraciaRealityBridge = GraciaRealityBridge()
    ) throws {
        guard let event = device.makeSharedEvent() else { throw GraciaError.contextCreationFailed }
        self.device = device
        self.realityRenderer = try RealityRenderer()
        self.bridge = bridge
        self.bridge.prepare(device: device, commandQueue: commandQueue)
        self.syncEvent = event
    }

    public func renderFrame(
        deltaTime: TimeInterval,
        view: RenderView,
        targetColor: any MTLTexture,
        realityDepth: (any MTLTexture)? = nil,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let (rkColor, output) = try ensureTarget(width: targetColor.width, height: targetColor.height)
        eventValue &+= 1
        let signal = eventValue
        try realityRenderer.updateAndRender(
            deltaTime: deltaTime,
            cameraOutput: output,
            actionsBeforeRender: [],
            actionsAfterRender: [.signal(syncEvent, value: signal)])
        commandBuffer.encodeWaitForEvent(syncEvent, value: signal)
        bridge.encodeComposite(
            sourceColor: rkColor, sourceDepth: realityDepth,
            targetColor: targetColor,
            projection: view.projection, cameraToWorld: view.cameraToWorld,
            commandBuffer: commandBuffer)
    }

    private func ensureTarget(width: Int, height: Int) throws -> (any MTLTexture, RealityRenderer.CameraOutput) {
        let fmt = bridge.colorFormat.metalPixelFormat
        if let t = realityColor, let o = cameraOutput, t.width == width, t.height == height {
            return (t, o)
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: fmt, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { throw GraciaError.rendererCreationFailed }
        let out = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
        realityColor = tex
        cameraOutput = out
        return (tex, out)
    }
}

/// Renders splats directly into a RealityKit `LowLevelTexture` (`.rgba8Unorm`) with a `.memoryless`
/// `.depth16Unorm` attachment (zero DRAM depth bandwidth on Apple silicon).
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class GraciaTextureHost {
    public let commandQueue: any MTLCommandQueue
    public let bridge: GraciaRealityBridge
    public let lowLevelTexture: LowLevelTexture
    public let textureResource: TextureResource
    private let depthTexture: any MTLTexture

    public init(
        device: any MTLDevice,
        width: Int,
        height: Int,
        colorFormat: ColorFormat = .rgba8Unorm,
        depthFormat: DepthFormat = .d16Unorm,
        audio: AudioOutput = .device
    ) throws {
        guard let queue = device.makeCommandQueue() else { throw GraciaError.contextCreationFailed }
        let llTex = try LowLevelTexture(descriptor: .init(
            pixelFormat: colorFormat.metalPixelFormat,
            width: width, height: height,
            textureUsage: [.shaderRead, .renderTarget]))
        let resource = try TextureResource(from: llTex)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat.metalPixelFormat, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        guard let depth = device.makeTexture(descriptor: depthDesc) else {
            throw GraciaError.rendererCreationFailed
        }

        let bridge = GraciaRealityBridge(colorFormat: colorFormat, depthFormat: depthFormat, audio: audio)
        bridge.prepare(device: device, commandQueue: queue)

        self.commandQueue = queue
        self.bridge = bridge
        self.lowLevelTexture = llTex
        self.textureResource = resource
        self.depthTexture = depth
    }

    @discardableResult
    public func renderFrame(
        view: RenderView,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    ) -> Bool {
        guard let cb = commandQueue.makeCommandBuffer() else { return false }
        let target = lowLevelTexture.replace(using: cb)
        let drew = bridge.encodeDirect(
            colorTexture: target, depthTexture: depthTexture,
            views: [view], clearColor: clearColor, commandBuffer: cb)
        cb.commit()
        return drew
    }
}
