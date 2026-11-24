//
//  Swift wrapper over `gracia_camera_*` in the C SDK, plus platform-independent pointer/key input.
//

import GraciaSDK
import gracia_sdk
import simd

enum K {
    /// Trackpad two-finger scroll pan scale; deltas arrive pre-accelerated.
    static let scrollPan: Float = 0.3
    /// Seconds to cross one scene radius (kept in sync with `src/shared/camera/SceneCamera.cpp`).
    static let travel: Float = 4.5
}

enum Axis {
    static let x = SIMD3<Float>(1, 0, 0)
    static let y = SIMD3<Float>(0, 1, 0)
    static let z = SIMD3<Float>(0, 0, 1)
    static let forward = SIMD3<Float>(0, 0, -1)
}

@inlinable
func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(hi, Swift.max(lo, v)) }

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

/// A pose of a scene's own space in the world: `model` moves the position as a point and turns the
/// rotation, its scale left out. Public beside `worldBounds` for the same host.
public func worldPose(of pose: Pose, model: simd_float4x4) -> Pose {
    let axis = { (c: SIMD4<Float>) in simd_normalize(SIMD3(c.x, c.y, c.z)) }
    let turn = simd_quatf(simd_float3x3(axis(model.columns.0), axis(model.columns.1), axis(model.columns.2)))
    return Pose(position: model.transform(point: pose.position), rotation: (turn * pose.rotation).normalized)
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

    var bit: UInt32 {
        switch self {
        case .w: UInt32(GRACIA_CAMERA_KEY_W.rawValue)
        case .a: UInt32(GRACIA_CAMERA_KEY_A.rawValue)
        case .s: UInt32(GRACIA_CAMERA_KEY_S.rawValue)
        case .d: UInt32(GRACIA_CAMERA_KEY_D.rawValue)
        case .r: UInt32(GRACIA_CAMERA_KEY_R.rawValue)
        case .f: UInt32(GRACIA_CAMERA_KEY_F.rawValue)
        case .q: UInt32(GRACIA_CAMERA_KEY_Q.rawValue)
        case .e: UInt32(GRACIA_CAMERA_KEY_E.rawValue)
        case .shift: UInt32(GRACIA_CAMERA_KEY_SHIFT.rawValue)
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
    private let raw: UnsafeMutableRawPointer

    public init() {
        // Metal clip space: +Y up (`flipY: false`), reverse-Z by default.
        raw = gracia_camera_create(true, false)!
    }

    deinit { gracia_camera_destroy(raw) }

    // MARK: Projection

    /// Must match the depth compare op of the pass being rendered.
    public var reverseZ: Bool {
        get { gracia_camera_reverse_z(raw) }
        set { gracia_camera_set_reverse_z(raw, newValue) }
    }

    public var fieldOfView: Float {
        get { gracia_camera_fov(raw) }
        set { gracia_camera_set_fov(raw, newValue) }
    }

    public var aspect: Float {
        get { gracia_camera_aspect(raw) }
        set { gracia_camera_set_aspect(raw, newValue) }
    }

    /// True once a scene has been framed; before that there is nothing to show.
    public var isFramed: Bool { gracia_camera_is_framed(raw) }

    /// Current world pose, for copy/paste.
    public var eyePosition: SIMD3<Float> {
        let p = gracia_camera_pose(raw).position
        return SIMD3(p.0, p.1, p.2)
    }

    public var orientation: simd_quatf {
        let r = gracia_camera_pose(raw).rotation
        return simd_quatf(ix: r.0, iy: r.1, iz: r.2, r: r.3)
    }

    var nearPlane: Float {
        var n: Float = 0
        gracia_camera_near_far(raw, &n, nil)
        return n
    }

    public func renderView(aspect: Float, viewHeightPoints: Float) -> RenderView {
        let v = gracia_camera_render_view(raw, aspect, viewHeightPoints)
        return RenderView(
            projection: Self.matrix(from: v.projection),
            cameraToWorld: Self.matrix(from: v.cameraToWorld))
    }

    // MARK: Scene

    /// Frames the camera on world-space `bbox` (see `worldBounds(of:model:)`). `adaptive` is what it
    /// frames/moves/zooms at; `bbox` bounds the far plane. `pivot` is the world point that the camera
    /// frames about and turns about. Invalid `bbox` un-frames. `reposition: false` keeps a `place`d pose.
    public func setBBox(
        _ bbox: BoundingBox, adaptive: BoundingBox? = nil, pivot: SIMD3<Float>? = nil, reposition: Bool = true
    ) {
        let full = Self.cBox(bbox)
        let call = { (aPtr: UnsafePointer<GraciaBBox>?) in
            if let pivot {
                [pivot.x, pivot.y, pivot.z].withUnsafeBufferPointer {
                    gracia_camera_set_bbox(self.raw, full, aPtr, $0.baseAddress, reposition)
                }
            } else {
                gracia_camera_set_bbox(self.raw, full, aPtr, nil, reposition)
            }
        }
        if var adapt = adaptive.flatMap({ $0.isValid ? Self.cBox($0) : nil }) {
            withUnsafePointer(to: &adapt, call)
        } else {
            call(nil)
        }
    }

    /// Places the camera at `eye` looking along `forward` (world-up implied, no roll).
    public func place(eye: SIMD3<Float>, forward: SIMD3<Float>) {
        let e: [Float] = [eye.x, eye.y, eye.z]
        let f: [Float] = [forward.x, forward.y, forward.z]
        e.withUnsafeBufferPointer { ep in
            f.withUnsafeBufferPointer { fp in
                gracia_camera_place_forward(raw, ep.baseAddress, fp.baseAddress)
            }
        }
    }

    /// Like `place(eye:forward:)` but with a full orientation, so roll survives, also through `reset()`.
    public func place(eye: SIMD3<Float>, orientation: simd_quatf) {
        let q = orientation.normalized.vector
        gracia_camera_place(raw, GraciaPose(position: (eye.x, eye.y, eye.z), rotation: (q.x, q.y, q.z, q.w)))
    }

    /// Moves the pivot with the subspace of a portal from the last rendered frame.
    public func follow(_ move: simd_float4x4) {
        let cols = move.columnMajor
        cols.withUnsafeBufferPointer { gracia_camera_follow(raw, $0.baseAddress) }
    }

    public func reset() { gracia_camera_reset(raw) }

    // MARK: Motion

    /// True when the camera moved. Inertia adds a short tail after the gesture, so an on-demand host
    /// must schedule another frame.
    @discardableResult
    public func update(dt: Float) -> Bool { gracia_camera_update(raw, dt) }

    /// Multiplicative: `factor > 1` moves closer.
    public func zoom(_ factor: Float) { if factor > 0 { gracia_camera_add_zoom(raw, log(factor)) } }

    func setViewHeight(_ points: Float) { gracia_camera_set_view_height(raw, points) }
    func addRotation(dx: Float, dy: Float) { gracia_camera_add_rotation(raw, dx, dy) }
    func addPan(dx: Float, dy: Float) { gracia_camera_add_pan(raw, dx, dy) }
    func addZoom(_ logDelta: Float) { gracia_camera_add_zoom(raw, logDelta) }
    func addScroll(deltaY: Float, precise: Bool) { gracia_camera_add_scroll(raw, deltaY, precise) }
    func addMagnification(_ m: Float) { if m > -1 { gracia_camera_add_zoom(raw, log1p(m)) } }
    func setKeys(_ keys: Set<MoveKey>) {
        gracia_camera_set_keys(raw, keys.reduce(0) { $0 | $1.bit })
    }

    private static func cBox(_ b: BoundingBox) -> GraciaBBox {
        guard b.isValid else { return GraciaBBox() }
        return GraciaBBox(minmax: (b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z))
    }

    private static func matrix(
        from m: (
            Float, Float, Float, Float, Float, Float, Float, Float,
            Float, Float, Float, Float, Float, Float, Float, Float
        )
    ) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(m.0, m.1, m.2, m.3),
            SIMD4(m.4, m.5, m.6, m.7),
            SIMD4(m.8, m.9, m.10, m.11),
            SIMD4(m.12, m.13, m.14, m.15))
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

    public func viewHeightChanged(_ points: Float) { scene.setViewHeight(points) }

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
        dragIsPan ? scene.addPan(dx: d.x, dy: d.y) : scene.addRotation(dx: d.x, dy: d.y)
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
            return scene.addScroll(deltaY: invertScrollZoom ? -deltaY : deltaY, precise: precise)
        }
        scene.addPan(dx: deltaX * K.scrollPan, dy: deltaY * K.scrollPan)
    }

    public func magnify(_ magnification: Float) { scene.addMagnification(magnification) }

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
