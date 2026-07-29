import GraciaSDK
import Testing
import simd

@testable import GraciaCamera

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-3) -> Bool {
    simd_length(a - b) < eps
}

/// Drains the gesture buffer for long enough that inertia has delivered essentially all of it.
private func settle(_ controls: SceneCamera) {
    for _ in 0..<200 { controls.update(dt: 1.0 / 60) }
}

@Suite("Controls")
struct ControlsTests {
    /// A scene centred on the origin, with the eye placed `distance` out along +Z looking back at
    /// it — so `|camera.position|` is simply how far off the scene the camera is.
    private func make(distance: Float = 4, sceneRadius: Float = 1) -> (SceneCamera, Camera) {
        let scene = SceneCamera()
        scene.input.height = 800
        // Half-extent chosen so the box's *radius* — half its diagonal — is `sceneRadius`.
        let half = sceneRadius / (3 as Float).squareRoot()
        scene.setBBox(BoundingBox(min: SIMD3(repeating: -half), max: SIMD3(repeating: half)))
        scene.place(eye: SIMD3(0, 0, distance), forward: SIMD3(0, 0, -1))
        return (scene, scene.camera)
    }

    @Test func framingPutsTheEyeWhereItWasAskedFor() {
        let (_, camera) = make(distance: 4)
        #expect(close(camera.position, SIMD3(0, 0, 4)))
        // Looking back down -Z at the pivot.
        #expect(close(simd_normalize(camera.target - camera.position), SIMD3(0, 0, -1)))
    }




    /// A trackball has no pole and no world up, so nothing clamps: drag straight up, over the top,
    /// and out the other side. Nothing goes bad, and the radius does not creep.
    @Test func rotationGoesOverTheTopAndKeepsItsRadius() {
        let (controls, camera) = make(distance: 4, sceneRadius: 1)

        controls.input.addRotation(dx: 0, dy: -4000)  // far past straight up
        settle(controls)

        #expect(camera.position.x.isFinite)
        #expect(camera.position.y.isFinite)
        #expect(camera.position.z.isFinite)
        #expect(abs(simd_length(camera.position) - 4) < 1e-3)
    }

    /// Movement and roll are frame-rate independent: a second is a second, whether it arrives in 30
    /// frames or 120. The cap on `dt` is a ceiling against a post-idle lurch, not a target frame
    /// time — set at 1/60 it silently halved the speed of every frame slower than 60 fps.
    @Test func movingAndRollingRespectDtAtAnyFrameRate() {
        func flownInOneSecond(fps: Int) -> Float {
            let (controls, camera) = make(distance: 12, sceneRadius: 12)
            let start = camera.position
            controls.setKeys([.w])
            for _ in 0..<fps { controls.update(dt: 1.0 / Float(fps)) }
            return simd_length(camera.position - start)
        }
        func rolledInOneSecond(fps: Int) -> Float {
            let (controls, camera) = make(distance: 12, sceneRadius: 12)
            let level = camera.up
            controls.setKeys([.q])
            for _ in 0..<fps { controls.update(dt: 1.0 / Float(fps)) }
            return acos(clamp(simd_dot(camera.up, level), -1, 1))
        }

        let fast = flownInOneSecond(fps: 120)
        for fps in [30, 60, 90] {
            #expect(abs(flownInOneSecond(fps: fps) - fast) < 0.02 * fast, "\(fps) fps flew wrong")
        }

        let spun = rolledInOneSecond(fps: 120)
        for fps in [30, 60, 90] {
            #expect(abs(rolledInOneSecond(fps: fps) - spun) < 0.02 * spun, "\(fps) fps rolled wrong")
        }
    }

