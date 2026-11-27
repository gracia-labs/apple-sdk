# Gracia RealityKit macOS demo

A small macOS RealityKit app that uses `GraciaRealityKit` (`GraciaARViewPostProcess`).

Splats render with `.rgba8Unorm` (4 B/px) color and direct `.d16Unorm` (2 B/px) depth (no
`DepthResolver`). One `half4` compute pass composites them against RealityKit color and depth. An
orange RealityKit cube orbits through the splats to show live hardware depth occlusion.

## Library types

| Type | Platforms | Use |
| --- | --- | --- |
| `GraciaRealityBridge` | macOS 14 · iOS 16.4 · visionOS 26 | Core bridge, 3-frame ring, direct splat depth, `half4` compute composite |
| `GraciaPostProcessEffect` | macOS 26 · iOS 26 | SwiftUI `RealityView` custom post-process with depth occlusion |
| `GraciaARViewPostProcess` | macOS 14 · iOS 16.4 | `ARView` post-process with depth occlusion |
| `GraciaRealityHybrid` | macOS 15 · iOS 18 · visionOS 26 | `RealityRenderer` + `MTLSharedEvent` in a Metal loop |
| `GraciaTextureHost` | macOS 15 · iOS 18 · visionOS 26 | Direct `.rgba8Unorm` `LowLevelTexture` + `.memoryless` depth |

## Build and run

Run `xcodegen generate` **inside** `RealityKit/` so `path: ..` resolves to the repo root:

```sh
brew install xcodegen        # once
cd RealityKit
xcodegen generate
open GraciaRealityKitDemo.xcodeproj
```

> If Xcode cannot find package products (`GraciaRealityKit`, `GraciaSDK`), close any other
> Xcode window that has the root `Package.swift` open, then run
> `xcodebuild -project GraciaRealityKitDemo.xcodeproj -resolvePackageDependencies` (or
> **File → Packages → Reset Package Caches**).

Build from the command line without a code signature:

```sh
xcodebuild -project GraciaRealityKitDemo.xcodeproj -scheme GraciaRealityKitDemo \
  CODE_SIGNING_ALLOWED=NO build
```

## Controls

- Click **Open Scene** to load a `.ply`, `.guf`, `.sog`, `.mint`, or `.grv` file.
- Drag to orbit, pinch to zoom, and toggle **Occluder** to inspect depth occlusion.
