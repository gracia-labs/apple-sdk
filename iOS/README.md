# Gracia iOS demo

A small iOS app that plays Gaussian-splat scenes in two modes:

- **2D viewer** — a touch-driven `MTKView`. It orbits, pans, zooms, and plays a scene, like the macOS
  `mac-viewer`.
- **AR** — the same scene placed in the world with ARKit, over the live camera feed.

Both modes are simple. `GraciaView` and `mac-viewer` are macOS-only. Thus on iOS you drive the renderer
yourself. This app is a worked example of the main README, "Use the libraries directly", with the one
thing that iOS adds: ARKit.

## Build and run

XcodeGen generates the Xcode project from [`project.yml`](project.yml):

```sh
brew install xcodegen        # once
cd iOS
xcodegen generate
open GraciaiOSDemo.xcodeproj
```

Then set your signing team on the `GraciaiOSDemo` target, and run on a **physical device**.

> **Device only.** The bundled `gracia_sdk.xcframework` has an `ios-arm64` slice, but no simulator
> slice. The splat render and ARKit both need real GPU and AR hardware. The Simulator does not build or
> run this app.

To compile-check from the command line, you need no signing:

```sh
xcodebuild -project GraciaiOSDemo.xcodeproj -scheme GraciaiOSDemo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Load a scene

There is no bundled sample. Tap **Open** and select a `.ply`, `.sog`, or `.mint` from Files. First,
AirDrop or copy a file onto the device. To load a scene on launch instead, put a scene file in the
resources of the app target.

## Controls

**2D viewer**

| gesture | action |
| --- | --- |
| one-finger drag | orbit |
| two-finger drag | pan |
| pinch | zoom |
| double-tap | reset framing |
| transport bar | play/pause and scrub (video only) |

**AR** (tap **AR** after a scene loads)

| gesture | action |
| --- | --- |
| tap | place the scene on the surface ahead (or 1 m ahead if there is none) |
| pinch | resize |
| one-finger drag | spin about the vertical axis |
| ☀ button (top-left) | switch environment lighting on or off (see below) |

## How it fits together

| File | Role |
| --- | --- |
| [`SplatsMetalView.swift`](Sources/Viewer/SplatsMetalView.swift) | the 2D viewer: an `MTKView` that runs the SDK render loop (three frames in flight, drain before swap, late-metadata reframe, and a continuous pace while it moves), with touch input mapped onto `CameraInput`. |
| [`ARSplatsRenderer.swift`](Sources/AR/ARSplatsRenderer.swift) | composites the scene over the camera feed. It uses two render encoders (splats first, then the camera behind them, destination-over) with ARKit's own pose and projection. |
| [`CameraBackground.swift`](Sources/AR/CameraBackground.swift) + [`Shaders.metal`](Sources/AR/Shaders.metal) | draws `ARFrame.capturedImage` (bi-planar YCbCr) as a full-screen quad. |
| [`EnvironmentSH.swift`](Sources/AR/EnvironmentSH.swift) | projects the AR environment-probe cube map into SH-L1 lighting coefficients. |
| [`ARSplatsViewController.swift`](Sources/AR/ARSplatsViewController.swift) | the `ARSession`, a `CADisplayLink` render loop that reads `session.currentFrame`, tap/pinch/drag placement, and the lighting switch. |

### The AR camera math

The ARKit `projectionMatrix(for:viewportSize:zNear:zFar:)` is a conventional right-handed projection
with `[0,1]` depth (near→0, far→1). Thus the splat pass is **non-reverse-Z**, to match it:

```swift
SplatsPassDescriptor(colorFormat: .rgba8Unorm, depth: .splats(format: .d16Unorm, reverseZ: false))
```

Each frame uses the **same** interface orientation `o` for all three calls:

```swift
let view = RenderView(
    projection:    frame.camera.projectionMatrix(for: o, viewportSize: vp, zNear: 0.05, zFar: 1000),
    cameraToWorld: frame.camera.viewMatrix(for: o).inverse)
```

GraciaSDK inverts `cameraToWorld` back to exactly `viewMatrix(for: o)`. This is the partner that matches
`projectionMatrix(for: o)`, thus the splats stay aligned to the image at every orientation. The camera
background samples `capturedImage` through `displayTransform(for: o, …)`, with the same `o`. The world
placement of the scene uses the scene *model* transform, never `cameraToWorld`.

### Environment lighting (experimental — the ☀ switch)

ARKit gives no spherical harmonics for a rear-camera session (SH is for face tracking only). It gives
an `AREnvironmentProbeAnchor.environmentTexture` **cube map** (you enable it with
`environmentTexturing = .automatic`). [`EnvironmentSH.swift`](Sources/AR/EnvironmentSH.swift) samples
that cube into a small equirectangular float image. Then it integrates the image into four SH-L1
coefficients, which feed the `setEnvironmentSH` of the scene. The convention matches **three.js**
`SphericalHarmonics3` (basis order `[DC, y, z, x]`, raw radiance coefficients, normalized by
`4π / totalWeight`).

The switch is **off by default**. A probe needs a second or two to appear, and it updates as you move.
Only then does the switch have an effect. `normalizeEnvSH1` normalizes the coefficients (a port is in
[`ARSplatsRenderer.swift`](Sources/AR/ARSplatsRenderer.swift)): it scales the DC so its peak channel
reaches `1 / SH_C0 ≈ 3.545`, and it scales SH1 by a `contrast` factor. This is peak-normalized, thus it
needs no knowledge of the absolute radiance scale of ARKit (which is about 10× dimmer than the working
range of the SDK). You can tune two constants on the device:

- **`environmentContrast`** (default 0.5, the same as the SDK) — damps the SH1 (directional) terms.
  Use a lower value for flatter light, or a higher value for the raw directionality of the room.
  (Strong SH-L1 can ring toward black on the dark side.)
- **`environmentInSceneSpace`** — rotates the SH by the placement yaw, thus the light stays fixed to
  the room. Flip it (or the yaw sign) if the light rotates with the scene, or turns the wrong way.
- It assumes the probe cube aligns to the world axes, and that its texels are linear.

## Notes and simplifications

- The app is portrait-locked, to keep the AR orientation math to one case.
- The AR placement stores a fixed world position (no `ARAnchor` tracking). This is stable enough for a
  short session. A relocalization can shift it.
- The 2D viewer and the AR mode each build their own `GraciaContext` and `Scene` from the URL. A scene
  binds to the context that created it, thus the two modes cannot share one.
