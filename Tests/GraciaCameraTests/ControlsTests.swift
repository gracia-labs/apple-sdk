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
    private func make(distance: Float = 4, sceneRadius: Float = 1) -> SceneCamera {
        let scene = SceneCamera()
        scene.setViewHeight(800)
        let half = sceneRadius / (3 as Float).squareRoot()
        scene.setBBox(BoundingBox(min: SIMD3(repeating: -half), max: SIMD3(repeating: half)))
        scene.place(eye: SIMD3(0, 0, distance), forward: SIMD3(0, 0, -1))
        return scene
    }

    @Test func framingPutsTheEyeWhereItWasAskedFor() {
        let camera = make(distance: 4)
        #expect(close(camera.eyePosition, SIMD3(0, 0, 4)))
        #expect(close(camera.orientation.act(Axis.forward), SIMD3(0, 0, -1)))
    }

    @Test func rotationGoesOverTheTopAndKeepsItsRadius() {
        let controls = make(distance: 4, sceneRadius: 1)

        controls.addRotation(dx: 0, dy: -4000)
        settle(controls)

        #expect(controls.eyePosition.x.isFinite)
        #expect(controls.eyePosition.y.isFinite)
        #expect(controls.eyePosition.z.isFinite)
        #expect(abs(simd_length(controls.eyePosition) - 4) < 1e-3)
    }

    @Test func movingAndRollingRespectDtAtAnyFrameRate() {
        func flownInOneSecond(fps: Int) -> Float {
            let controls = make(distance: 12, sceneRadius: 12)
            let start = controls.eyePosition
            controls.setKeys([.w])
            for _ in 0..<fps { controls.update(dt: 1.0 / Float(fps)) }
            return simd_length(controls.eyePosition - start)
        }
        func rolledInOneSecond(fps: Int) -> Float {
            let controls = make(distance: 12, sceneRadius: 12)
            let level = controls.orientation.act(Axis.y)
            controls.setKeys([.q])
            for _ in 0..<fps { controls.update(dt: 1.0 / Float(fps)) }
            return acos(clamp(simd_dot(controls.orientation.act(Axis.y), level), -1, 1))
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

    @Test func rollTurnsTheCameraWithoutMovingIt() {
        let controls = make(distance: 4, sceneRadius: 1)
        let from = controls.eyePosition
        let level = controls.orientation.act(Axis.y)

        controls.setKeys([.q])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        #expect(close(controls.eyePosition, from, 1e-4), "roll moved the eye")
        #expect(simd_dot(controls.orientation.act(Axis.y), level) < 0.99, "roll did not tilt the horizon")

        controls.setKeys([.e])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])
        #expect(simd_dot(controls.orientation.act(Axis.y), level) > 0.99, "E did not undo Q")
    }

    @Test func repeatedRotationOffCentreDoesNotDrift() {
        let controls = make(distance: 4, sceneRadius: 1)

        controls.setKeys([.d])
        for _ in 0..<120 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        let radius = simd_length(controls.eyePosition)
        for _ in 0..<8 {
            controls.addRotation(dx: 140, dy: 55)
            settle(controls)
            #expect(abs(simd_length(controls.eyePosition) - radius) < 1e-3, "the camera drifted")
        }
    }

    @Test func draggingOrbitsTheSceneCentre() {
        let controls = make(distance: 4, sceneRadius: 1)
        let radius = simd_length(controls.eyePosition)
        let height = controls.eyePosition.y

        controls.addRotation(dx: 150, dy: 0)
        settle(controls)

        #expect(abs(simd_length(controls.eyePosition) - radius) < 1e-3)
        #expect(abs(controls.eyePosition.y - height) < 1e-3)
        #expect(controls.orientation.act(Axis.y).y > 0)

        let facing = simd_dot(controls.orientation.act(Axis.forward), simd_normalize(-controls.eyePosition))
        #expect(facing > 0.999)
    }

    @Test func draggingTurnsInPlaceOnceInsideTheScene() {
        let far = make(distance: 4, sceneRadius: 1)
        let near = make(distance: 0.01, sceneRadius: 1)

        for controls in [far, near] {
            controls.addRotation(dx: 150, dy: 0)
            settle(controls)
        }

        #expect(simd_length(far.eyePosition - SIMD3(0, 0, 4)) > 1)
        #expect(simd_length(near.eyePosition - SIMD3(0, 0, 0.01)) < 0.05)
    }

    @Test func nothingBoundsTheCamera() {
        let controls = make(distance: 4, sceneRadius: 1)

        controls.setKeys([.s, .shift])
        for _ in 0..<3600 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        #expect(simd_length(controls.eyePosition) > 40)
    }

    @Test func aCameraThatDriftedFarAwayCanZoomItselfHome() {
        let controls = make(distance: 1000, sceneRadius: 1)
        #expect(simd_length(controls.eyePosition) > 900)

        for _ in 0..<20 { controls.zoom(2); settle(controls) }

        #expect(simd_length(controls.eyePosition) < 10)
    }

    @Test func flyingForwardPassesRightThroughTheScene() {
        let controls = make(distance: 200, sceneRadius: 100)
        #expect(simd_length(controls.eyePosition) > 100)

        controls.setKeys([.w, .shift])
        var closest = Float.greatestFiniteMagnitude
        for _ in 0..<1800 {
            controls.update(dt: 1.0 / 60)
            closest = Swift.min(closest, simd_length(controls.eyePosition))
        }
        controls.setKeys([])

        #expect(closest < 1)
        #expect(controls.eyePosition.z < -100)
    }

    private func flownInOneSecond(sceneRadius: Float, distance: Float) -> Float {
        let controls = make(distance: distance, sceneRadius: sceneRadius)
        let start = controls.eyePosition

        controls.setKeys([.w])
        for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
        controls.setKeys([])

        return simd_length(controls.eyePosition - start)
    }

    @Test func flyingCoversTheSameFractionOfTheSceneWhateverTheScale() {
        for radius in [0.5 as Float, 12, 5000] {
            let flown = flownInOneSecond(sceneRadius: radius, distance: radius)
            #expect(abs(flown / radius - 1 / K.travel) < 0.01)
        }
    }

    @Test func flyingDoesNotDecelerateAsItCloses() {
        let controls = make(distance: 100, sceneRadius: 100)
        controls.setKeys([.w])

        func second() -> Float {
            let from = controls.eyePosition
            for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
            return simd_length(controls.eyePosition - from)
        }

        let first = second()
        _ = second()
        let third = second()
        #expect(abs(third - first) < 0.01 * first)
    }

    @Test func theWheelTrimsFlySpeedRatherThanZoomingWhileFlying() {
        let controls = make(distance: 100, sceneRadius: 1000)
        controls.setKeys([.w])

        func second() -> Float {
            let from = controls.eyePosition
            for _ in 0..<60 { controls.update(dt: 1.0 / 60) }
            return simd_length(controls.eyePosition - from)
        }

        let before = second()
        controls.addZoom(log(4))
        for _ in 0..<10 { controls.update(dt: 1.0 / 60) }
        let after = second()

        #expect(after > before * 3)
        #expect(after < before * 5)
    }

    @Test func theWheelZoomsWhenNotFlying() {
        let controls = make(distance: 4)
        controls.zoom(2)
        settle(controls)
        #expect(simd_length(controls.eyePosition) < 4)
    }
}
