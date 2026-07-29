//
//  The bridge between the SwiftUI control window (main actor) and the Compositor Services render
//  loop (a dedicated background thread). Compositor Services runs the render closure off the main
//  actor, so the two sides can't share `@Observable` state directly. `RenderLink` is a small
//  lock-guarded mailbox: the UI writes control *inputs*, the render thread reads a consistent
//  snapshot each frame and writes status *outputs* back for the HUD.
//
//  Everything crossing the boundary is a plain `Sendable` value type, so there's nothing to race on
//  beyond the single lock.
//

import Foundation

/// How the immersive space composites: `.full` replaces passthrough (you're inside the scene),
/// `.mixed` keeps passthrough (the scene floats in your room). The only rendering difference is the
/// clear-colour alpha — opaque black for full, transparent for passthrough.
///
/// `.progressive` is deliberately not offered: Compositor Services requires the newer drawable
/// render-context present path for progressive immersion, which the classic `encodePresent`
/// (used here) can't satisfy — advertising it makes the compositor refuse to present the drawable.
enum ImmersionMode: String, Sendable, CaseIterable, Identifiable {
    case full, mixed
    var id: String { rawValue }

    /// Passthrough modes clear to alpha 0 so the camera feed shows through; full clears to opaque black.
    var isPassthrough: Bool { self != .full }

    var label: String {
        switch self {
        case .full: "Full (inside the scene)"
        case .mixed: "Mixed (in your room)"
        }
    }
}

/// What the render thread publishes each frame for the window's HUD.
struct ImmersiveStatus: Sendable, Equatable {
    var sceneName: String = ""
    var loaded = false
    var isVideo = false
    var visibleSplats: UInt32 = 0
    var splatsBudget: UInt32 = 0
    var fps: Double = 0
    var buffering = false
    var duration: Double = 0
    var playhead: Double = 0
    var gpuBytes: UInt64 = 0
    /// Non-nil once a scene fails to load, so the window can surface it.
    var errorMessage: String? = nil
}

final class RenderLink: @unchecked Sendable {
    private let lock = NSLock()

    // MARK: Inputs (UI → render thread)

    private var _sceneURL: URL?
    /// Bumped every time a new file is chosen, so the render thread reloads even if the URL repeats.
    private var _sceneGeneration = 0
    private var _isPlaying = true
    private var _playbackSpeed: Double = 1
    private var _seek: Double?
    private var _immersion: ImmersionMode = .mixed
    private var _recenter = false

    // MARK: Outputs (render thread → UI)

    private var _status = ImmersiveStatus()

    /// A consistent snapshot of every input, taken once per frame. One-shots (`seek`, `recenter`)
    /// are consumed here so they fire exactly once.
    struct Inputs: Sendable {
        var sceneURL: URL?
        var sceneGeneration: Int
        var isPlaying: Bool
        var playbackSpeed: Double
        var seek: Double?
        var immersion: ImmersionMode
        var recenter: Bool
    }

    // MARK: UI side

    func setScene(_ url: URL?) {
        lock.withLock {
            _sceneURL = url
            _sceneGeneration += 1
            _seek = 0
            _isPlaying = true
        }
    }

    func setPlaying(_ v: Bool) { lock.withLock { _isPlaying = v } }
    func setPlaybackSpeed(_ v: Double) { lock.withLock { _playbackSpeed = v } }
    func seek(to t: Double) { lock.withLock { _seek = t } }
    func setImmersion(_ m: ImmersionMode) { lock.withLock { _immersion = m } }
    func requestRecenter() { lock.withLock { _recenter = true } }

    /// Clears the recenter request once the renderer has actually applied it (see below — it is *not*
    /// cleared in ``takeInputs()``, so a tap survives a frame that never reaches placement).
    func consumeRecenter() { lock.withLock { _recenter = false } }

    func status() -> ImmersiveStatus { lock.withLock { _status } }

    // MARK: Render side

    /// Pulls the current inputs and clears the one-shot requests.
    func takeInputs() -> Inputs {
        lock.withLock {
            let seek = _seek; _seek = nil
            // `_recenter` is deliberately NOT cleared here — it stays latched until the renderer
            // actually applies it (``consumeRecenter()``), so a tap can't be dropped by a frame that
            // aborts before placement. `seek` is safe to consume: it's applied before those aborts.
            return Inputs(
                sceneURL: _sceneURL,
                sceneGeneration: _sceneGeneration,
                isPlaying: _isPlaying,
                playbackSpeed: _playbackSpeed,
                seek: seek,
                immersion: _immersion,
                recenter: _recenter)
        }
    }

    func publish(_ s: ImmersiveStatus) { lock.withLock { _status = s } }
}
