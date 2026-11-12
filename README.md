# Gracia SDK for Apple platforms

Render Gaussian-splat scenes — static captures and volumetric video — in Swift, with Metal.

```swift
let view = try SplatsSceneView(device: device)   // macOS: a full viewer
try view.load(urls: [sceneURL])
window.contentView = view
```

The camera (drag to orbit, WASD to fly, scroll to zoom), video playback, and drag-and-drop are all included.

## Products

| Product | Platforms | What it is |
| --- | --- | --- |
| `GraciaSDK` | macOS · iOS · visionOS | Scene loading + the Metal renderer. Foundation, Metal, simd. |
| `GraciaCamera` | macOS · iOS · visionOS | Camera + input (orbit / fly / zoom). simd only. |
| `GraciaView` | macOS | Drop-in `MTKView` that plays scenes. AppKit + MetalKit. |
| `mac-viewer` | macOS | A demo app: `swift run mac-viewer scene.mint` |

`GraciaSDK` and `GraciaCamera` use **no UI framework**. On iOS and visionOS, bring your own view.
`GraciaView` is the macOS convenience layer.

**Formats** `.ply`, `.sog` (static), `.mint`, `.grv` (video). **Requires** macOS 14 · iOS 16.4 · visionOS 26, Swift 6, Apple silicon.

## Install

Add the package. Depend on `GraciaView` (macOS) or `GraciaSDK` and `GraciaCamera` (iOS and visionOS).
The Metal framework ships inside, thus you link nothing else. Each slice is a **static library** with
its own C++ runtime: the link puts it into your binary, thus your app ships nothing beside it, and
embeds and signs nothing of it. The library names the system frameworks that it needs.

```sh
swift run mac-viewer a.mint b.mint --split          # side by side
swift run mac-viewer --stream https://…/s.mint --token abc123
swift run mac-viewer --help                         # all flags
```

## Demo content

Scenes to play with: **https://docs.gracia.ai/demo-data**

Three ways to play a scene:

| | How | Call |
| --- | --- | --- |
| **Local file** | Download it, open it from disk | `view.load(urls: [url])` |
| **Direct URL** | A direct link to the file streams as it is — no token, any static host | `view.load(streamURL: url)` |
| **Gracia stream** | Streaming through Gracia infrastructure, with a token | `view.load(streamURL: url, token: t)` |
| **`.grv` stream** | A `.grv` from any static host, with the key of a locked one | `view.load(grvURL: url, key: k)` |

The same in `mac-viewer`: a path argument, `--stream <url>`, `--stream <url> --token <t>`, or
`--grv <url> --key <file>`. A locked `.grv` opens only with its key: a file takes the file beside it
with `.key` after its name, and `key:` gives it to a stream or to a file of another name.
A direct link works from any static host, thus it is the quickest way to try a stream. Gracia
infrastructure is the more reliable path.

They are demo content: for demonstration and evaluation, not for redistribution or
publication. See [CONTENT-LICENSE](CONTENT-LICENSE). For your own 4DGS content, write to
support@gracia.ai.

## Using the view (macOS)

`SplatsSceneView` (an `NSView`) owns the renderer, the camera, the playback, the input, and the render
pace. You own the window. Do not add a draw loop. A static scene renders **on demand**. A stream that
plays or buffers renders continuously, and it pauses while the window is not key.

```swift
try view.load(urls: urls, layout: .split)      // or load(streamURL:token:)
try view.toggleLayout()                        // .mix ⇄ .split
view.isPlaying = true; view.playbackSpeed = 1.5
view.seek(to: 2.5)                             // works while paused
view.onStatus = { s in hud.stringValue = "\(Int(s.fps)) fps · \(s.visibleSplats) splats" }
view.snapshot(to: pngURL, afterFrames: 20) { _ in }
```

The camera frames the scene box. Where a `.grv` states a display viewpoint, the camera starts there
instead, under the scene transform, and the controls move it from there. `0` returns it there. Where a
`.grv` states a pivot, the camera turns about it, and frames the box about it.

## Using the libraries directly (iOS / visionOS)

Drive the renderer yourself. Configure the drawable from the pass descriptor. The default color format
of `MTKView` is wrong. Set `camera.reverseZ = pass.usesReverseZ`.

