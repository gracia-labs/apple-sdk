import GraciaSDK
import Testing
import simd

@testable import GraciaCamera

private func ~= (a: Float, b: Float) -> Bool { abs(a - b) < 1e-4 }
private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    simd_length(a - b) < eps
}

// MARK: - Math

@Suite("Camera math")
struct CameraMathTests {
    /// `yawPitch` feeds the one place the camera builds an orientation from a direction: `pose`,
    /// which aims the eye at a target. The quaternion it makes must look back down that direction.
    @Test func yawPitchRebuildsTheDirectionItCameFrom() {
        for yaw in stride(from: -3.0 as Float, through: 3.0, by: 0.7) {
            for pitch in stride(from: -1.4 as Float, through: 1.4, by: 0.5) {
                let forward = SIMD3<Float>(
                    cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))

                let (y, p) = yawPitch(of: forward)
                let orient = simd_quatf(angle: -y, axis: Axis.y) * simd_quatf(angle: p, axis: Axis.x)

                #expect(close(orient.act(Axis.forward), forward, 1e-3))

                // And the basis it implies is orthonormal, at every pitch.
                let (right, up, back) = (orient.act(Axis.x), orient.act(Axis.y), orient.act(Axis.z))
                #expect(simd_length(right) ~= 1)
                #expect(abs(simd_dot(right, up)) < 1e-4)
                #expect(abs(simd_dot(right, back)) < 1e-4)
                #expect(abs(simd_dot(up, back)) < 1e-4)
            }
        }
    }

    @Test func identityYawPitchLooksDownNegativeZ() {
        let (yaw, pitch) = yawPitch(of: Axis.forward)
        #expect(yaw ~= 0)
        #expect(pitch ~= 0)
    }

    @Test func perspectiveScaleIsWorldUnitsPerPixel() {
        // At distance d with fov 90°, the visible height is 2d, spread over `pixels` rows.
        #expect(perspectiveScale(distance: 5, fovYDegrees: 90, pixels: 100) ~= 0.1)
    }

    /// `matrixWorld` is camera-to-world; the SDK inverts it internally.
    @Test func matrixWorldIsCameraToWorld() {
        let camera = Camera()
        camera.position = SIMD3(1, 2, 3)
        camera.setAxes(right: Axis.x, up: Axis.y, back: Axis.z)
        #expect(close(camera.matrixWorld.transform(point: .zero), camera.position))
    }

}

// MARK: - Bounds

@Suite("Scene framing")
struct SceneFramingTests {
    @Test func fitFramesTheWholeBoxIntoTheFrustum() {
        let scene = SceneCamera()
        scene.aspect = 16.0 / 9
        let bbox = BoundingBox(min: SIMD3(-1, -2, -3), max: SIMD3(4, 5, 6))
        scene.setBBox(bbox)
        #expect(scene.isFramed)

        let view = scene.renderView(aspect: 16.0 / 9, viewHeightPoints: 800)
        let vp = view.projection * simd_inverse(view.cameraToWorld)
        for i in 0..<8 {
            let corner = SIMD3<Float>(
                i & 1 == 0 ? bbox.min.x : bbox.max.x,
                i & 2 == 0 ? bbox.min.y : bbox.max.y,
                i & 4 == 0 ? bbox.min.z : bbox.max.z)
            let clip = vp * SIMD4(corner, 1)
            #expect(clip.w > 0)
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            #expect(abs(ndc.x) <= 1 && abs(ndc.y) <= 1)
            #expect(ndc.z >= 0 && ndc.z <= 1)
        }
    }

