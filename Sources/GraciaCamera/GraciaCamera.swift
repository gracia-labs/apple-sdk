//
//  One camera: eye + orientation. Public API is `SceneCamera` and `CameraInput`.
//

import GraciaSDK
import simd

// MARK: - Tuning

enum K {
    /// Radians of rotation per full view-height drag.
    static let rotate: Float = 2.5
    static let pan: Float = 1.6
    /// Trackpad deltas arrive pre-accelerated and keep coming through momentum after lift.
    static let scrollPan: Float = 0.3
    static let wheelZoom: Float = 0.0015

    /// Seconds to cross one scene radius; seeds a constant fly speed (decaying speed never arrives).
    /// The wheel trims it.
    static let travel: Float = 4.5
    static let flyTrim: (min: Float, max: Float) = (1.0 / 64, 64)
    static let boost: Float = 4
    /// Radians/sec on Q/E. No world up, so roll is how you level the horizon yourself — or tilt it.
    static let roll: Float = 1.4

    /// Two floors under `reach` (scene fractions): the orbit arc wants tight up close, the dolly step
    /// wants to stay big or zoom stalls just as it arrives.
    static let reachFloor: Float = 0.02
    static let dollyFloor: Float = 0.15
    /// Ceiling on `reach` — bounds how fast a gesture *grows*, not where the camera goes: the dolly
    /// step is a fraction of reach, so zooming out compounds and runs away.
    static let reachCeiling: Float = 1000
    static let nearFraction: Float = 0.002

    /// Cap on per-step `dt`. Slower frames still move *proportionally*; the cap only stops the first
    /// frame after an idle (dt up to 0.25s) from lurching.
    static let moveDtCap: Float = 1.0 / 20
    /// Inertia time constant, seconds.
    static let tau: Float = 0.022
    static let idle: Float = 1e-4
    static let defaultRadius: Float = 12
}

enum Axis {
    static let x = SIMD3<Float>(1, 0, 0)
    static let y = SIMD3<Float>(0, 1, 0)
    static let z = SIMD3<Float>(0, 0, 1)
    static let forward = SIMD3<Float>(0, 0, -1)
}

@inlinable
func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, v)) }

/// World units per pixel at `distance` — the pan gain.
@inlinable
func perspectiveScale(distance: Float, fovYDegrees: Float, pixels: Float) -> Float {
    2 * distance * tan(fovYDegrees * .pi / 360) / Swift.max(1, pixels)
}

@inlinable
func yawPitch(of forward: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
    (atan2(forward.x, -forward.z), asin(clamp(forward.y, -1, 1)))
}

/// World-space AABB of a transformed box — all 8 corners, since a rotated centre isn't the bounds
/// centre. Public so the host (owning the model matrix) can supply world bounds.
public func worldBounds(of bbox: BoundingBox, model: simd_float4x4) -> BoundingBox {
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for i in 0..<8 {
        let p = model.transform(
            point: SIMD3(
                i & 1 == 0 ? bbox.min.x : bbox.max.x,
                i & 2 == 0 ? bbox.min.y : bbox.max.y,
                i & 4 == 0 ? bbox.min.z : bbox.max.z))
        lo = simd_min(lo, p)
        hi = simd_max(hi, p)
    }
    return BoundingBox(min: lo, max: hi)
}

// MARK: - Camera

/// A pose plus a projection. `matrixWorld` is camera-to-world, as the SDK expects.
final class Camera {
    var position = SIMD3<Float>.zero
    var target = SIMD3<Float>.zero
    var up = Axis.y

    private(set) var matrixWorld = matrix_identity_float4x4
    private(set) var projectionMatrix = matrix_identity_float4x4

    var fov: Float = 60 { didSet { updateProjection() } }
    var aspect: Float = 1 { didSet { updateProjection() } }
    var near: Float = 0.05 { didSet { updateProjection() } }
    var far: Float = 10000 { didSet { updateProjection() } }
    var reverseZ = true { didSet { updateProjection() } }

    init() {
        updateProjection()
        matrixWorld = GraciaMatrix.cameraWorld(eye: position, target: target, up: up)
    }

    private func updateProjection() {
        projectionMatrix = GraciaMatrix.perspective(
            fovYDegrees: fov, aspect: aspect, near: near, far: far, reverseZ: reverseZ)
    }