    /// Q and E roll about the camera's own view axis. The eye does not move — that is what a roll
    /// is — and with no world up to keep the horizon level, this is how you level it yourself.
    @Test func rollTurnsTheCameraWithoutMovingIt() {
        let (controls, camera) = make(distance: 4, sceneRadius: 1)
        let from = camera.position
        let level = camera.up

        controls.setKeys([.q])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        #expect(close(camera.position, from, 1e-4), "roll moved the eye")
        #expect(simd_dot(camera.up, level) < 0.99, "roll did not tilt the horizon")

        // E rolls back the other way.
        controls.setKeys([.e])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])
        #expect(simd_dot(camera.up, level) > 0.99, "E did not undo Q")
    }

    /// The radius must not creep, even when the camera is not looking straight at the scene.
    ///
    /// It used to. The pivot was placed by `reach`, and `reach` is measured *from the eye* — so each
    /// frame of a drag moved the eye, which moved `reach`, which moved the pivot, and the camera
    /// walked further out with every frame. Rotating about the centre preserves the radius exactly.
    @Test func repeatedRotationOffCentreDoesNotDrift() {
        let (controls, camera) = make(distance: 4, sceneRadius: 1)

        controls.setKeys([.d])  // strafe, so the scene is no longer dead ahead
        for _ in 0..<120 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        let radius = simd_length(camera.position)
        for _ in 0..<8 {
            controls.input.addRotation(dx: 140, dy: 55)
            settle(controls)
            #expect(abs(simd_length(camera.position) - radius) < 1e-3, "the camera drifted")
        }
    }









    /// Dragging orbits the scene centre: the eye swings about it at a constant radius and a constant
    /// height, and the scene stays dead centre in the view and simply spins. A turntable.
    @Test func draggingOrbitsTheSceneCentre() {
        let (controls, camera) = make(distance: 4, sceneRadius: 1)
        let radius = simd_length(camera.position)
        let height = camera.position.y

        controls.input.addRotation(dx: 150, dy: 0)
        settle(controls)

        #expect(abs(simd_length(camera.position) - radius) < 1e-3)
        #expect(abs(camera.position.y - height) < 1e-3)
        #expect(camera.up.y > 0)

        // Still looking straight at the scene — it never left the middle of the view.
        let facing = simd_dot(
            simd_normalize(camera.target - camera.position), simd_normalize(-camera.position))
        #expect(facing > 0.999)
    }

    /// Flown inside the scene, the same drag turns your head rather than sweeping you round it —
    /// because what it turns about is now a couple of centimetres ahead, not the far side of the
    /// room. The arc tightens as you close in; nothing switches mode.
    @Test func draggingTurnsInPlaceOnceInsideTheScene() {
        let (far, farCamera) = make(distance: 4, sceneRadius: 1)
        let (near, nearCamera) = make(distance: 0.01, sceneRadius: 1)

        for (controls, camera) in [(far, farCamera), (near, nearCamera)] {
            let from = camera.position
            controls.input.addRotation(dx: 150, dy: 0)
            settle(controls)
            _ = from
        }

        // The same drag swings the eye a long way from a stand-off, and barely stirs it up close.
        let swung = simd_length(farCamera.position - SIMD3(0, 0, 4))
        let stirred = simd_length(nearCamera.position - SIMD3(0, 0, 0.01))
        #expect(swung > 1)
        #expect(stirred < 0.05)
    }



    /// Nothing fences the camera in. It may fly anywhere, in any direction — the boxes are guidance,
    /// not a cage.
    @Test func nothingBoundsTheCamera() {
        let (controls, camera) = make(distance: 4, sceneRadius: 1)

        controls.setKeys([.s, .shift])  // straight out, for a minute
        for _ in 0..<3600 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        #expect(simd_length(camera.position) > 40)  // long gone, and allowed to be
    }

    /// And having gone, it can always get back — because every gesture is a fraction of how far off
    /// the scene is, so the further out it drifts the *bigger* each scroll gets.
    @Test func aCameraThatDriftedFarAwayCanZoomItselfHome() {
        let (controls, camera) = make(distance: 1000, sceneRadius: 1)
        #expect(simd_length(camera.position) > 900)

        for _ in 0..<20 { controls.zoom(2); settle(controls) }

        #expect(simd_length(camera.position) < 10)  // home, in twenty notches
    }

    /// The camera can fly into the scene it is framed outside of — and straight on through it, and
    /// out the far side. Nothing fences it out of its own content, and nothing catches it on the way
    /// through. It used to: the bound was on the pivot, and the eye trailed `distance` behind it, so
    /// a scene wider than the framing distance could not be entered at all.
    @Test func flyingForwardPassesRightThroughTheScene() {
        let (controls, camera) = make(distance: 200, sceneRadius: 100)
        #expect(simd_length(camera.position) > 100)  // starts outside

        controls.setKeys([.w, .shift])
        var closest = Float.greatestFiniteMagnitude
        for _ in 0..<1800 {
            controls.update(dt: 1.0 / 60)
            closest = Swift.min(closest, simd_length(camera.position))
        }
        controls.setKeys([])

        #expect(closest < 1)  // went clean through the middle
        #expect(camera.position.z < -100)  // and out the far side, still going
    }

    /// One second on W flies a sixth of the way to what you are looking at, whatever "the way" is.
    private func flownInOneSecond(sceneRadius: Float, distance: Float) -> Float {
        let (controls, camera) = make(distance: distance, sceneRadius: sceneRadius)
        let start = camera.position

        controls.setKeys([.w])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        return simd_length(camera.position - start)
    }

    /// A doll's house and a city block fly the same: one second covers the same *fraction of the
    /// scene* in each. The scene seeds the speed — and then, within the scene, the speed is constant.
    @Test func flyingCoversTheSameFractionOfTheSceneWhateverTheScale() {
        for radius in [0.5 as Float, 12, 5000] {
            let flown = flownInOneSecond(sceneRadius: radius, distance: radius)
            #expect(abs(flown / radius - 1 / K.travel) < 0.01)
        }
    }

    /// Constant, emphatically: no decay as it closes in. Deceleration reads as a sticky camera that
    /// never arrives, which is why no editor does it.
    @Test func flyingDoesNotDecelerateAsItCloses() {
        let (controls, camera) = make(distance: 100, sceneRadius: 100)
        controls.setKeys([.w])

        func second() -> Float {
            let from = camera.position
            for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
            return simd_length(camera.position - from)
        }

        let first = second()
        _ = second()
        let third = second()
        #expect(abs(third - first) < 0.01 * first)
    }

    /// The wheel is the speed dial while the keys are down — the Unity/Unreal escape hatch.
    @Test func theWheelTrimsFlySpeedRatherThanZoomingWhileFlying() {
        // Roomy, so the flight does not reach the bound and confuse the measurement.
        let (controls, camera) = make(distance: 100, sceneRadius: 1000)
        controls.setKeys([.w])

        func second() -> Float {
            let from = camera.position
            for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
            return simd_length(camera.position - from)
        }

        let before = second()
        controls.input.addZoom(log(4))  // wind it up 4x
        for _ in 0..<10 { controls.update(dt: 1.0 / 60) }  // just enough to drain the wheel
        let after = second()

        #expect(after > before * 3)
        #expect(after < before * 5)
    }

    /// And it is the zoom again the moment the keys are up.
    @Test func theWheelZoomsWhenNotFlying() {
        let (controls, camera) = make(distance: 4)
        controls.zoom(2)
        settle(controls)
        #expect(simd_length(camera.position) < 4)
    }





}

extension SIMD4 where Scalar == Float {
    fileprivate var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