```swift
let context  = try GraciaContext(device: device, commandQueue: queue)
let scene    = try Scene(url: url, context: context)
let renderer = try SplatsRenderer(context: context, maxSplatsCount: scene.splatsBudget)
let pass     = SplatsPassDescriptor.viewer         // → metalColorPixelFormat, metalDepthPixelFormat, …

// once per frame:
scene.setTime(playhead); scene.pump()              // pump() every frame or nothing decodes
let frame = renderer.render(scenes: [scene], view: camera.renderView(aspect: a, viewHeightPoints: vh),
                            targetWidth: w, targetHeight: h, pass: pass, commandBuffer: cb)
let enc = renderer.makeRenderCommandEncoder(cb, descriptor: desc, pass: pass)!  // AFTER render()
frame.color.mono?.execute(into: enc); enc.endEncoding()
```

The API cannot enforce three rules (if you break one, you get a use-after-free crash):

- **Call `render(...)` with no encoder open.** Make the render encoder afterwards with `makeRenderCommandEncoder`.
- **Hold each `Frame` until its command buffer completes**, and keep ≤ 3 in flight.
- **Never free a scene or renderer with a frame in flight** — drain, call `context.waitUntilIdle()`, then free.

**Streams settle late.** The `duration`, `splatsBudget`, and `boundingBox` of a `.mint` stream read 0
or empty until `pump()` brings the metadata in. A `.grv` file does the same. Drive the loop from
`hasVideo`, never from `duration > 0`. When `isSettled` flips, rebuild the renderer and re-frame the
camera. A settled `.grv` can state `viewpoints`, where its author starts the viewer: `display` for a
flat screen and `vr` for a headset, each the pose of the eye in the scene's own space. Map one through
`worldPose(of:model:)` under a scene transform. Start a flat camera at `display` with
`place(eye:orientation:)` at 60° vertical. In a headset, stand the viewer on the floor of the scene
(y 0) under `vr`, facing its heading, and keep the height and the tilt of the headset. A settled `.grv`
can also state a `pivot`, the point that a viewer turns about, in the same space: give it through
`model.transform(point:)` to `camera.setBBox(_:adaptive:pivot:)`. A `.grv` that plays nothing states
why in `status` after `pump()` returns false: `.locked` opens only with its key, thus load it again with
`key:`; `.unsupported` needs a newer SDK; `.failed` does not play. `frameSplatsCount` is the splats of
the frame of the last render. `SceneGroup` composites N scenes as one. `CameraInput` maps the pointer, the keys, and the
scroll. The pointer y is **down**. Call `releaseAllKeys()` on any lost key-up. The source doc comments
are the full API.

**Sound.** A `.grv` can hold sounds, and the SDK plays them itself. The context mixes them on the default
playback device (`audio: .device`, the default of `GraciaContext`). On iOS and visionOS, set the
category of your `AVAudioSession`, for example `.playback`: the SDK does not change it. Each frame:

```swift
scene.setTime(playhead)
scene.setSpeed(moves ? playbackSpeed : 0)          // 0 while you pause, hold the time or scrub
context.setListener(cameraToWorld: view.cameraToWorld)   // in a headset, the head between the eyes
```

A scene plays no sound until you set a speed. A sound with an emitter comes from its place in the scene,
under the transform of the scene, and the others play at the listener, as music. `setVolume` scales the
gain of each sound of a scene. To mix the sounds into an audio engine of your own, create the context with
`audio: .host(sampleRate:channels:)` and call `readAudio(into:frameCount:)` on your audio thread. The MP3
of a `.mint` is not played: read it from `audioData`.

For full worked examples, see the [iOS demo](iOS/README.md) (2D viewer and AR) and the
[visionOS demo](AVP/README.md) (immersive stereo).

## Controls

`drag` orbit · `right-drag`/`⌥` pan · `scroll` zoom · `wasd rf qe` fly (⇧ sprint; scroll sets speed) ·
`space` play/pause · `0` reset framing · `m` mix/split · hold `b` split dividers · `⌘O` open · `⌘L` stream · `⌘K` flag · drop files.
The fly speed scales with the scene size. Thus it stays usable from a doll-house to a landscape.

## Test

```sh
swift build && swift test
```

## Contributing

Contributions are welcome — bug fixes, new examples, platform fixes, documentation.

- **Everything under the MIT part of [LICENSE](LICENSE)** — issues and pull requests both.
  Fork it, patch it, send it back.
- **The Artifacts** — issues only. They ship prebuilt, thus there is nothing to patch here.
  Report a bug with steps to reproduce it and we fix it upstream and ship a new build.

By opening a pull request you agree that your contribution is licensed under the MIT License
(Part B of [LICENSE](LICENSE)).