    /// From a raw orthonormal basis (no `lookAt` cross products), so the camera can roll. `back`
    /// faces away from view.
    func setAxes(right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        self.up = up
        self.target = position - back
        matrixWorld = GraciaMatrix.cameraWorld(eye: position, right: right, up: up, back: back)
    }

    var renderView: RenderView {
        RenderView(projection: projectionMatrix, cameraToWorld: matrixWorld)
    }
}

// MARK: - Gestures

/// One frame's worth: rotation in radians, pan in points, zoom in log space.
struct GestureDelta {
    var rotX: Float = 0
    var rotY: Float = 0
    var panX: Float = 0
    var panY: Float = 0
    var zoom: Float = 0

    var isSettled: Bool { abs(rotX) + abs(rotY) + abs(panX) + abs(panY) + abs(zoom) < K.idle }

    static func += (l: inout GestureDelta, r: GestureDelta) {
        l.rotX += r.rotX; l.rotY += r.rotY; l.panX += r.panX; l.panY += r.panY; l.zoom += r.zoom
    }
    static func -= (l: inout GestureDelta, r: GestureDelta) {
        l.rotX -= r.rotX; l.rotY -= r.rotY; l.panX -= r.panX; l.panY -= r.panY; l.zoom -= r.zoom
    }
    static func * (l: GestureDelta, s: Float) -> GestureDelta {
        GestureDelta(
            rotX: l.rotX * s, rotY: l.rotY * s, panX: l.panX * s, panY: l.panY * s, zoom: l.zoom * s)
    }
}

/// Accumulates raw input, draining it on the render clock: frame-rate independent, with a short
/// tail after release.
final class GestureInput {
    /// View height in points; normalises rotation so drags feel size-independent.
    var height: Float = 1

    private var accumulated = GestureDelta()
    private var pending = GestureDelta()

    func addRotation(dx: Float, dy: Float) {
        let h = Swift.max(height, 1)
        accumulated.rotX += (dx / h) * K.rotate
        accumulated.rotY += (dy / h) * K.rotate
    }

    func addPan(dx: Float, dy: Float) {
        accumulated.panX += dx
        accumulated.panY += dy
    }

    /// Log space, so it composes additively.
    func addZoom(_ z: Float) { accumulated.zoom += z }

    func addScroll(deltaY: Float, precise: Bool) {
        addZoom(deltaY * (precise ? 1 : 100) * K.wheelZoom)
    }

    /// `m` is the relative delta (scale factor − 1).
    func addMagnification(_ m: Float) {
        guard m > -1 else { return }
        addZoom(log1p(m))
    }

    func reset() { pending = GestureDelta() }

    /// Critically damped: each frame takes `1 − exp(−dt/tau)` of what is outstanding.
    func drain(dt: Float) -> GestureDelta? {
        pending += accumulated
        accumulated = GestureDelta()
        guard !pending.isSettled else { return nil }
        let out = pending * (1 - exp(-dt / K.tau))
        pending -= out
        return out
    }
}

// MARK: - Keys

/// Positional virtual key codes (`kVK_ANSI_*`) — physical key, layout-independent.
public enum KeyCode {
    public static let a: UInt16 = 0
    public static let b: UInt16 = 11
    public static let s: UInt16 = 1
    public static let d: UInt16 = 2
    public static let f: UInt16 = 3
    public static let g: UInt16 = 5
    public static let m: UInt16 = 46
    public static let q: UInt16 = 12
    public static let w: UInt16 = 13
    public static let e: UInt16 = 14
    public static let r: UInt16 = 15
    public static let zero: UInt16 = 29
    public static let space: UInt16 = 49
}

enum MoveKey: Hashable {
    case w, a, s, d, r, f, q, e, shift

    init?(keyCode: UInt16) {
        switch keyCode {
        case KeyCode.w: self = .w
        case KeyCode.a: self = .a
        case KeyCode.s: self = .s
        case KeyCode.d: self = .d
        case KeyCode.r: self = .r
        case KeyCode.f: self = .f
        case KeyCode.q: self = .q
        case KeyCode.e: self = .e
        default: return nil
        }
    }
}

// MARK: - Scene camera

