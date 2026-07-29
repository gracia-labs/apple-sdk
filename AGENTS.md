# AGENTS.md

This file explains how to integrate the Gracia SDK into an Apple app. [`README.md`](README.md) is the
reference, and the source doc comments are the full API. This file is the shortest correct path, with
the errors that cost the most time.

> Write docs in Simplified Technical English (ASD-STE100): short active sentences, present tense, no gerund verbs, no contractions.

## Orientation

| To build | Depend on |
| --- | --- |
| a macOS viewer, fast | `GraciaView` (it pulls in the other two) |
| iOS / visionOS | `GraciaSDK` + `GraciaCamera`, and write your own view |
| macOS with your own renderer | `GraciaSDK` + `GraciaCamera` |

`GraciaView` and `mac-viewer` are macOS-only (`#if os(macOS)`). Do not use `SplatsSceneView` on iOS.
The Metal framework is inside the package: no install step, no `pod`, no build script. If you write
one, something is wrong. The framework is mergeable with `-Xlinker -merge_framework -Xlinker gracia_sdk`.
See README, "Install".

```sh
swift build && swift test
swift run mac-viewer scene.mint --screenshot out.png --frames 20   # headless PNG; then read it back
```

## macOS: `SplatsSceneView` does the work

```swift
let view = try SplatsSceneView(device: MTLCreateSystemDefaultDevice()!)
view.onError = { print("gracia: \($0)") }
window.contentView = view
try view.load(urls: [url])
```

The view controls the renderer, the camera, the input, the playback, and the frame rate. Do not add a
`CADisplayLink`, a render loop, or an `MTKViewDelegate`. A static scene must stay idle. Connect the
callbacks that you need: `onSceneLoaded`, `onError`, `onStatus`, `onCommandKey`.

## iOS / visionOS: you render

The sequence for each frame is in README, "Use the libraries directly". Two full worked examples exist:
[`iOS/README.md`](iOS/README.md) (2D viewer and AR) and [`AVP/README.md`](AVP/README.md) (immersive
stereo). Five things cause most errors, in this order:

1. Configure the drawable from `SplatsPassDescriptor.viewer`, not by hand. The default color format of
   `MTKView` is wrong. The depth format and the clear value must match the projection.
2. Set `camera.reverseZ = pass.usesReverseZ`, or the scene is empty or inside-out.
3. Call `render(...)` with no encoder open. Then make the encoder with `makeRenderCommandEncoder(_:descriptor:pass:)`.
4. Call `scene.pump()` every frame, or nothing decodes.
5. Hold the `Frame` until its command buffer is complete. If you release it early, you get a
   use-after-free crash on a Metal thread.

## Lifetime rules

Almost all crashes have one cause: you release GPU data while the GPU still uses it. Obey these rules.

1. Do not release a `Scene` or a `SplatsRenderer` while a frame that uses it is not complete.
2. Use a maximum of three frames at a time.
3. To change the scene, do these steps in sequence: wait for the current frames to complete, call
   `context.waitUntilIdle()`, release the `Frame` objects that you hold, then replace the scene and
   rebuild.
4. Release the frames when the view closes too. `SplatsSceneView` does this in an `isolated deinit`.
5. Call `withDrainedFrames` from `beforeFrame()` only. It needs all the permits, but `render(...)`
   holds one, so a call inside a frame stops the view.

A crash on a `com.Metal.CompletionQueueDispatch` thread means you broke one of these rules.

## Looks broken, but is not

- **`visibleSplatsCount` is 0** → set `renderer.setFlag("splats_count_readback", true)`.
- **The scene is on its side** → reorient it with `setSceneTransform(_:)` or `Scene.setTransform(_:)`.
- **The scene is small and far** → the SDK frames with `adaptiveBBox`. If the scene is wide, you framed on `boundingBox`.
- **`GraciaContext` does not create** → a GPU frame debugger (`MTL_CAPTURE_ENABLED`) blocks it. Detach it.
- **Nothing draws** → a static scene draws on demand; call `requestFrame()`.
- **A `.mint` is blank at first** → it buffers; check `SceneStatus.isBuffering` or `Frame.buffering`.
- **A stream shows `duration == 0`, an empty bbox, and never draws** → the metadata is not in yet. Call
  `pump()`, watch `Scene.isSettled`, then frame and rebuild again. Do not gate on `duration > 0`.
- **`ld: dylib cannot be merged`** → the xcframework is older than the mergeable build. Remove
  `-merge_framework`, or rebuild the xcframework.

## Verify a change

There is no offscreen render test, so use the real path and read the PNG back:

```sh
swift test
swift run mac-viewer scene.mint --screenshot out.png   # + MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1
```

Test both layouts: `a.mint b.sog` (composited) and `a.mint b.mint --split`. A frame debugger blocks
context creation, so do not attach one to debug that.

---

# Develop the package

- **Layering.** `GraciaSDK` and `GraciaCamera` must never import AppKit, UIKit, or MetalKit. This keeps
  them usable on iOS and visionOS. Check with
  `strings .build/debug/GraciaSDK.swiftmodule | grep -E '^(AppKit|UIKit|MetalKit)$'` (must be empty) and
  `xcodebuild -scheme GraciaCamera -destination 'generic/platform=iOS' build`.
- **Scene swaps** are the crash path. The `SplatsSceneView.swapContent` order is load-bearing: drain,
  `waitUntilIdle`, release the `Frame`s, then rebuild. Stress it: run `--reload … --screenshot` 15
  times, and expect zero non-zero exits.
- **Frame pacing.** A static scene draws about 2 frames in each 4 s. A video runs at the display rate,
  and so does a stream that buffers. Measure with unbuffered stderr, because `kill -9` loses the
  `print()` buffer. If you leave `preferredFramesPerSecond` unset, `MTKView` holds 60.
- **Tests.** `swift test` runs 72 tests in 10 suites. `Live SDK` is the only GPU suite. It is
  `.serialized`, and it does nothing when there is no Metal device.
- **Camera.** Keys match by physical key code, never by character (the character is layout-dependent and
  can strand a held key). Fly speed is proportional to the scene radius. `moveDtCap` stops a large
  post-idle `dt` from a lurch.
