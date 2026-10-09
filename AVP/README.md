# Gracia visionOS demo (Apple Vision Pro)

A Vision Pro app that plays a Gaussian-splat scene **in stereo, and immersively**. You step inside the
scene, or you float it in your room, and you look around with your head. It is the visionOS counterpart
to the iOS demo. On iOS you drive one camera from touch. Here the two eyes come straight from the
headset, and the built-in VR path of the SDK does the stereo.

- **Control window** — select a `.ply`, `.sog`, `.mint`, or `.grv`; enter or exit the immersive space;
  place and scale the scene; and play or scrub volumetric video. A small HUD shows splats, FPS, and
  GPU use.
- **Immersive space** — a [Compositor Services](https://developer.apple.com/documentation/compositorservices)
  render loop draws the scene into the display, one eye for each texture-array slice.
  [ARKit](https://developer.apple.com/documentation/arkit/worldtrackingprovider) tracks the head.

`GraciaView` and `mac-viewer` are macOS-only. Thus on visionOS you drive `GraciaSDK` and `GraciaCamera`
yourself. This is the "Use the libraries directly" path of the main README, with the two things that
Vision Pro adds: Compositor Services and the render for each eye.

## Build and run

XcodeGen generates the Xcode project from [`project.yml`](project.yml):

```sh
brew install xcodegen        # once
cd AVP
xcodegen generate
open GraciaVisionDemo.xcodeproj
```

Then set your signing team on the `GraciaVisionDemo` target, and run on a **physical Vision Pro**.

> **Device only.** The fully immersive Metal render with Compositor Services is a device feature. The
> visionOS Simulator cannot present it. The stereo splat render also needs real GPU hardware. Thus this
> app builds for the Vision Pro only. (`SUPPORTED_PLATFORMS: xros` in `project.yml` makes Xcode refuse
> the Simulator destination.)

To compile-check from the command line, you need no signing:

```sh
xcodebuild -project GraciaVisionDemo.xcodeproj -scheme GraciaVisionDemo \
  -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build
```

## Load a scene

There is no bundled sample. In the window, tap **Open** and select a `.ply`, `.sog`, `.mint`, or `.grv`
from Files. First, AirDrop or copy a file onto the device. The app copies the file into its container,
thus the render thread can read it. Then tap **Enter Immersive Space**.

## Controls

Move the scene **with your hands**, directly in the space:

| gesture | action |
| --- | --- |
| pinch and drag, one hand | move the scene |
| pinch with both hands | scale and rotate it |

The control window holds the rest. It stays visible inside the space:

| control | action |
| --- | --- |
| **Enter / Exit Immersive Space** | open or close the stereo player |
| **Immersion** | Mixed (the scene floats in your room over passthrough) or Full (passthrough is replaced, and you are inside the scene) |
| **Recenter in front of me** | drop the scene again, sized and placed in front of your view |
| **Play / scrub** | volumetric video (`.mint`, `.grv`) only |

## How it fits together

| File | Role |
| --- | --- |
| [`GraciaVisionApp.swift`](Sources/App/GraciaVisionApp.swift) | the `@main` app: a `WindowGroup` control panel and an `ImmersiveSpace` that hosts a `CompositorLayer`. |
| [`ControlPanelView.swift`](Sources/App/ControlPanelView.swift) | the window UI: file import, open or close the space, immersion and playback, and the HUD. |
| [`AppModel.swift`](Sources/App/AppModel.swift) | the window's `@Observable` state. It pushes every control change into the `RenderLink`. |
| [`RenderLink.swift`](Sources/Immersive/RenderLink.swift) | the lock-guarded mailbox between the main actor and the render thread (control inputs in, status out). |
| [`SpatialGestureController.swift`](Sources/Immersive/SpatialGestureController.swift) | maps hand pinches to the scene's model matrix. `layerRenderer.onSpatialEvent` feeds it (main actor), and the render thread applies it. This is ported from the production app. |
| [`Placement.swift`](Sources/Immersive/Placement.swift) | the scene's *initial* placement, and Recenter: normalize to a graspable size, and drop it in front of the head. It also extracts head yaw and position. |
| [`LayerConfiguration.swift`](Sources/Immersive/LayerConfiguration.swift) | picks the layer's color format, depth format, and layout, to match the Gracia pass. |
| [`ImmersiveRenderer.swift`](Sources/Immersive/ImmersiveRenderer.swift) | the render loop: per-eye `RenderView`s from the drawable, `SplatsRenderer(vr: true).render(views:)`, multiview amplification into the layered texture, and scene load, placement, and playback. |

### The stereo camera math

Each frame, for each eye `i` of the drawable:

```swift
let projection    = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
let cameraToWorld = deviceAnchor.originFromAnchorTransform * drawable.views[i].transform
views.append(RenderView(projection: projection, cameraToWorld: cameraToWorld))
```

The parts match the Gracia conventions exactly, thus nothing is flipped or transposed:

- **`.rightUpBack`** (right-handed, +Y up, +Z toward the viewer) *is* the Gracia camera basis (columns
  right / up / back / eye, with back away from the view). `computeProjection` returns a
  Metal-clip-space matrix. The depth range of the drawable is reverse-Z, thus it maps near→1, far→0.
  Thus the Gracia pass is reverse-Z too (`.splats(format: .d32Float, reverseZ: true)`, compare
  `.greater`, clear depth `0`).
- **`originFromAnchorTransform`** is device-to-world (the pose of the head in the world).
  `views[i].transform` is eye-to-device. Thus `originFromAnchorTransform * views[i].transform` is
  eye-to-world, which the SDK inverts to the view matrix. The device pose left-multiplies.
- The world placement of the scene uses the scene **model** transform (`scene.setTransform`), never
  `cameraToWorld`.

The two eyes render with `StereoMode.multiview`. `render(views: [left, right])` returns a **single
vertex-amplified draw call** (`frame.color.mono`). One render pass runs it over the whole 2-slice
layered texture (`colorTextures[0]` / `depthTextures[0]`, `renderTargetArrayLength = 2`). The shader of
the SDK amplifies each vertex to two views (`[[amplification_id]]`), and it selects the matrix for each
eye by that id. The SDK does not set the amplification on the encoder, thus you must do it:

```swift
encoder.setViewports([viewport, viewport])                 // amp 1 uses viewport index 1
encoder.setVertexAmplificationCount(2, viewMappings: [
    .init(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
    .init(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1),   // amp 1 → slice 1
])
```

This matches the Metal backend of the SDK (`deps/fuji/.../metal/RenderPass.cpp`). Depth comes from the
same color pass (`.splats(reverseZ: true)`, stored to `depthTextures[0]`), thus the compositor can
reproject. The path is reverse-Z throughout, and it matches `computeProjection` and the `depthRange` of
the drawable.

## Notes and simplifications

- **Hand-driven placement, with `onSpatialEvent`.** Compositor Services delivers the pinches
  (`layerRenderer.onSpatialEvent`), the same indirect-pinch input that SwiftUI uses. Thus you need no
  `HandTrackingProvider` and no hand-tracking authorization. There is no world anchor, thus a
  relocalization can shift where the scene sits until you Recenter.
- **Foveation is on** where the device supports it. The single layered (multiview) render pass applies
  `drawable.rasterizationRateMaps.first`. Thus the periphery rasterizes at lower density, and the
  compositor un-warps it at scan-out. Note: the SDK `render` takes only width, height, and
  projection — no rate map. Thus it does not density-compensate the splat *footprint*. The geometry and
  the blend warp correctly (clip-space geometry goes through the rate map), but the splat sizes
  assume a uniform density. Check the periphery on the device. A fully density-correct result needs an
  SDK `render` that accepts the rate map, as the production hybrid renderer does.
- **No audio.** A `.mint` can carry an MP3 (`Scene.audioData`). This app does not connect it to an
  `AVAudioPlayer` from the playhead, the same as the iOS demo.
- **Passthrough (Mixed)** clears the color to alpha 0, thus the camera feed shows through. **Full**
  clears to opaque black. The premultiplied splats of the scene blend over whichever mode you select.