/// Rigid placement of a scene in the world.
public struct SceneTransform: Sendable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public init(
        translation: SIMD3<Float> = .zero,
        rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
        scale: SIMD3<Float> = SIMD3(repeating: 1)
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }
}

public final class SceneCamera {
    let camera = Camera()
    let input = GestureInput()

    private var eye = SIMD3<Float>.zero
    private var orient = simd_quatf(angle: 0, axis: Axis.y)
    private var keys: Set<MoveKey> = []

    private var sceneCentre = SIMD3<Float>.zero
    private var sceneRadius = K.defaultRadius
    /// Radius of the true box — what the far plane must clear, strays and all.
    private var fullRadius = K.defaultRadius
    private var flyTrim: Float = 1
    /// What `reset()` returns to.
    private var framing: (target: SIMD3<Float>, eye: SIMD3<Float>)?

    /// True once a scene has been framed; before that there is nothing to show.
    public private(set) var isFramed = false

    public init() { apply() }

    // MARK: Projection

    /// Must match the depth compare op of the pass being rendered.
    public var reverseZ: Bool {
        get { camera.reverseZ }
        set { camera.reverseZ = newValue }
    }

    public var fieldOfView: Float {
        get { camera.fov }
        set { camera.fov = newValue }
    }

    public var aspect: Float {
        get { camera.aspect }
        set { camera.aspect = newValue }
    }

    public func renderView(aspect: Float, viewHeightPoints: Float) -> RenderView {
        if aspect > 0, aspect.isFinite { camera.aspect = aspect }
        input.height = viewHeightPoints
        return camera.renderView
    }

    // MARK: Scene

    /// Frames the camera on world-space `bbox` (see `worldBounds(of:model:)`). `adaptive` is what it
    /// frames/moves/zooms at — without it stray splats shrink the scale to a speck; `bbox` still
    /// bounds the far plane. Invalid `bbox` un-frames. `reposition: false` updates only the movement
    /// scale, keeping a `place`d pose.
    public func setBBox(_ bbox: BoundingBox, adaptive: BoundingBox? = nil, reposition: Bool = true) {
        guard bbox.isValid else {
            isFramed = false
            return
        }
        frameScene(
            full: bbox, subject: adaptive.flatMap { $0.isValid ? $0 : nil } ?? bbox,
            reposition: reposition)
    }

    /// Places the camera at `eye` looking along `forward` (world-up implied, no roll). Reads nothing
    /// from the box, so a spawn can precede its scene. Leaves `isFramed` to `setBBox`; keep this pose
    /// past a settle with `reposition: false`.
    public func place(eye: SIMD3<Float>, forward: SIMD3<Float>) {
        let target = eye + normalized(forward, fallback: Axis.forward)
        framing = (target, eye)
        pose(target: target, eye: eye)
    }

    /// Current world pose, for copy/paste.
    public var eyePosition: SIMD3<Float> { eye }
    public var orientation: simd_quatf { orient }

    /// Like `place(eye:forward:)` but with a full orientation, so roll survives.
    public func place(eye: SIMD3<Float>, orientation: simd_quatf) {
        self.eye = eye
        orient = orientation
        framing = (eye + orientation.act(Axis.forward), eye)
        input.reset()
        apply()
    }

    public func reset() {
        guard let framing else { return }
        pose(target: framing.target, eye: framing.eye)
        isFramed = true
    }

    private func frameScene(full: BoundingBox, subject: BoundingBox, reposition: Bool) {
        sceneCentre = subject.center
        sceneRadius =
            subject.radius.isFinite && subject.radius > 0 ? subject.radius : K.defaultRadius
        fullRadius = Swift.max(full.radius, 1e-4)
        flyTrim = 1
        // Drawable now.
        isFramed = true

        // A `place`d scene (spawn) keeps its pose; scale alone is enough.
        guard reposition else { return }

        // Back off along +Z until the bounding sphere fits the tighter fov half-angle.
        let halfFovV = camera.fov * .pi / 360
        let halfFov = Swift.min(halfFovV, atan(tan(halfFovV) * Swift.max(camera.aspect, 1e-3)))
        let dist = subject.radius / sin(halfFov) * 1.05

        framing = (subject.center, subject.center + Axis.z * Swift.max(dist, 1e-3))
        reset()
    }

