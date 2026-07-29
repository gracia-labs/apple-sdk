// swift-tools-version: 6.0

import PackageDescription

/// Gracia's Gaussian-splat SDK for Apple platforms.
///
/// Three libraries stacked on the C SDK, plus a viewer app that demonstrates them:
///
///   GraciaSDK     C bindings, Metal wiring, scene loading      Metal · simd · Foundation
///   GraciaCamera  camera + input (orbit, fly, zoom)            simd
///   GraciaView    macOS MTKView that plays scenes              AppKit · MetalKit
///   mac-viewer    the demo app: window, menu, HUD, CLI
///
/// `GraciaSDK` and `GraciaCamera` deliberately depend on no UI framework, so they work on the
/// xcframework's `ios-arm64` and `xros-arm64` slices too. AppKit and MetalKit stop at `GraciaView`.
let package = Package(
    name: "gracia-sdk",
    // Matches the xcframework's slices. `GraciaView` and `mac-viewer` are macOS-only — their
    // sources are guarded with `#if os(macOS)`, so they vanish on the other two platforms.
    platforms: [.macOS(.v14), .iOS("16.4"), .visionOS("26.0")],
    products: [
        .library(name: "GraciaSDK", targets: ["GraciaSDK"]),
        .library(name: "GraciaCamera", targets: ["GraciaCamera"]),
        .library(name: "GraciaView", targets: ["GraciaView"]),
        .executable(name: "mac-viewer", targets: ["MacViewer"]),
    ],
    targets: [
        // SwiftPM unpacks the zip itself, so the framework needs no separate install step.
        .binaryTarget(name: "gracia_sdk", path: "gracia_sdk.xcframework.zip"),

        // Everything C-facing: handles, matrix conventions, draw-call lifetimes, Metal wiring.
        .target(name: "GraciaSDK", dependencies: ["gracia_sdk"]),

        // Camera and input: orbit (drag), fly (WASD), zoom (scroll).
        .target(name: "GraciaCamera", dependencies: ["GraciaSDK"]),

        // The macOS view layer.
        .target(name: "GraciaView", dependencies: ["GraciaSDK", "GraciaCamera"]),

        // The demo viewer: a window, a menu, a HUD and a CLI around `SplatsSceneView`.
        // `-merge_framework` supersedes the `-framework` flag SwiftPM adds for the binary target, so
        // the mergeable `gracia_sdk` slice lands inside this executable instead of loading at launch.
        .executableTarget(
            name: "MacViewer",
            dependencies: ["GraciaView"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-merge_framework", "-Xlinker", "gracia_sdk"])]
        ),

        .testTarget(name: "GraciaSDKTests", dependencies: ["GraciaSDK"]),
        .testTarget(name: "GraciaCameraTests", dependencies: ["GraciaCamera", "GraciaSDK"]),
        .testTarget(name: "GraciaViewTests", dependencies: ["GraciaView"]),
    ],
    swiftLanguageModes: [.v6]
)
