//
//  Computes the *initial* placement of a scene — where it first appears, and where Recenter puts it —
//  before the hand gestures (see ``SpatialGestureController``) take over. The scene is normalized to a
//  graspable size and dropped a short distance in front of the viewer, so two-hand scaling starts from
//  something manageable regardless of the file's real-world scale.
//

import GraciaSDK
import simd

enum GesturePlacement {
    /// Model matrix placing the scene's bounds centre `distance` metres ahead of the head, normalized
    /// so its radius is about `targetRadius` metres, and dropped `drop` metres below eye level.
    static func initial(
        box: BoundingBox, head: simd_float4x4?, distance: Float = 1.2, targetRadius: Float = 0.5,
        drop: Float = 0.15
    ) -> simd_float4x4 {
        let center = box.isValid ? box.center : .zero
        let radius = box.isValid ? max(box.radius, 1e-3) : 1
        let s = targetRadius / radius

        let headPos = head.map(headPosition) ?? .zero
        let yaw = head.map(headYaw) ?? 0
        let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        let target = headPos + forward * distance + SIMD3(0, -drop, 0)

        // Rotate + scale about the scene's own centre, then place that centre at the target.
        let place = simd_float4x4(
            translation: target, rotation: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)),
            scale: SIMD3(repeating: s))
        let centerToOrigin = simd_float4x4(
            translation: -center, rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
            scale: SIMD3(repeating: 1))
        return place * centerToOrigin
    }

    /// Head position in world space, from a device-to-world (`originFromAnchorTransform`) matrix.
    static func headPosition(_ deviceToWorld: simd_float4x4) -> SIMD3<Float> {
        let c = deviceToWorld.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    /// Head yaw about vertical, from a device-to-world matrix; yaw 0 when the device looks along −Z.
    static func headYaw(_ deviceToWorld: simd_float4x4) -> Float {
        let forward = -SIMD3<Float>(
            deviceToWorld.columns.2.x, deviceToWorld.columns.2.y, deviceToWorld.columns.2.z)
        return atan2(-forward.x, -forward.z)
    }
}