    // MARK: Motion

    /// True when the camera moved. Inertia adds a short tail after the gesture, so an on-demand host
    /// must schedule another frame.
    @discardableResult
    public func update(dt: Float) -> Bool {
        var moved = move(dt: dt)
        if let o = input.drain(dt: dt) {
            turn(dx: o.rotX, dy: o.rotY)
            // While flying, the wheel is the speed dial, not zoom (as in Unity/Unreal).
            if o.zoom != 0 {
                isFlying
                    ? flyTrim = clamp(flyTrim * exp(o.zoom), K.flyTrim.min, K.flyTrim.max)
                    : dolly(o.zoom)
            }
            if o.panX != 0 || o.panY != 0 { pan(o.panX, o.panY) }
            moved = true
        }
        if moved { apply() }
        return moved
    }

    /// Multiplicative: `factor > 1` moves closer.
    public func zoom(_ factor: Float) { if factor > 0 { input.addZoom(log(factor)) } }

    func setKeys(_ keys: Set<MoveKey>) { self.keys = keys }

    // MARK: Internals

    private var right: SIMD3<Float> { orient.act(Axis.x) }
    private var up: SIMD3<Float> { orient.act(Axis.y) }
    private var back: SIMD3<Float> { orient.act(Axis.z) }

    /// Shift alone is not flying.
    private var isFlying: Bool { !keys.subtracting([.shift]).isEmpty }

    /// Distance to the scene. Every gesture is a fraction of it, so scene size stops mattering and the
    /// camera can't be lost — drift out and each scroll grows, pulling you back.
    private var reach: Float {
        clamp(
            simd_distance(eye, sceneCentre),
            sceneRadius * K.reachFloor, sceneRadius * K.reachCeiling)
    }

    /// Metres per second on the keys: seeded by the scene, then trimmed by the wheel.
    private var flySpeed: Float { sceneRadius / K.travel * flyTrim }

    private func pose(target: SIMD3<Float>, eye: SIMD3<Float>) {
        self.eye = eye
        let angles = yawPitch(of: normalized(target - eye, fallback: Axis.forward))
        orient =
            simd_quatf(angle: -angles.yaw, axis: Axis.y)
            * simd_quatf(angle: angles.pitch, axis: Axis.x)
        input.reset()
        apply()
    }

    /// A trackball: one rotation from the camera's *own* axes, turning both camera and eye-offset. No
    /// world up, deliberately — avoids depending on the asset's export up (half are Z-up) and leaves
    /// no pole to clamp. Turns about the scene *centre* to preserve `|eye - centre|` exactly; a
    /// `reach`-based pivot would walk the camera outward every frame.
    private func turn(dx: Float, dy: Float) {
        guard dx != 0 || dy != 0 else { return }
        let rotation = (simd_quatf(angle: -dy, axis: right) * simd_quatf(angle: -dx, axis: up))
            .normalized

        orient = (rotation * orient).normalized
        eye = sceneCentre + rotation.act(eye - sceneCentre)
    }

    /// Broad from afar, fine up close. Its own floor, above the orbit arc's, or it stalls mid-scene
    /// where you were headed.
    private func dolly(_ amount: Float) {
        eye -= back * (amount * Swift.max(reach, sceneRadius * K.dollyFloor))
    }

    private func pan(_ px: Float, _ py: Float) {
        let s =
            perspectiveScale(distance: reach, fovYDegrees: camera.fov, pixels: input.height) * K.pan
        eye += right * (-px * s) + up * (py * s)
    }

    private func move(dt: Float) -> Bool {
        guard !keys.isEmpty else { return false }
        let step = Swift.min(dt, K.moveDtCap) * (keys.contains(.shift) ? K.boost : 1)
        var moved = false

        // Roll turns about the camera's own Z, so the eye does not move.
        var roll: Float = 0
        if keys.contains(.q) { roll -= K.roll * step }
        if keys.contains(.e) { roll += K.roll * step }
        if roll != 0 {
            orient = (orient * simd_quatf(angle: roll, axis: Axis.z)).normalized
            moved = true
        }

        var v = SIMD3<Float>.zero
        if keys.contains(.w) { v -= back }
        if keys.contains(.s) { v += back }
        if keys.contains(.d) { v += right }
        if keys.contains(.a) { v -= right }
        if keys.contains(.r) { v += up }
        if keys.contains(.f) { v -= up }
        if v != .zero {
            eye += simd_normalize(v) * (step * flySpeed)
            moved = true
        }
        return moved
    }

