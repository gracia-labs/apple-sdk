//
//  macOS RealityKit ARView hosting GraciaARViewPostProcess (direct .d16Unorm splat-pass depth +
//  half4 compute depth occlusion against an orbiting RealityKit occluder cube).
//

import AppKit
import Combine
import GraciaRealityKit
import GraciaSDK
import RealityKit
import SwiftUI
import simd

struct RealityKitSplatsViewport: View {
    let sceneURL: URL?
    let isPlaying: Bool
    let showOccluder: Bool
    let resetToken: Int

    @State private var yaw: Float = 0.35
    @State private var pitch: Float = -0.25
    @State private var distance: Float = 2.6
    @State private var dragStart: (yaw: Float, pitch: Float)?

    var body: some View {
        ARViewBridge(
            sceneURL: sceneURL,
            isPlaying: isPlaying,
            showOccluder: showOccluder,
            yaw: yaw,
            pitch: pitch,
            distance: distance)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let base = dragStart ?? (yaw, pitch)
                    if dragStart == nil { dragStart = base }
                    yaw = base.yaw - Float(value.translation.width) * 0.008
                    pitch = min(max(base.pitch - Float(value.translation.height) * 0.008, -1.4), 1.4)
                }
                .onEnded { _ in dragStart = nil }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    distance = min(max(distance / Float(max(value.magnification, 0.2)), 0.4), 20)
                }
        )
        .onChange(of: resetToken) { _, _ in
            yaw = 0.35; pitch = -0.25; distance = 2.6
        }
    }
}

private struct ARViewBridge: NSViewRepresentable {
    let sceneURL: URL?
    let isPlaying: Bool
    let showOccluder: Bool
    let yaw: Float
    let pitch: Float
    let distance: Float

    @MainActor
    final class Coordinator {
        let postProcess = GraciaARViewPostProcess()
        let splatEntity = Entity()
        let cameraEntity = PerspectiveCamera()
        let occluder: ModelEntity
        var loadedURL: URL?
        var elapsed: Float = 0
        var subscription: (any Cancellable)?

        init() {
            let mesh = MeshResource.generateBox(size: 0.28, cornerRadius: 0.03)
            let mat = SimpleMaterial(color: .systemOrange, isMetallic: true)
            occluder = ModelEntity(mesh: mesh, materials: [mat])
        }

        func setup(in arView: ARView) {
            arView.environment.background = .color(NSColor(white: 0.08, alpha: 1))

            let root = AnchorEntity(world: .zero)
            root.addChild(splatEntity)
            root.addChild(occluder)
            root.addChild(cameraEntity)

            let light = DirectionalLight()
            light.light.intensity = 2500
            light.look(at: .zero, from: [2, 3, 2], relativeTo: nil)
            root.addChild(light)

            // Install render callbacks before the custom camera enters the scene.
            postProcess.attach(to: arView, entity: splatEntity)
            arView.scene.addAnchor(root)

            subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.elapsed += Float(event.deltaTime)
                    let a = self.elapsed * 0.9
                    let box = self.postProcess.bridge.boundingBox
                    let center = box.isValid ? box.center : .zero
                    let r = box.isValid ? max(box.radius * 0.65, 0.45) : 0.7
                    self.occluder.position = center + SIMD3(cos(a) * r, 0.1 * sin(a * 2), sin(a) * r)
                    self.occluder.orientation = simd_quatf(angle: a * 1.4, axis: normalize(SIMD3(0.4, 1, 0.2)))
                }
            }
        }

        func update(url: URL?, isPlaying: Bool, showOccluder: Bool, yaw: Float, pitch: Float, distance: Float) {
            if url != loadedURL {
                loadedURL = url
                if let url { postProcess.bridge.load(url: url) } else { postProcess.bridge.unload() }
            }
            postProcess.bridge.isPlaying = isPlaying
            occluder.isEnabled = showOccluder

            let box = postProcess.bridge.boundingBox
            let target = box.isValid ? box.center : .zero
            let r = box.isValid ? max(box.radius * distance, 0.5) : distance
            let eye = target + SIMD3(
                r * cos(pitch) * sin(yaw),
                r * sin(-pitch),
                r * cos(pitch) * cos(yaw))
            cameraEntity.look(at: target, from: eye, relativeTo: nil)
        }

        func teardown(from arView: ARView) {
            subscription?.cancel()
            subscription = nil
            postProcess.detach(from: arView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        context.coordinator.setup(in: view)
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {
        context.coordinator.update(
            url: sceneURL, isPlaying: isPlaying, showOccluder: showOccluder,
            yaw: yaw, pitch: pitch, distance: distance)
    }

    static func dismantleNSView(_ view: ARView, coordinator: Coordinator) {
        coordinator.teardown(from: view)
    }
}
