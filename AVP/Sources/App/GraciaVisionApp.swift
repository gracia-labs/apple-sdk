//
//  App entry point: a control window plus an immersive space that renders the scene in stereo
//  through Compositor Services.
//
//  The `CompositorLayer` render closure runs on the main actor, so it does the minimum — build the
//  renderer and hand its loop off to a dedicated thread — then returns. The renderer talks to the
//  window only through `model.link`.
//

import CompositorServices
import SwiftUI

@main
struct GraciaVisionApp: App {
    static let immersiveSpaceID = "player"

    @State private var model = AppModel()
    // Immersion style lives here as @State: changing it re-runs this body and re-applies the style to
    // the open space. (A `.constant` binding doesn't drive live changes — mixed would stay black.)
    // Default `.mixed` so you land in passthrough with the scene in your room.
    @State private var immersion: ImmersionMode = .mixed

    var body: some SwiftUI.Scene {
        WindowGroup(id: "control") {
            ControlPanelView(model: model, immersion: $immersion)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            CompositorLayer(configuration: GraciaLayerConfiguration()) { layerRenderer in
                let renderer = ImmersiveRenderer(layerRenderer: layerRenderer, link: model.link) {
                    // The render loop exits when the space closes (including a system-initiated close
                    // via the Digital Crown), so this is the reliable "immersive ended" signal.
                    Task { @MainActor in model.isImmersed = false }
                }
                // Hand pinches targeting the immersive space arrive here (pinches on the control
                // window are disambiguated away by the system) and drive the scene's placement.
                layerRenderer.onSpatialEvent = { [gestures = renderer.gestureController] events in
                    gestures.handleSpatialEvents(events)
                }
                renderer.start()
            }
        }
        // Two-way binding so picking a style in the window switches the live space. Only `.mixed` and
        // `.full` are advertised — `.progressive` would require the drawable render-context present
        // path (this renderer uses the classic `encodePresent`).
        .immersionStyle(
            selection: Binding(get: { immersion.style }, set: { immersion = ImmersionMode(style: $0) }),
            in: .mixed, .full)
    }
}