    /// No bounds on the camera, but the depth range must track the eye (not be fixed at load), or a
    /// camera that flew off would watch the scene get clipped.
    private func apply() {
        camera.position = eye
        camera.setAxes(right: right, up: up, back: back)

        let near = Swift.max(0.01, reach * K.nearFraction)
        let far = Swift.max(reach + fullRadius * 4, near * 1000)
        if abs(camera.near - near) > near * 0.05 { camera.near = near }
        if abs(camera.far - far) > far * 0.05 { camera.far = far }
    }
}

// MARK: - Input

public struct InputModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let option = InputModifiers(rawValue: 1 << 1)
    public static let command = InputModifiers(rawValue: 1 << 2)
}

public enum PointerButton: Sendable { case primary, secondary }

/// Turns pointer, scroll and key events into camera motion.
///
/// Host contract: pointer positions in **points, y down** (AppKit passes `bounds.height -
/// locationInView.y`); any path that can swallow a key-up (Command held, deactivation, focus loss)
/// must call `releaseAllKeys()`, or a key sticks and the camera keeps moving.
public final class CameraInput {
    private unowned let scene: SceneCamera
    private var lastPoint: SIMD2<Float>?
    private var dragIsPan = false
    private var keys: Set<MoveKey> = []

    /// Flip if scroll-to-zoom feels backwards on the host's pointing device.
    public var invertScrollZoom = false

    public init(sceneCamera: SceneCamera) { scene = sceneCamera }

    public func viewHeightChanged(_ points: Float) { scene.input.height = Swift.max(points, 1) }

    // MARK: Pointer

    public func pointerDown(
        at point: SIMD2<Float>, button: PointerButton = .primary, modifiers: InputModifiers = []
    ) {
        lastPoint = point
        dragIsPan = button == .secondary || modifiers.contains(.option)
    }

    public func pointerDragged(to point: SIMD2<Float>) {
        guard let last = lastPoint else { return }
        let d = point - last
        lastPoint = point
        dragIsPan
            ? scene.input.addPan(dx: d.x, dy: d.y)
            : scene.input.addRotation(dx: d.x, dy: d.y)
    }

    public func pointerUp() {
        lastPoint = nil
        dragIsPan = false
    }

    /// Trackpad: two-finger slide pans, pinch zooms. A wheel has no second axis, so it keeps zooming;
    /// ⌥ zooms either way. `precise` means trackpad rather than wheel.
    public func scroll(
        deltaX: Float = 0, deltaY: Float, precise: Bool, modifiers: InputModifiers = []
    ) {
        guard precise, !modifiers.contains(.option) else {
            return scene.input.addScroll(
                deltaY: invertScrollZoom ? -deltaY : deltaY, precise: precise)
        }
        scene.input.addPan(dx: deltaX * K.scrollPan, dy: deltaY * K.scrollPan)
    }

    public func magnify(_ magnification: Float) { scene.input.addMagnification(magnification) }

    // MARK: Keyboard

    /// True when the key was consumed as a movement key.
    @discardableResult
    public func keyDown(keyCode: UInt16) -> Bool {
        guard let key = MoveKey(keyCode: keyCode) else { return false }
        keys.insert(key)
        scene.setKeys(keys)
        return true
    }

    @discardableResult
    public func keyUp(keyCode: UInt16) -> Bool {
        guard let key = MoveKey(keyCode: keyCode) else { return false }
        keys.remove(key)
        scene.setKeys(keys)
        return true
    }

    public func modifiersChanged(_ modifiers: InputModifiers) {
        // macOS delivers no key-up while Command is held, so anything still down would stick.
        guard !modifiers.contains(.command) else { return releaseAllKeys() }
        if modifiers.contains(.shift) {
            keys.insert(.shift)
        } else {
            keys.remove(.shift)
        }
        scene.setKeys(keys)
    }

    public func releaseAllKeys() {
        keys.removeAll()
        scene.setKeys(keys)
    }
}