    @Test func resetRestoresTheInitialFraming() {
        let scene = SceneCamera()
        scene.setBBox(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        let framed = scene.camera.position

        scene.input.addRotation(dx: 200, dy: 90)
        scene.zoom(4)
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
        #expect(!close(scene.camera.position, framed, 1e-2))

        scene.reset()
        #expect(close(scene.camera.position, framed, 1e-3))
    }

    /// A video stream reports an inverted box until its first frame decodes.
    @Test func invalidBoundingBoxDoesNotFrame() {
        let scene = SceneCamera()
        scene.setBBox(
            BoundingBox(
                min: SIMD3(repeating: .greatestFiniteMagnitude),
                max: SIMD3(repeating: .leastNormalMagnitude)))
        #expect(!scene.isFramed)
    }

    /// The projection's Z direction must match the pass's depth compare op.
    @Test func reverseZIsForwardedToTheProjection() {
        let scene = SceneCamera()
        scene.reverseZ = SplatsPassDescriptor.viewer.usesReverseZ
        #expect(scene.reverseZ)

        let view = scene.renderView(aspect: 1, viewHeightPoints: 100)
        // near maps to 1 under reverse-Z.
        let atNear = view.projection * SIMD4<Float>(0, 0, -scene.camera.near, 1)
        #expect(atNear.z / atNear.w ~= 1)
    }
}

// MARK: - Input

/// `CameraInput` is the whole host-facing input surface, and it speaks only in points, virtual key
/// codes and modifier flags — no AppKit type reaches this module.
///
/// The regressions here are the two ways held-key tracking used to break: matching keys by
/// character meant a non-Latin layout produced nothing at all, and a down/up character mismatch left
/// the key stuck in the held set with the camera still moving. Key codes are positional, so a key-up
/// always cancels the key-down before it.
@Suite("Input")
struct InputTests {
    /// Framed on a unit box, so `reach` is the framing distance and speed follows from it.
    private func makeFly() -> (SceneCamera, CameraInput) {
        let scene = SceneCamera()
        scene.setBBox(BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1)))
        return (scene, CameraInput(sceneCamera: scene))
    }

    /// Metres per second on the keys: the scene's radius crossed in ``K/travel`` seconds. Constant —
    /// it does not decay as the camera closes in. The unit box the tests frame on has radius √3.
    private let flySpeed = (3.0 as Float).squareRoot() / K.travel

    /// Distance travelled over one second of held keys.
    private func run(_ scene: SceneCamera, seconds: Double = 1) -> Float {
        let start = scene.camera.position
        for _ in 0..<Int(seconds * 60) { scene.update(dt: 1.0 / 60) }
        return simd_length(scene.camera.position - start)
    }

    @Test func moveKeysAreMatchedByPhysicalPosition() {
        #expect(MoveKey(keyCode: KeyCode.w) == .w)
        #expect(MoveKey(keyCode: KeyCode.a) == .a)
        #expect(MoveKey(keyCode: KeyCode.s) == .s)
        #expect(MoveKey(keyCode: KeyCode.d) == .d)
        #expect(MoveKey(keyCode: KeyCode.r) == .r)
        #expect(MoveKey(keyCode: KeyCode.f) == .f)
        // Command keys are not movement keys.
        #expect(MoveKey(keyCode: KeyCode.g) == nil)
        #expect(MoveKey(keyCode: KeyCode.space) == nil)
    }

    @Test func holdingForwardMovesAtTheStockSpeed() {
        let (scene, input) = makeFly()
        #expect(input.keyDown(keyCode: KeyCode.w))
        #expect(abs(run(scene) - flySpeed) < 0.02 * flySpeed)
    }

    @Test func keyUpStopsTheCamera() {
        let (scene, input) = makeFly()
        input.keyDown(keyCode: KeyCode.w)
        #expect(run(scene, seconds: 0.25) > 0)

        input.keyUp(keyCode: KeyCode.w)
        #expect(run(scene) == 0)  // released: not one unit of drift
    }

    /// macOS delivers no key-up while Command is held, so the held set must be dropped.
    @Test func commandModifierReleasesHeldKeys() {
        let (scene, input) = makeFly()
        input.keyDown(keyCode: KeyCode.w)
        input.modifiersChanged([.command])
        #expect(run(scene) == 0)
    }

    /// Losing focus (⌘-Tab, a modal open panel) is the other way key-up never arrives.
    @Test func releaseAllKeysStopsTheCamera() {
        let (scene, input) = makeFly()
        input.keyDown(keyCode: KeyCode.d)
        #expect(run(scene, seconds: 0.25) > 0)

        input.releaseAllKeys()
        #expect(run(scene) == 0)
    }

    @Test func shiftSprintsAndReleasesWithTheModifier() {
        let (scene, input) = makeFly()
        input.keyDown(keyCode: KeyCode.w)

        input.modifiersChanged([.shift])
        #expect(abs(run(scene) - flySpeed * 4) < 0.02 * flySpeed * 4)

        input.modifiersChanged([])
        #expect(abs(run(scene) - flySpeed) < 0.02 * flySpeed)
    }

    @Test func unknownKeysAreNotConsumed() {
        let (_, input) = makeFly()
        #expect(!input.keyDown(keyCode: KeyCode.g))
        #expect(!input.keyUp(keyCode: KeyCode.space))
    }

    // MARK: Pointer

    /// A bbox centred on the origin means the orbit target is the origin, so `|position|` is the
    /// orbit radius. (`camera.target` is not it: `setAxes` puts it one unit in front of the eye.)
    private func framedOrbit() -> (SceneCamera, CameraInput) {
        let scene = SceneCamera()
        let input = CameraInput(sceneCamera: scene)
        scene.setBBox(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        input.viewHeightChanged(800)
        return (scene, input)
    }

    private func back(_ scene: SceneCamera) -> SIMD3<Float> {
        let m = scene.camera.matrixWorld
        return SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    }

    private func settle(_ scene: SceneCamera) {
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
    }

    /// Orbiting swings the eye around the target: the view direction turns, the radius does not.
    @Test func primaryDragOrbits() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.camera.position)
        let viewDirection = back(scene)

        input.pointerDown(at: SIMD2(400, 400))
        input.pointerDragged(to: SIMD2(500, 400))
        input.pointerUp()
        settle(scene)

        #expect(!close(back(scene), viewDirection, 1e-2))
        #expect(abs(simd_length(scene.camera.position) - radius) < 1e-2)
    }

    /// Panning slides the target: the eye moves, the view direction does not. Both the secondary
    /// button and ⌥ + primary do it.
    @Test func secondaryDragPans() {
        for down: (CameraInput, SIMD2<Float>) -> Void in [
            { $0.pointerDown(at: $1, button: .secondary) },
            { $0.pointerDown(at: $1, button: .primary, modifiers: .option) },
        ] {
            let (scene, input) = framedOrbit()
            let position = scene.camera.position
            let viewDirection = back(scene)

            down(input, SIMD2(400, 400))
            input.pointerDragged(to: SIMD2(500, 400))
            input.pointerUp()
            settle(scene)

            #expect(close(back(scene), viewDirection, 1e-3))  // no rotation
            #expect(!close(scene.camera.position, position, 1e-2))
        }
    }

    /// A positive scroll delta (wheel away) zooms in. A wheel, not a trackpad — see below.
    @Test func scrollingUpZoomsIn() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.camera.position)

        input.scroll(deltaY: 1, precise: false)  // one notch
        settle(scene)
        #expect(simd_length(scene.camera.position) < radius - 1e-3)
    }

    /// A trackpad's two-finger slide pans rather than zooming. Panning slides the eye *across* the
    /// view; zooming would drive it along the view axis. So that is what separates them.
    @Test func twoFingerSlidePansRatherThanZooming() {
        let (scene, input) = framedOrbit()
        let position = scene.camera.position
        let viewAxis = back(scene)

        input.scroll(deltaX: 40, deltaY: 40, precise: true)
        settle(scene)

        let moved = scene.camera.position - position
        #expect(simd_length(moved) > 1e-2)
        #expect(close(back(scene), viewAxis, 1e-3))  // did not turn
        #expect(abs(simd_dot(simd_normalize(moved), viewAxis)) < 0.05)  // nor go in or out
    }

    /// ⌥ gets the zoom back on a trackpad, for anyone who does not want to pinch.
    @Test func optionScrollZoomsOnATrackpad() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.camera.position)

        input.scroll(deltaY: 100, precise: true, modifiers: .option)
        settle(scene)
        #expect(simd_length(scene.camera.position) < radius - 1e-3)
    }

    @Test func invertScrollZoomFlipsTheDirection() {
        let (scene, input) = framedOrbit()
        input.invertScrollZoom = true
        let radius = simd_length(scene.camera.position)

        input.scroll(deltaY: 100, precise: false)
        settle(scene)
        #expect(simd_length(scene.camera.position) > radius + 1e-3)
    }

    /// Wheel notches are ~100x coarser than trackpad pixel deltas.
    @Test func wheelNotchesZoomFurtherThanPixelDeltas() {
        func radiusAfterScroll(precise: Bool) -> Float {
            let (scene, input) = framedOrbit()
            input.scroll(deltaY: 1, precise: precise, modifiers: .option)
            settle(scene)
            return simd_length(scene.camera.position)
        }
        #expect(radiusAfterScroll(precise: false) < radiusAfterScroll(precise: true))
    }

    /// Pinching out (positive magnification) zooms in.
    @Test func pinchingOutZoomsIn() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.camera.position)

        input.magnify(1)  // scale factor 2
        settle(scene)
        #expect(simd_length(scene.camera.position) < radius - 1e-3)
    }

    @Test func dragWithoutPointerDownIsIgnored() {
        let (scene, input) = makeFly()
        let before = scene.camera.position
        input.pointerDragged(to: SIMD2(500, 400))
        for _ in 0..<60 { scene.update(dt: 1.0 / 60) }
        #expect(close(scene.camera.position, before))
    }
}
