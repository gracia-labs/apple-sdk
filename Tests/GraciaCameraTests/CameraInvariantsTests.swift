import GraciaSDK
import Testing
import simd

@testable import GraciaCamera

/// The camera is free: no bounds, no cage, every direction open. What must hold is that whatever
/// sequence of gestures it is put through, the pose stays finite, the projection stays sane, and
/// recentring brings it home.
///
/// Rather than enumerate the ways to break it by hand, this beats on every input at once.
@Suite("Camera invariants")
struct CameraInvariantsTests {
    /// Deterministic — a fuzz test that cannot be reproduced is a fuzz test that cannot be fixed.
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)  // 0..<1
        }
        mutating func signed(_ scale: Float) -> Float { (next() * 2 - 1) * scale }
        mutating func chance(_ p: Float) -> Bool { next() < p }
    }

    private func make(radius: Float, at centre: SIMD3<Float>) -> (SceneCamera, CameraInput) {
        let camera = SceneCamera()
        let input = CameraInput(sceneCamera: camera)
        input.viewHeightChanged(800)
        camera.aspect = 16.0 / 9
        let half = radius / (3 as Float).squareRoot()
        camera.setBBox(
            BoundingBox(min: centre - SIMD3(repeating: half), max: centre + SIMD3(repeating: half)))
        return (camera, input)
    }

    struct Scene: Sendable, CustomStringConvertible {
        let radius: Float
        let centre: SIMD3<Float>
        var description: String { "radius \(radius) at \(centre)" }
    }

    /// Every gesture, in every order, at every scale — and the camera still knows where it is.
    @Test(arguments: [
        Scene(radius: 0.5, centre: .zero),  // a doll's house
        Scene(radius: 12, centre: SIMD3(3, -2, 40)),  // a room, off the origin
        Scene(radius: 5000, centre: SIMD3(-800, 120, 0)),  // a city, well off it
        Scene(radius: 78.9, centre: SIMD3(7.9, 20.6, 11.3)),  // the golf scene, to scale
    ])
    func noSequenceOfGesturesCanLoseTheCamera(_ scene: Scene) {
        let (radius, centre) = (scene.radius, scene.centre)
        let (camera, input) = make(radius: radius, at: centre)
        var rng = Random(seed: 0xF00D)



        for step in 0..<4000 {
            switch Int(rng.next() * 6) {
            case 0: input.pointerDown(at: SIMD2(rng.next() * 800, rng.next() * 800))
            case 1: input.pointerDragged(to: SIMD2(rng.signed(4000), rng.signed(4000)))
            case 2: input.scroll(deltaY: rng.signed(2000), precise: rng.chance(0.5))
            case 3: input.magnify(rng.signed(0.9))
            case 4:
                let movement = [
                    KeyCode.w, KeyCode.a, KeyCode.s, KeyCode.d, KeyCode.r, KeyCode.f,
                ]
                input.keyDown(keyCode: movement[Int(rng.next() * Float(movement.count)) % 6])
            default: input.releaseAllKeys()
            }
            if rng.chance(0.05) { input.modifiersChanged(rng.chance(0.5) ? [.shift] : []) }

            camera.update(dt: 1.0 / 60)

            let view = camera.renderView(aspect: 16.0 / 9, viewHeightPoints: 800)
            let eye = view.cameraToWorld.columns.3

            #expect(eye.x.isFinite && eye.y.isFinite && eye.z.isFinite, "went non-finite at \(step)")
            for column in [view.projection.columns.0, view.projection.columns.2] {
                #expect(column.x.isFinite && column.z.isFinite, "projection went bad at \(step)")
            }
        }

        // The camera is free to be anywhere. What must hold is that it can always come home.
        input.releaseAllKeys()
        camera.reset()
        let home = camera.renderView(aspect: 16.0 / 9, viewHeightPoints: 800).cameraToWorld.columns.3
        #expect(simd_length(SIMD3(home.x, home.y, home.z) - centre) < radius * 8)
    }
}
