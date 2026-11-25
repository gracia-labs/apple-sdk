import GraciaSDK
import Testing
import simd

@testable import GraciaCamera

private func ~= (a: Float, b: Float) -> Bool { abs(a - b) < 1e-4 }
private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    simd_length(a - b) < eps
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
        let framed = scene.eyePosition

        scene.addRotation(dx: 200, dy: 90)
        scene.zoom(4)
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
        #expect(!close(scene.eyePosition, framed, 1e-2))

        scene.reset()
        #expect(close(scene.eyePosition, framed, 1e-3))
    }

    /// A display viewpoint can roll; `reset` must bring the roll back, not only the direction.
    @Test func resetRestoresAPlacedRoll() {
        let scene = SceneCamera()
        scene.setBBox(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        let eye = SIMD3<Float>(0.5, 1, 4)
        let turn = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3(0.2, 1, 0.3)))
        scene.place(eye: eye, orientation: turn)

        scene.addRotation(dx: 200, dy: 90)
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
        scene.reset()

        #expect(close(scene.eyePosition, eye, 1e-4))
        #expect(close(scene.orientation.act(Axis.y), turn.act(Axis.y), 1e-4))
        #expect(close(scene.orientation.act(Axis.forward), turn.act(Axis.forward), 1e-4))
    }

    /// A viewpoint states the scene's own space; the scene transform moves it and turns it, and its
    /// scale moves the eye but leaves the turn alone.
    @Test func worldPoseFollowsTheSceneTransform() {
        let pose = Pose(position: SIMD3(1, 2, 3), rotation: simd_quatf(angle: 0.3, axis: Axis.x))
        let rotation = simd_quatf(angle: .pi / 2, axis: Axis.y)
        let model = simd_float4x4(translation: SIMD3(10, 0, 0), rotation: rotation, scale: SIMD3(repeating: 2))

        let world = worldPose(of: pose, model: model)

        #expect(close(world.position, model.transform(point: pose.position)))
        #expect(close(world.rotation.act(Axis.forward), (rotation * pose.rotation).act(Axis.forward)))
        #expect(close(world.rotation.act(Axis.y), (rotation * pose.rotation).act(Axis.y)))
    }

    /// A `.grv` can state a pivot off the centre of its box: the camera frames the box about the pivot,
    /// and a turn keeps the eye at its distance from the pivot.
    @Test func turnsAboutThePivot() {
        let scene = SceneCamera()
        let pivot = SIMD3<Float>(0.5, -0.25, 0.75)
        scene.setBBox(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)), pivot: pivot)
        let framed = scene.eyePosition
        #expect(close(SIMD3(framed.x, framed.y, 0), SIMD3(pivot.x, pivot.y, 0)))
        #expect(close(scene.orientation.act(Axis.forward), Axis.forward))

        let distance = simd_length(framed - pivot)
        scene.addRotation(dx: 200, dy: 90)
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
        #expect(!close(scene.eyePosition, framed, 1e-2))
        #expect(abs(simd_length(scene.eyePosition - pivot) - distance) < 1e-3 * distance)
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
        let atNear = view.projection * SIMD4<Float>(0, 0, -scene.nearPlane, 1)
        #expect(atNear.z / atNear.w ~= 1)
    }
}

// MARK: - Input

