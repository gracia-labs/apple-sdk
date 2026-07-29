//
//  Two-handed spatial manipulation of the scene, ported from the production app
//  (VisionSceneRenderer.SpatialGestureController). One-hand pinch-drag pans; two-hand pinch scales
//  and rotates about vertical while following the midpoint. The scene's model matrix is driven
//  entirely by these gestures — there are no on-screen placement controls.
//
//  Threading: `handleSpatialEvents` runs on the main actor (from `layerRenderer.onSpatialEvent`) and
//  only writes a lock-guarded snapshot of the live pinch positions. `update()` runs on the render
//  thread each frame and applies them; the model matrix is otherwise render-thread-confined.
//

import SwiftUI
import os
import simd

final class SpatialGestureController: @unchecked Sendable {

    // MARK: Cross-thread pinch snapshot (main → render)

    private struct PinchSnapshot {
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
    }
    private let pinchLock = OSAllocatedUnfairLock(initialState: PinchSnapshot())

    // MARK: Model matrix (render-thread confined)

    private var currentModelMatrix = matrix_identity_float4x4

    private enum GestureState {
        case idle
        case oneHandDrag(pinch: SIMD3<Float>)
        case twoHand(midpoint: SIMD3<Float>, distance: Float, angle: Float, startMatrix: simd_float4x4)
    }
    private var state: GestureState = .idle
    private var smoothedPinch: SIMD3<Float>?
    private let smoothing: Float = 0.45

    /// Pan / scale can be pinned individually; both are free by default.
    var lockPosition = false
    var lockScale = false

    // MARK: - Main actor: spatial events

    /// Records the active pinch position per hand into the shared snapshot. The event collection is
    /// the full current set, so overwriting per call is correct — a hand that stops pinching drops out.
    func handleSpatialEvents(_ events: SpatialEventCollection) {
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
        for event in events {
            guard event.kind == .indirectPinch || event.kind == .directPinch else { continue }
            guard event.phase == .active else { continue }
            let pos = Self.position(of: event)
            if event.chirality == .left { left = pos }
            else if event.chirality == .right { right = pos }
        }
        let (l, r) = (left, right)
        pinchLock.withLock { $0.left = l; $0.right = r }
    }

    private static func position(of event: SpatialEventCollection.Event) -> SIMD3<Float> {
        if let pose = event.inputDevicePose {
            let p = pose.pose3D.position
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let p = event.location3D
        return SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    // MARK: - Render thread: apply each frame

    func update() {
        let snap = pinchLock.withLock { $0 }
        switch (snap.left, snap.right) {
        case let (.some(l), .some(r)): applyTwoHand(left: l, right: r)
        case let (.some(p), .none): applyOneHand(p)
        case let (.none, .some(p)): applyOneHand(p)
        case (.none, .none): state = .idle; smoothedPinch = nil
        }
    }

    private func applyOneHand(_ pos: SIMD3<Float>) {
        if lockPosition { state = .oneHandDrag(pinch: pos); smoothedPinch = nil; return }
        let smoothed = smoothedPinch.map { simd_mix($0, pos, SIMD3(repeating: smoothing)) } ?? pos
        smoothedPinch = smoothed
        if case .oneHandDrag(let prev) = state {
            currentModelMatrix = translation(smoothed - prev) * currentModelMatrix
        }
        state = .oneHandDrag(pinch: smoothed)
    }

    private func applyTwoHand(left: SIMD3<Float>, right: SIMD3<Float>) {
        let mid = (left + right) * 0.5
        let dist = simd_distance(left, right)
        let angle = atan2(right.x - left.x, right.z - left.z)
        guard case .twoHand(let mid0, let dist0, let angle0, let start) = state else {
            state = .twoHand(midpoint: mid, distance: dist, angle: angle, startMatrix: currentModelMatrix)
            return
        }
        let scaleRatio = lockScale ? 1 : dist / max(dist0, 0.001)
        // Scale + rotate about the gesture's start midpoint, then follow the hands' current midpoint.
        let recenter = lockPosition ? translation(mid0) : translation(mid)
        currentModelMatrix = recenter * rotationY(angle - angle0) * scale(scaleRatio) * translation(-mid0) * start
    }

    // MARK: - Placement / read

    func resetToMatrix(_ m: simd_float4x4) {
        currentModelMatrix = m
        state = .idle
        smoothedPinch = nil
        pinchLock.withLock { $0.left = nil; $0.right = nil }
    }

    var modelMatrix: simd_float4x4 { currentModelMatrix }
}

// MARK: - Matrix helpers

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t, 1)
    return m
}

private func scale(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, s, s, 1))
}

private func rotationY(_ radians: Float) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)))
}
