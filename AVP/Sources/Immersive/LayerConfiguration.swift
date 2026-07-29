//
//  Configures the Compositor Services layer the immersive space renders into. The choices here must
//  line up with the Gracia `SplatsPassDescriptor` the renderer builds, or Metal rejects the
//  pipeline — so this file and ``ImmersiveRenderer/makePass()`` are a matched pair.
//

import CompositorServices
import Metal
import SwiftUI  // CompositorLayerConfiguration lives in the CompositorServices–SwiftUI integration.

struct GraciaLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration
    ) {
        // Colour: Gracia has no BGRA format, so pick from the formats it *can* represent. `.rgba16Float`
        // (HDR) is always offered on visionOS and is the natural fit; the sRGB/UNORM 8-bit forms are
        // fallbacks. The renderer reads back whichever we land on and matches its pass to it.
        let colors = capabilities.supportedColorFormats(options: [])
        let graciaColors: [MTLPixelFormat] = [.rgba16Float, .rgba8Unorm_srgb, .rgba8Unorm]
        configuration.colorFormat = graciaColors.first(where: colors.contains) ?? .rgba16Float

        // Depth: 32-bit float. The drawable's depth range is stored reverse-Z, so the projection
        // `computeProjection` hands back maps near→1/far→0 — which is why the Gracia pass is built
        // reverse-Z too (see ImmersiveRenderer.makePass).
        let depths = capabilities.supportedDepthFormats
        configuration.depthFormat = depths.contains(.depth32Float) ? .depth32Float : (depths.first ?? .depth32Float)

        // Foveation: the compositor renders the periphery at lower density into a smaller physical
        // texture and un-warps it at scan-out. When on, the drawable hands us a per-view
        // rasterization-rate map that every render pass must apply (see ImmersiveRenderer.encode).
        //
        // Caveat: the SDK's render() takes only width/height + projection, no rate map, so it sizes
        // splat footprints against a uniform density. Geometry and blending warp correctly (clip-space
        // geometry through the rate map); splat *sizes* are not density-compensated across the field.
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        // Query the layouts with the foveation option so the chosen layout is valid for a foveated
        // target. Layered — one texture array, one slice per eye — maps 1:1 onto Gracia's multipass
        // stereo (one encoder per slice); `.shared`/`.dedicated` also work (each view is located from
        // its texture map), but layered is the Vision Pro path.
        let layoutOptions: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            foveationEnabled ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: layoutOptions)
        configuration.layout =
            layouts.contains(.layered) ? .layered : (layouts.contains(.shared) ? .shared : .dedicated)
    }
}