@Suite("Input")
struct InputTests {
    private func makeFly() -> (SceneCamera, CameraInput) {
        let scene = SceneCamera()
        scene.setBBox(BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1)))
        return (scene, CameraInput(sceneCamera: scene))
    }

    private let flySpeed = (3.0 as Float).squareRoot() / K.travel

    private func run(_ scene: SceneCamera, seconds: Double = 1) -> Float {
        let start = scene.eyePosition
        for _ in 0..<Int(seconds * 60) { scene.update(dt: 1.0 / 60) }
        return simd_length(scene.eyePosition - start)
    }

    @Test func moveKeysAreMatchedByPhysicalPosition() {
        #expect(MoveKey(keyCode: KeyCode.w) == .w)
        #expect(MoveKey(keyCode: KeyCode.a) == .a)
        #expect(MoveKey(keyCode: KeyCode.s) == .s)
        #expect(MoveKey(keyCode: KeyCode.d) == .d)
        #expect(MoveKey(keyCode: KeyCode.r) == .r)
        #expect(MoveKey(keyCode: KeyCode.f) == .f)
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
        #expect(run(scene) == 0)
    }

    @Test func commandModifierReleasesHeldKeys() {
        let (scene, input) = makeFly()
        input.keyDown(keyCode: KeyCode.w)
        input.modifiersChanged([.command])
        #expect(run(scene) == 0)
    }

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

    private func framedOrbit() -> (SceneCamera, CameraInput) {
        let scene = SceneCamera()
        let input = CameraInput(sceneCamera: scene)
        scene.setBBox(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        input.viewHeightChanged(800)
        return (scene, input)
    }

    private func back(_ scene: SceneCamera) -> SIMD3<Float> { scene.orientation.act(Axis.z) }

    private func settle(_ scene: SceneCamera) {
        for _ in 0..<200 { scene.update(dt: 1.0 / 60) }
    }

    @Test func primaryDragOrbits() {
        let (scene, input) = framedOrbit()
        let startEye = scene.eyePosition
        let radius = simd_length(startEye)
        let viewDirection = back(scene)

        input.pointerDown(at: SIMD2(400, 400))
        input.pointerDragged(to: SIMD2(500, 400))
        input.pointerUp()
        settle(scene)

        #expect(!close(back(scene), viewDirection, 1e-2))
        #expect(!close(scene.eyePosition, startEye, 1e-2))
        #expect(abs(simd_length(scene.eyePosition) - radius) < 1e-2)
    }

    @Test func freeLookDragTurnsInPlace() {
        let (scene, input) = framedOrbit()
        scene.freeLook = true
        let position = scene.eyePosition
        let viewDirection = back(scene)

        input.pointerDown(at: SIMD2(400, 400))
        input.pointerDragged(to: SIMD2(500, 350))
        input.pointerUp()
        settle(scene)

        #expect(close(scene.eyePosition, position, 1e-4))
        #expect(!close(back(scene), viewDirection, 1e-2))
        let forward = scene.orientation.act(Axis.forward)
        #expect(forward.x > 0.1)
        #expect(forward.y > 0.05)
        #expect(abs(scene.orientation.act(Axis.x).y) < 1e-4)
    }

    @Test func secondaryDragPans() {
        for down: (CameraInput, SIMD2<Float>) -> Void in [
            { $0.pointerDown(at: $1, button: .secondary) },
            { $0.pointerDown(at: $1, button: .primary, modifiers: .option) },
        ] {
            let (scene, input) = framedOrbit()
            let position = scene.eyePosition
            let viewDirection = back(scene)

            down(input, SIMD2(400, 400))
            input.pointerDragged(to: SIMD2(500, 400))
            input.pointerUp()
            settle(scene)

            #expect(close(back(scene), viewDirection, 1e-3))
            #expect(!close(scene.eyePosition, position, 1e-2))
        }
    }

    @Test func scrollingUpZoomsIn() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.eyePosition)

        input.scroll(deltaY: 1, precise: false)
        settle(scene)
        #expect(simd_length(scene.eyePosition) < radius - 1e-3)
    }

    @Test func twoFingerSlidePansRatherThanZooming() {
        let (scene, input) = framedOrbit()
        let position = scene.eyePosition
        let viewAxis = back(scene)

        input.scroll(deltaX: 40, deltaY: 40, precise: true)
        settle(scene)

        let moved = scene.eyePosition - position
        #expect(simd_length(moved) > 1e-2)
        #expect(close(back(scene), viewAxis, 1e-3))
        #expect(abs(simd_dot(simd_normalize(moved), viewAxis)) < 0.05)
    }

    @Test func optionScrollZoomsOnATrackpad() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.eyePosition)

        input.scroll(deltaY: 100, precise: true, modifiers: .option)
        settle(scene)
        #expect(simd_length(scene.eyePosition) < radius - 1e-3)
    }

    @Test func invertScrollZoomFlipsTheDirection() {
        let (scene, input) = framedOrbit()
        input.invertScrollZoom = true
        let radius = simd_length(scene.eyePosition)

        input.scroll(deltaY: 100, precise: false)
        settle(scene)
        #expect(simd_length(scene.eyePosition) > radius + 1e-3)
    }

    @Test func wheelNotchesZoomFurtherThanPixelDeltas() {
        func radiusAfterScroll(precise: Bool) -> Float {
            let (scene, input) = framedOrbit()
            input.scroll(deltaY: 1, precise: precise, modifiers: .option)
            settle(scene)
            return simd_length(scene.eyePosition)
        }
        #expect(radiusAfterScroll(precise: false) < radiusAfterScroll(precise: true))
    }

    @Test func pinchingOutZoomsIn() {
        let (scene, input) = framedOrbit()
        let radius = simd_length(scene.eyePosition)

        input.magnify(1)
        settle(scene)
        #expect(simd_length(scene.eyePosition) < radius - 1e-3)
    }

    @Test func dragWithoutPointerDownIsIgnored() {
        let (scene, input) = makeFly()
        let before = scene.eyePosition
        input.pointerDragged(to: SIMD2(500, 400))
        for _ in 0..<60 { scene.update(dt: 1.0 / 60) }
        #expect(close(scene.eyePosition, before))
    }
}
