//
//  The window's view model. Holds the control values the user edits and mirrors the render thread's
//  status back for the HUD. Every control change is pushed straight into the ``RenderLink``, which
//  the immersive renderer reads on its own thread.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    /// The one shared object the render thread also holds.
    let link = RenderLink()

    // MARK: Scene

    var sceneName: String?
    var loadError: String?

    // MARK: Immersive space

    var isImmersed = false

    // MARK: Playback

    var isPlaying = true {
        didSet { link.setPlaying(isPlaying) }
    }

    // MARK: Live status (polled from the render thread while immersed)

    var status = ImmersiveStatus()

    // MARK: Actions

    func selectScene(url: URL) {
        sceneName = url.lastPathComponent
        loadError = nil
        isPlaying = true
        link.setScene(url)
    }

    func recenter() { link.requestRecenter() }

    func seek(to time: Double) { link.seek(to: time) }

    /// Copies the render thread's latest status into the observable `status`, surfacing any load
    /// error to the window.
    func refreshStatus() {
        status = link.status()
        if let message = status.errorMessage { loadError = message }
    }
}

extension ImmersionMode {
    /// The SwiftUI immersion style this mode drives.
    var style: any ImmersionStyle {
        switch self {
        case .full: .full
        case .mixed: .mixed
        }
    }

    /// Maps a SwiftUI immersion style back to our mode (for the immersionStyle selection binding).
    init(style: any ImmersionStyle) {
        self = style is MixedImmersionStyle ? .mixed : .full
    }
}
