//
//  Swift bindings for the Gracia C SDK.
//  Depends on Metal, simd and Foundation only — never AppKit/UIKit/MetalKit.
//  See README.md for conventions.
//

import Foundation
import Metal
import gracia_sdk
import simd

// MARK: - Errors

public enum GraciaError: Error, CustomStringConvertible {
    case contextCreationFailed
    case rendererCreationFailed
    case loadFailed(URL)
    case unsupportedFile(URL)

    public var description: String {
        switch self {
        case .contextCreationFailed:
            "failed to create the Gracia context (no Metal device, or a GPU debugger is attached)"
        case .rendererCreationFailed: "failed to create the splats renderer"
        case .loadFailed(let url): "failed to load \(url.lastPathComponent)"
        case .unsupportedFile(let url): "unsupported file type: \(url.lastPathComponent)"
        }
    }
}

// MARK: - Geometry

/// Axis-aligned bounds in the object's own (pre-transform) space.
public struct BoundingBox: Equatable, Sendable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    fileprivate init(_ b: GraciaBBox) {
        let m = b.minmax
        self.init(min: SIMD3(m.0, m.1, m.2), max: SIMD3(m.3, m.4, m.5))
    }

    public var center: SIMD3<Float> { (min + max) * 0.5 }
    public var size: SIMD3<Float> { max - min }
    /// Half the diagonal — the radius of the enclosing sphere.
    public var radius: Float { simd_length(size) * 0.5 }

    /// A fresh video stream reports an inverted box until its first frame decodes, so check finiteness too.
    public var isValid: Bool {
        min.x <= max.x && min.y <= max.y && min.z <= max.z
            && min.x.isFinite && min.y.isFinite && min.z.isFinite
            && max.x.isFinite && max.y.isFinite && max.z.isFinite
    }

    /// Smallest box containing both; an invalid box contributes nothing (undecoded video won't poison it).
    public func union(_ other: BoundingBox) -> BoundingBox {
        guard isValid else { return other }
        guard other.isValid else { return self }
        return BoundingBox(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

// MARK: - Matrix conventions

/// Matrix conventions `gracia_splats_renderer_render` requires: each `float*` is 16 floats
/// **column-major**, byte-identical to `simd_float4x4`. No transpose needed.
public enum GraciaMatrix {
    /// Right-handed, zero-to-one depth, no Y flip on Metal. See README "Matrices".
    /// - Parameter reverseZ: maps near to 1, far to 0 for depth precision. Pair with
    ///   `DepthDescription.splats(format:reverseZ:)`.
    public static func perspective(
        fovYDegrees: Float, aspect: Float, near: Float, far: Float, reverseZ: Bool = true
    ) -> simd_float4x4 {
        // Reverse-Z is the standard formula with near and far swapped.
        let n = reverseZ ? far : near
        let f = reverseZ ? near : far
        let t = tan(fovYDegrees * .pi / 360)  // tan(fovY / 2)

        return simd_float4x4(
            SIMD4(1 / (Swift.max(aspect, 1e-6) * t), 0, 0, 0),
            SIMD4(0, 1 / t, 0, 0),
            SIMD4(0, 0, f / (n - f), -1),
            SIMD4(0, 0, (f * n) / (n - f), 0))
    }

    /// Camera-to-world from an orthonormal basis. Columns are (right, up, back, eye); `back` points away from view.
    public static func cameraWorld(
        eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>
    ) -> simd_float4x4 {
        simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1))
    }

    /// Camera-to-world looking from `eye` at `target`.
    public static func cameraWorld(
        eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)
    ) -> simd_float4x4 {
        let z = normalized(eye - target, fallback: SIMD3(0, 0, 1))
        let x = normalized(simd_cross(up, z), fallback: SIMD3(1, 0, 0))
        return cameraWorld(eye: eye, right: x, up: simd_cross(z, x), back: z)
    }
}

/// Like `simd_normalize` but returns `fallback` for a zero-length vector instead of NaN.
@inlinable
public func normalized(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v)
    return len.isFinite && len > 1e-6 ? v / len : fallback
}

/// `Vec3.setLength` — normalize (with fallback) then scale.
@inlinable
public func withLength(
    _ v: SIMD3<Float>, _ len: Float, fallback: SIMD3<Float> = SIMD3(1, 0, 0)
) -> SIMD3<Float> {
    normalized(v, fallback: fallback) * len
}

extension simd_float4x4 {
    /// The 16 floats the C API expects, column-major.
    @inlinable
    public var columnMajor: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    /// Transform a point (w = 1).
    @inlinable
    public func transform(point p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    public init(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        let r = simd_float3x3(rotation)
        self.init(
            SIMD4(r.columns.0 * scale.x, 0),
            SIMD4(r.columns.1 * scale.y, 0),
            SIMD4(r.columns.2 * scale.z, 0),
            SIMD4(translation, 1))
    }
}

// MARK: - Formats

public enum ColorFormat: Sendable {
    case rgba8Unorm, rgba8Srgb, rgba16Float, rg16Float, rgba32Float

    fileprivate var raw: GraciaColorFormat {
        switch self {
        case .rgba8Unorm: GRACIA_COLOR_FORMAT_RGBA8_UNORM
        case .rgba8Srgb: GRACIA_COLOR_FORMAT_RGBA8_SRGB
        case .rgba16Float: GRACIA_COLOR_FORMAT_RGBA16_FLOAT
        case .rg16Float: GRACIA_COLOR_FORMAT_RG16_FLOAT
        case .rgba32Float: GRACIA_COLOR_FORMAT_RGBA32_FLOAT
        }
    }

    /// The colour attachment format this maps to. No BGRA exists, so `MTKView`'s default `.bgra8Unorm` won't work.
    public var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .rgba8Unorm: .rgba8Unorm
        case .rgba8Srgb: .rgba8Unorm_srgb
        case .rgba16Float: .rgba16Float
        case .rg16Float: .rg16Float
        case .rgba32Float: .rgba32Float
        }
    }
}

/// Depth-24 is deliberately absent (unsupported on iOS/visionOS/Apple silicon). Use ``d32FloatS8Uint`` for stencil.
public enum DepthFormat: Sendable {
    case undefined, d16Unorm, d32Float, d32FloatS8Uint

    fileprivate var raw: GraciaDepthFormat {
        switch self {
        case .undefined: GRACIA_DEPTH_FORMAT_UNDEFINED
        case .d16Unorm: GRACIA_DEPTH_FORMAT_D16_UNORM
        case .d32Float: GRACIA_DEPTH_FORMAT_D32_FLOAT
        case .d32FloatS8Uint: GRACIA_DEPTH_FORMAT_D32_FLOAT_S8_UINT
        }
    }

    /// `.invalid` for `.undefined` — what `MTKView.depthStencilPixelFormat` wants with no depth attachment.
    public var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .undefined: .invalid
        case .d16Unorm: .depth16Unorm
        case .d32Float: .depth32Float
        case .d32FloatS8Uint: .depth32Float_stencil8
        }
    }
}

public enum CompareOp: Sendable {
    case never, less, equal, lessOrEqual, greater, notEqual, greaterOrEqual, always

    fileprivate var raw: GraciaCompareOp {
        switch self {
        case .never: GRACIA_COMPARE_OP_NEVER
        case .less: GRACIA_COMPARE_OP_LESS
        case .equal: GRACIA_COMPARE_OP_EQUAL
        case .lessOrEqual: GRACIA_COMPARE_OP_LESS_OR_EQUAL
        case .greater: GRACIA_COMPARE_OP_GREATER
        case .notEqual: GRACIA_COMPARE_OP_NOT_EQUAL
        case .greaterOrEqual: GRACIA_COMPARE_OP_GREATER_OR_EQUAL
        case .always: GRACIA_COMPARE_OP_ALWAYS
        }
    }
}

public enum StereoMode: Sendable {
    case multipass, multiview, multilayer

    fileprivate var raw: GraciaStereoMode {
        switch self {
        case .multipass: GRACIA_STEREO_MODE_MULTIPASS
        case .multiview: GRACIA_STEREO_MODE_MULTIVIEW
        case .multilayer: GRACIA_STEREO_MODE_MULTILAYER
        }
    }

    fileprivate init(_ raw: GraciaStereoMode) {
        switch raw {
        case GRACIA_STEREO_MODE_MULTIVIEW: self = .multiview
        case GRACIA_STEREO_MODE_MULTILAYER: self = .multilayer
        default: self = .multipass
        }
    }
}

// MARK: - Pass descriptors

/// Depth attachment state. `.undefined` means no depth attachment.
public struct DepthDescription: Sendable {
    public var format: DepthFormat
    public var test: Bool
    public var write: Bool
    public var compareOp: CompareOp
    public var clamp: Bool

    public init(
        format: DepthFormat, test: Bool, write: Bool, compareOp: CompareOp, clamp: Bool = false
    ) {
        self.format = format
        self.test = test
        self.write = write
        self.compareOp = compareOp
        self.clamp = clamp
    }

    public static let none = DepthDescription(
        format: .undefined, test: false, write: false, compareOp: .less)

    /// Splats write depth (for later passes) but never test it; a depth attachment also selects the tile path. See README.
    public static func splats(format: DepthFormat, reverseZ: Bool) -> DepthDescription {
        DepthDescription(
            format: format, test: false, write: true, compareOp: reverseZ ? .greater : .less)
    }

    /// Depth state for the proxy-mesh pass: tests and writes.
    public static func mesh(format: DepthFormat, reverseZ: Bool) -> DepthDescription {
        DepthDescription(
            format: format, test: true, write: true, compareOp: reverseZ ? .greater : .less)
    }

    fileprivate var raw: GraciaDepthDescription {
        GraciaDepthDescription(
            format: format.raw, test: test, write: write, compareOp: compareOp.raw, clamp: clamp)
    }
}

/// The render pass the draw calls execute into. `colorFormat` and `sampleCount` must match the
/// encoder's attachments exactly, or Metal rejects the pipeline.
public struct SplatsPassDescriptor: Sendable {
    public var colorFormat: ColorFormat
    public var depth: DepthDescription
    public var sampleCount: UInt32
    public var stereo: StereoMode
    /// Stereo mode of the auxiliary linear-depth pass, which the SDK emits regardless.
    public var depthStereo: StereoMode

    public init(
        colorFormat: ColorFormat = .rgba8Unorm,
        depth: DepthDescription = .none,
        sampleCount: UInt32 = 1,
        stereo: StereoMode = .multipass,
        depthStereo: StereoMode = .multipass
    ) {
        self.colorFormat = colorFormat
        self.depth = depth
        self.sampleCount = sampleCount
        self.stereo = stereo
        self.depthStereo = depthStereo
    }

    /// 8-bit RGBA drawable + 16-bit reverse-Z depth; the depth attachment selects the tile path.
    public static let viewer = SplatsPassDescriptor(
        colorFormat: .rgba8Unorm, depth: .splats(format: .d16Unorm, reverseZ: true))

    /// True when the depth state was built for a reverse-Z projection.
    public var usesReverseZ: Bool {
        depth.compareOp == .greater || depth.compareOp == .greaterOrEqual
    }

    public var hasDepthAttachment: Bool { depth.format != .undefined }

    /// Reverse-Z clears to 0 (near maps to 1); a conventional projection clears to 1.
    public var clearDepth: Double { usesReverseZ ? 0 : 1 }

    /// The colour attachment format this pass's pipeline is built for; `MTKView` must be set to it.
    public var metalColorPixelFormat: MTLPixelFormat { colorFormat.metalPixelFormat }

    /// `.invalid` when the pass has no depth attachment.
    public var metalDepthPixelFormat: MTLPixelFormat { depth.format.metalPixelFormat }

    fileprivate var raw: GraciaRendererSplatsPass {
        GraciaRendererSplatsPass(
            colorFormat: colorFormat.raw, depth: depth.raw, sampleCount: sampleCount,
            stereo: stereo.raw, depthStereo: depthStereo.raw, fragmentDensityMap: false)
    }
}

/// Optional motion-vector pass. Omit it and the SDK emits no motion draw calls.
public struct MotionPassDescriptor: Sendable {
    public var colorFormat: ColorFormat
    public var depth: DepthDescription
    public var invertPositionY: Bool
    public var invertColorY: Bool
    public var sampleCount: UInt32
    public var stereo: StereoMode

    public init(
        colorFormat: ColorFormat = .rg16Float, depth: DepthDescription = .none,
        invertPositionY: Bool = false, invertColorY: Bool = false, sampleCount: UInt32 = 1,
        stereo: StereoMode = .multipass
    ) {
        self.colorFormat = colorFormat
        self.depth = depth
        self.invertPositionY = invertPositionY
        self.invertColorY = invertColorY
        self.sampleCount = sampleCount
        self.stereo = stereo
    }

    fileprivate var raw: GraciaRendererMotionPass {
        GraciaRendererMotionPass(
            colorFormat: colorFormat.raw, depth: depth.raw, invertPosY: invertPositionY,
            invertColorY: invertColorY, sampleCount: sampleCount, stereo: stereo.raw, fragmentDensityMap: false)
    }
}

/// Optional proxy-mesh pass. Omit it and the SDK emits no mesh draw calls.
public struct MeshPassDescriptor: Sendable {
    public var colorFormat: ColorFormat
    public var depth: DepthDescription
    /// Negates clip-space Y in the mesh shader — for backends whose NDC has +Y down.
    public var invertPositionY: Bool
    public var disableColorWrite: Bool
    public var sampleCount: UInt32
    public var stereo: StereoMode

    public init(
        colorFormat: ColorFormat = .rgba8Unorm, depth: DepthDescription = .none,
        invertPositionY: Bool = false, disableColorWrite: Bool = false,
        sampleCount: UInt32 = 1, stereo: StereoMode = .multipass
    ) {
        self.colorFormat = colorFormat
        self.depth = depth
        self.invertPositionY = invertPositionY
        self.disableColorWrite = disableColorWrite
        self.sampleCount = sampleCount
        self.stereo = stereo
    }

    fileprivate var raw: GraciaRendererMeshPass {
        GraciaRendererMeshPass(
            colorFormat: colorFormat.raw, depth: depth.raw, invertPosY: invertPositionY,
            disableColorWrite: disableColorWrite, sampleCount: sampleCount, stereo: stereo.raw, fragmentDensityMap: false)
    }
}

/// Metal imageblock sizing for the tile-shading splat path.
public struct MetalTileSettings: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var imageblockSampleLength: UInt32
}

// MARK: - Context

/// Owns the SDK session: the GPU context and an optional on-disk cache.
///
/// The SDK holds device and queue as `__unsafe_unretained`, so this class keeps them alive.
public final class GraciaContext {
    fileprivate let raw: UnsafeMutableRawPointer
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue

    public init(
        device: any MTLDevice, commandQueue: any MTLCommandQueue, cacheDirectory: URL? = nil
    ) throws {
        var desc = GraciaContextDescriptor()
        desc.device = Unmanaged.passUnretained(device)
        desc.commandQueue = Unmanaged.passUnretained(commandQueue)

        let created: UnsafeMutableRawPointer? =
            if let dir = cacheDirectory {
                dir.path.withCString { gracia_context_create(&desc, $0) }
            } else {
                gracia_context_create(&desc, nil)
            }

        guard let created else { throw GraciaError.contextCreationFailed }
        self.raw = created
        self.device = device
        self.commandQueue = commandQueue
    }

    deinit { gracia_context_destroy(raw) }

    public var gpuAllocatedBytes: UInt64 { gracia_context_gpu_allocated_bytes(raw) }

    /// Blocks until every command buffer on this queue completes. Call before destroying a renderer
    /// or scene, or in-flight completion handlers dereference freed memory.
    public func waitUntilIdle() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}

// MARK: - Scene

/// A loaded scene: static splats (`.ply`, `.sog`) or volumetric video (`.mint`, `.grv`).
///
/// The C API splits these across `gracia_static_splats_*` and `gracia_video_stream_*`; one type
/// wraps both via a function table.
public final class Scene {
    /// The formats, named as their extensions are. `mint` and `grv` are volumetric video.
    public enum Kind: String, Sendable, CaseIterable {
        case ply, guf, sog, mint, grv

        public var isVideo: Bool { self == .mint || self == .grv }

        fileprivate var contentType: GraciaContentType {
            switch self {
            case .ply: GRACIA_CONTENT_PLY
            case .guf: GRACIA_CONTENT_GUF
            case .sog: GRACIA_CONTENT_SOG
            case .mint: GRACIA_CONTENT_MINT
            // Only static content takes a content type, and the C API names no `.grv`.
            case .grv: GRACIA_CONTENT_UNKNOWN
            }
        }
    }

    /// Extensions an open panel or drag-and-drop should accept.
    public static let supportedExtensions = Set(Kind.allCases.map(\.rawValue))

    /// Whether ``init(url:context:)`` would load this URL, without context/device/GPU work. Needs an
    /// extension; otherwise use ``init(url:kind:context:)``. Only a MINT is also checked for a
    /// version this build reads.
    public static func canLoad(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let kind = Kind(rawValue: url.pathExtension.lowercased()), kind != .mint { return true }
        return mintVersion(url) != 0
    }

    /// 0 when the file is not a MINT this build can read.
    private static func mintVersion(_ url: URL) -> UInt32 {
        url.path.withCString { gracia_video_mint_version_from_file($0) }
    }

    fileprivate let handle: UnsafeMutableRawPointer
    private let api: API

    public let url: URL
    public let kind: Kind

    // Placeholders until ``isSettled`` — see README, "Late metadata".

    /// In the scene's own space, before any transform set with ``setTransform(_:)``.
    public private(set) var boundingBox: BoundingBox
    /// 10th–90th percentile of splat positions per axis (stray splats don't inflate it); equals ``boundingBox`` for video.
    public private(set) var adaptiveBBox: BoundingBox
    /// Splats this scene needs from the renderer's budget.
    public private(set) var splatsBudget: UInt32
    /// Seconds; 0 for static content.
    public private(set) var duration: Double

    /// True once the three above are real. See README, "Late metadata".
    public var isSettled: Bool {
        splatsBudget > 0 && boundingBox.isValid && (!isVideo || duration > 0)
    }

    public var isVideo: Bool { kind.isVideo }
    public var name: String { url.lastPathComponent }

    private init(
        handle: UnsafeMutableRawPointer, api: API, url: URL, kind: Kind,
        boundingBox: BoundingBox, adaptiveBBox: BoundingBox,
        splatsBudget: UInt32, duration: Double
    ) {
        self.handle = handle
        self.api = api
        self.url = url
        self.kind = kind
        self.boundingBox = boundingBox
        self.adaptiveBBox = adaptiveBBox
        self.splatsBudget = splatsBudget
        self.duration = duration
    }

    deinit { api.destroy(handle) }

    /// Loads any supported scene, format from the extension; anything else is tried as MINT.
    public convenience init(url: URL, context: GraciaContext) throws {
        let kind = Kind(rawValue: url.pathExtension.lowercased())
        try self.init(url: url, kind: kind ?? .mint, context: context)
    }

    /// Loads a scene whose format the caller knows — content stored under its id has no extension.
    public convenience init(url: URL, kind: Kind, context: GraciaContext) throws {
        if kind.isVideo {
            try self.init(videoURL: url, kind: kind, context: context)
        } else {
            try self.init(staticURL: url, kind: kind, context: context)
        }
    }

    private convenience init(staticURL url: URL, kind: Kind, context: GraciaContext) throws {
        guard
            let handle = url.path.withCString({
                gracia_static_splats_create(context.raw, nil, $0, kind.contentType)
            })
        else { throw GraciaError.loadFailed(url) }

        let count = gracia_static_splats_count(handle)
        guard count > 0 else {
            gracia_static_splats_destroy(handle)
            throw GraciaError.loadFailed(url)
        }

        self.init(
            handle: handle, api: .staticSplats, url: url, kind: kind,
            boundingBox: BoundingBox(gracia_static_splats_bbox(handle)),
            adaptiveBBox: BoundingBox(gracia_static_splats_adaptive_bbox(handle)),
            splatsBudget: count, duration: 0)
    }

    private convenience init(videoURL url: URL, kind: Kind, context: GraciaContext) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GraciaError.loadFailed(url)
        }
        // A `.grv` as its caller names it; a MINT named `.mint`, or actually one despite no extension.
        guard
            kind == .grv || url.pathExtension.lowercased() == Kind.mint.rawValue
                || Scene.mintVersion(url) != 0
        else { throw GraciaError.unsupportedFile(url) }

        guard
            let handle = url.path.withCString({
                gracia_video_stream_create(context.raw, nil, $0, false)
            })
        else { throw GraciaError.loadFailed(url) }

        // Authored bounds: readable before the first frame decodes, unlike the stream's own. A `.grv`
        // states its bounds in its head, which lands after opening.
        let authored = kind == .mint ? Scene.layoutBoundingBox(url) : nil
        self.init(
            handle: handle, api: .videoStream, url: url, kind: kind,
            boundingBox: authored ?? BoundingBox(gracia_video_stream_bbox(handle)),
            adaptiveBBox: authored ?? BoundingBox(gracia_video_stream_adaptive_bbox(handle)),
            splatsBudget: UInt32(clamping: gracia_video_stream_max_splats_count(handle)),
            duration: gracia_video_stream_duration(handle))
    }

    /// An HTTP(S) MINT stream. Give the context a `cacheDirectory` for on-disk chunk caching.
    public convenience init(streamURL: String, context: GraciaContext, token: String? = nil) throws {
        let url = URL(string: streamURL) ?? URL(fileURLWithPath: streamURL)
        let handle: UnsafeMutableRawPointer? = streamURL.withCString { cURL in
            if let token {
                token.withCString { gracia_video_stream_create_from_url(context.raw, cURL, $0) }
            } else {
                gracia_video_stream_create_from_url(context.raw, cURL, nil)
            }
        }
        guard let handle else { throw GraciaError.loadFailed(url) }
        self.init(
            handle: handle, api: .videoStream, url: url, kind: .mint,
            boundingBox: BoundingBox(gracia_video_stream_bbox(handle)),
            adaptiveBBox: BoundingBox(gracia_video_stream_adaptive_bbox(handle)),
            splatsBudget: UInt32(clamping: gracia_video_stream_max_splats_count(handle)),
            duration: gracia_video_stream_duration(handle))
    }

    private static func layoutBoundingBox(_ url: URL) -> BoundingBox? {
        guard let desc = url.path.withCString({ gracia_video_desc_create(nil, $0) }) else {
            return nil
        }
        defer { gracia_video_desc_destroy(desc) }
        let bbox = BoundingBox(gracia_video_desc_bbox(desc))
        return bbox.isValid ? bbox : nil
    }

    // MARK: Appearance

    /// Model matrix placing this scene in the world.
    public func setTransform(_ m: simd_float4x4) {
        var cols = m.columnMajor
        cols.withUnsafeMutableBufferPointer { api.setTransform(handle, $0.baseAddress) }
    }

    /// 4 x vec4 of irradiance-scaled environment SH, or `nil` to disable.
    public func setEnvironmentSH(_ sh: [Float]?) {
        guard let sh else { return api.setEnvSH(handle, nil) }
        precondition(sh.count == 16, "env SH must be 16 floats (4 x vec4)")
        sh.withUnsafeBufferPointer { api.setEnvSH(handle, $0.baseAddress) }
    }

    public func setColorGrade(hue: Float, saturation: Float, value: Float, weight: Float) {
        api.setColorGrade(handle, hue, saturation, value, weight)
    }

    public func setVisibility(_ v: Float) { api.setVisibility(handle, v) }

    public func setFlag(_ key: String, _ value: Bool) {
        key.withCString { api.setFlag(handle, $0, value) }
    }

    /// Min/max per axis in `[-1, 1]` relative to ``boundingBox``; `falloff` in `[0, 1]`.
    public func setBBoxMask(min lo: SIMD3<Float>, max hi: SIMD3<Float>, falloff: Float) {
        api.setBboxMask(handle, lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, falloff)
    }

    public func clearBBoxMask() { api.clearBboxMask(handle) }

    // MARK: Playback (video only; no-ops otherwise)

    /// Targets a frame. Call once per frame, before rendering.
    public func setTime(_ t: Double) {
        guard isVideo else { return }
        gracia_video_stream_set_time(handle, t)
    }

    /// Drives the streaming/decode state machine (the only entry point that does). Call once per
    /// frame; returns true once the stream has frames to draw.
    @discardableResult
    public func pump() -> Bool {
        guard isVideo else { return false }
        if !isSettled { settle() }
        return gracia_video_stream_ready(handle)
    }

    /// Takes whatever metadata has landed; the rest still reads 0, or an inverted box.
    private func settle() {
        if duration == 0 { duration = gracia_video_stream_duration(handle) }
        if splatsBudget == 0 {
            splatsBudget = UInt32(clamping: gracia_video_stream_max_splats_count(handle))
        }
        if !boundingBox.isValid {
            boundingBox = BoundingBox(gracia_video_stream_bbox(handle))
            adaptiveBBox = BoundingBox(gracia_video_stream_adaptive_bbox(handle))
        }
    }

    public func setPlaybackRange(_ range: ClosedRange<Double>) {
        guard isVideo else { return }
        gracia_video_stream_set_playback_start(handle, range.lowerBound)
        gracia_video_stream_set_playback_end(handle, range.upperBound)
    }

    // MARK: Audio

    /// The MP3 muxed into a MINT; `nil` for static/silent content and until ``isSettled``. The SDK
    /// plays nothing — feed an `AVAudioPlayer` from the playhead you advance.
    public var audioData: Data? {
        guard isVideo else { return nil }
        let size = gracia_video_stream_audio_size(handle)
        guard size > 0 else { return nil }

        var data = Data(count: Int(size))
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return gracia_video_stream_audio_read(handle, base.assumingMemoryBound(to: CChar.self))
        }
        return ok ? data : nil
    }
}

/// Static and video handles expose the same setters under different C symbols; captured once so they
/// can't diverge. All fields are C function pointers, safe to share.
private struct API: @unchecked Sendable {
    let destroy: (UnsafeMutableRawPointer?) -> Void
    let setTransform: (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?) -> Void
    let setEnvSH: (UnsafeMutableRawPointer?, UnsafePointer<Float>?) -> Void
    let setColorGrade: (UnsafeMutableRawPointer?, Float, Float, Float, Float) -> Void
    let setFlag: (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Bool) -> Void
    let setVisibility: (UnsafeMutableRawPointer?, Float) -> Void
    let setBboxMask:
        (UnsafeMutableRawPointer?, Float, Float, Float, Float, Float, Float, Float) -> Void
    let clearBboxMask: (UnsafeMutableRawPointer?) -> Void

    static let staticSplats = API(
        destroy: gracia_static_splats_destroy,
        setTransform: gracia_static_splats_set_transform,
        setEnvSH: gracia_static_splats_set_env_sh,
        setColorGrade: gracia_static_splats_set_color_grade,
        setFlag: gracia_static_splats_set_flag,
        setVisibility: gracia_static_splats_set_visibility,
        setBboxMask: gracia_static_splats_set_bbox_mask,
        clearBboxMask: gracia_static_splats_clear_bbox_mask)

    static let videoStream = API(
        destroy: gracia_video_stream_destroy,
        setTransform: gracia_video_stream_set_transform,
        setEnvSH: gracia_video_stream_set_env_sh,
        setColorGrade: gracia_video_stream_set_color_grade,
        setFlag: gracia_video_stream_set_flag,
        setVisibility: gracia_video_stream_set_visibility,
        setBboxMask: gracia_video_stream_set_bbox_mask,
        clearBboxMask: gracia_video_stream_clear_bbox_mask)
}

// MARK: - Scene group

/// Several scenes as one: union bbox, summed splat budget, one playback clock.
/// Read from the scenes each time, not snapshotted — a video's numbers arrive late.
public final class SceneGroup {
    public let scenes: [Scene]

    /// Union of the scenes' own bounds, before any transform.
    public var boundingBox: BoundingBox {
        scenes.dropFirst().reduce(scenes.first?.boundingBox ?? .empty) { $0.union($1.boundingBox) }
    }

    /// Union of the scenes' ``Scene/adaptiveBBox``.
    public var adaptiveBBox: BoundingBox {
        scenes.dropFirst().reduce(scenes.first?.adaptiveBBox ?? .empty) { $0.union($1.adaptiveBBox) }
    }

    /// What a renderer compositing all of them at once needs. Saturates rather than wrapping.
    public var splatsBudget: UInt32 {
        UInt32(clamping: scenes.reduce(UInt64(0)) { $0 + UInt64($1.splatsBudget) })
    }

    /// The shortest video duration, so the clock never runs past a scene's last frame; 0 for static content or until metadata lands.
    public var duration: Double {
        scenes.lazy.map(\.duration).filter { $0 > 0 }.min() ?? 0
    }

    /// True once every scene knows its own numbers.
    public var isSettled: Bool { scenes.allSatisfy(\.isSettled) }

    public var isEmpty: Bool { scenes.isEmpty }

    /// Not `duration > 0`: a stream is a video before it can say how long it is.
    public var hasVideo: Bool { scenes.contains(where: \.isVideo) }

    public init(_ scenes: [Scene]) {
        self.scenes = scenes
    }

    /// Model matrix for every scene in the group.
    public func setTransform(_ m: simd_float4x4) {
        for scene in scenes { scene.setTransform(m) }
    }

    /// Targets a frame on every video scene. Call once per frame, before rendering.
    public func setTime(_ t: Double) {
        for scene in scenes { scene.setTime(t) }
    }

    /// Drives every video's decode state machine. True once all have frames to draw; a group with no video is always ready.
    @discardableResult
    public func pump() -> Bool {
        var ready = true
        for scene in scenes where scene.isVideo {
            // Every stream must be pumped; don't short-circuit.
            let sceneReady = scene.pump()
            ready = ready && sceneReady
        }
        return ready
    }

    public func setPlaybackRange(_ range: ClosedRange<Double>) {
        for scene in scenes { scene.setPlaybackRange(range) }
    }

    // MARK: Appearance (each fans out to every scene)

    /// Sets an internal flag on every scene. See ``Scene/setFlag(_:_:)``.
    public func setFlag(_ key: String, _ value: Bool) {
        for scene in scenes { scene.setFlag(key, value) }
    }

    public func setVisibility(_ v: Float) {
        for scene in scenes { scene.setVisibility(v) }
    }

    public func setColorGrade(hue: Float, saturation: Float, value: Float, weight: Float) {
        for scene in scenes {
            scene.setColorGrade(hue: hue, saturation: saturation, value: value, weight: weight)
        }
    }

    public func setEnvironmentSH(_ sh: [Float]?) {
        for scene in scenes { scene.setEnvironmentSH(sh) }
    }

    public func setBBoxMask(min lo: SIMD3<Float>, max hi: SIMD3<Float>, falloff: Float) {
        for scene in scenes { scene.setBBoxMask(min: lo, max: hi, falloff: falloff) }
    }

    public func clearBBoxMask() {
        for scene in scenes { scene.clearBBoxMask() }
    }
}

extension BoundingBox {
    /// The identity for ``union(_:)``.
    public static let empty = BoundingBox(
        min: SIMD3(repeating: .greatestFiniteMagnitude),
        max: SIMD3(repeating: -.greatestFiniteMagnitude))
}

// MARK: - Draw calls

/// One recorded batch of GPU commands, owned by the caller and freed on `deinit`.
///
/// `render` hands back a heap handle per pass and view; every non-null one must be destroyed even if
/// never executed, or it leaks.
public final class DrawCalls {
    private let raw: UnsafeMutableRawPointer

    fileprivate init(raw: UnsafeMutableRawPointer) { self.raw = raw }

    deinit { gracia_draw_call_destroy(raw) }

    /// Records the batch into an open render encoder, whose attachments must match the batch's pass descriptor.
    public func execute(into encoder: any MTLRenderCommandEncoder) {
        var pass = GraciaRenderPass()
        pass.encoder = Unmanaged.passUnretained(encoder)
        gracia_draw_call_execute(raw, pass)
    }
}

/// One pass's draw calls, one entry per view (1 mono, 2 stereo).
public struct PassDrawCalls {
    public let views: [DrawCalls?]
    public let stereo: StereoMode

    /// The single view of a mono frame.
    public var mono: DrawCalls? { views.first ?? nil }

    fileprivate init(_ pass: GraciaPassDrawCalls) {
        // `views` is a fixed 2-slot C array; viewCount says how many are meaningful.
        let raw = [pass.views.0, pass.views.1]
        views = (0..<Int(Swift.min(pass.viewCount, 2))).map { raw[$0].map(DrawCalls.init(raw:)) }
        stereo = StereoMode(pass.stereoMode)
    }
}

/// Draw calls for one frame, split by pass. Batches free on deinit, so hold the frame until its
/// command buffer completes.
///
/// `depth` is a separate linear-depth target emitted regardless of configuration, so even a
/// colour-only caller must free it. `motion` and `mesh` are empty unless their descriptors were supplied.
public final class Frame: @unchecked Sendable {
    public let color: PassDrawCalls
    public let depth: PassDrawCalls
    public let motion: PassDrawCalls
    public let mesh: PassDrawCalls
    /// True while a video scene is still fetching the frames it needs.
    public let buffering: Bool

    fileprivate init(_ raw: GraciaDrawCalls) {
        color = PassDrawCalls(raw.color)
        depth = PassDrawCalls(raw.depth)
        motion = PassDrawCalls(raw.motion)
        mesh = PassDrawCalls(raw.mesh)
        buffering = raw.buffering
    }

    fileprivate static let empty = Frame(GraciaDrawCalls())
}

/// Camera for one view. Both matrices column-major; `cameraToWorld` is *not* the view matrix — the
/// SDK inverts it. See ``GraciaMatrix``.
public struct RenderView: Sendable {
    public var projection: simd_float4x4
    public var cameraToWorld: simd_float4x4

    public init(projection: simd_float4x4, cameraToWorld: simd_float4x4) {
        self.projection = projection
        self.cameraToWorld = cameraToWorld
    }
}

// MARK: - Renderer

public final class SplatsRenderer {
    private let raw: UnsafeMutableRawPointer
    private let context: GraciaContext
    public let maxSplatsCount: UInt32

    /// - Parameter maxSplatsCount: fixed at creation; buffers sized once, never resized, over-budget not clamped.
    public init(context: GraciaContext, maxSplatsCount: UInt32, vr: Bool = false, legacyPipeline: Bool = false) throws {
        guard let created = gracia_splats_renderer_create(context.raw, maxSplatsCount, vr, legacyPipeline) else {
            throw GraciaError.rendererCreationFailed
        }
        self.raw = created
        self.context = context
        self.maxSplatsCount = maxSplatsCount
    }

    deinit { gracia_splats_renderer_destroy(raw) }

    /// Mono convenience overload.
    public func render(
        scenes: [Scene], view: RenderView, targetWidth: UInt32, targetHeight: UInt32,
        pass: SplatsPassDescriptor, motion: MotionPassDescriptor? = nil,
        mesh: MeshPassDescriptor? = nil, locomotion: simd_float4x4? = nil,
        commandBuffer: any MTLCommandBuffer
    ) -> Frame {
        render(
            scenes: scenes, views: [view], targetWidth: targetWidth, targetHeight: targetHeight,
            pass: pass, motion: motion, mesh: mesh, locomotion: locomotion,
            commandBuffer: commandBuffer)
    }

    /// Encodes the sort/preprocess compute work into `commandBuffer` and returns the draw calls to record afterwards.
    ///
    /// Must be called with **no encoder open** on `commandBuffer` — the SDK opens its own compute
    /// encoders. Create the render encoder only after this returns, via ``makeRenderCommandEncoder(_:descriptor:pass:)``.
    ///
    /// - Parameter views: one for mono, two for stereo (needs `vr: true` at init).
    public func render(
        scenes: [Scene], views: [RenderView], targetWidth: UInt32, targetHeight: UInt32,
        pass: SplatsPassDescriptor, motion: MotionPassDescriptor? = nil,
        mesh: MeshPassDescriptor? = nil, locomotion: simd_float4x4? = nil,
        commandBuffer: any MTLCommandBuffer
    ) -> Frame {
        guard !scenes.isEmpty, let first = views.first else { return .empty }
        precondition(views.count <= 2, "at most two views (left/right eye)")
        let second = views.count > 1 ? views[1] : first

        var objects = scenes.map { GraciaSplatsObject(ptr: $0.handle, isVideo: $0.isVideo) }
        var splatsPass = pass.raw
        var motionPass = motion?.raw
        var meshPass = mesh?.raw
        var locomotionFloats = locomotion?.columnMajor

        // Both C view slots are always filled, so mono never reads garbage from views[1]. Separate
        // locals: nesting `withUnsafeMutableBufferPointer` over one array's elements violates exclusivity.
        var proj0 = first.projection.columnMajor
        var proj1 = second.projection.columnMajor
        var cam0 = first.cameraToWorld.columnMajor
        var cam1 = second.cameraToWorld.columnMajor

        var cb = GraciaCommandBuffer()
        cb.handle = Unmanaged.passUnretained(commandBuffer)

        let raw = proj0.withUnsafeMutableBufferPointer { p0 in
            proj1.withUnsafeMutableBufferPointer { p1 in
                cam0.withUnsafeMutableBufferPointer { c0 in
                    cam1.withUnsafeMutableBufferPointer { c1 in
                        var projPtrs = [p0.baseAddress, p1.baseAddress]
                        var viewPtrs = [c0.baseAddress, c1.baseAddress]
                        return projPtrs.withUnsafeMutableBufferPointer { pp in
                            viewPtrs.withUnsafeMutableBufferPointer { vv in
                                objects.withUnsafeMutableBufferPointer { objs in
                                    // NULL locomotion is read as identity.
                                    withOptionalFloats(&locomotionFloats) { loco in
                                        withOptionalPointer(&motionPass) { mo in
                                            withOptionalPointer(&meshPass) { me in
                                                gracia_splats_renderer_render(
                                                    self.raw, objs.baseAddress,
                                                    UInt32(objs.count),
                                                    pp.baseAddress, vv.baseAddress, loco,
                                                    targetWidth, targetHeight, views.count > 1,
                                                    &splatsPass, mo, me, cb)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return Frame(raw)
    }

    /// Opens the render encoder for a frame's draw calls, applying what the SDK's chosen pipeline needs. Call after `render(...)`, never before.
    public func makeRenderCommandEncoder(
        _ commandBuffer: any MTLCommandBuffer, descriptor: MTLRenderPassDescriptor,
        pass: SplatsPassDescriptor
    ) -> (any MTLRenderCommandEncoder)? {
        applyTileSettings(to: descriptor, for: pass)
        return commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    }

    /// Applies the tile-shading geometry a depth-attachment pass needs; returns it, or `nil` otherwise. See README.
    @discardableResult
    public func applyTileSettings(
        to descriptor: MTLRenderPassDescriptor, for pass: SplatsPassDescriptor
    ) -> MetalTileSettings? {
        guard let tile = metalTileSettings(for: pass) else { return nil }
        descriptor.tileWidth = Int(tile.width)
        descriptor.tileHeight = Int(tile.height)
        descriptor.imageblockSampleLength = Int(tile.imageblockSampleLength)
        return tile
    }

    /// `nil` when the pass has no depth attachment, and so no imageblock tile path.
    public func metalTileSettings(for pass: SplatsPassDescriptor) -> MetalTileSettings? {
        var splatsPass = pass.raw
        let s = gracia_splats_renderer_metal_tile_settings(raw, &splatsPass)
        guard s.width > 0, s.height > 0 else { return nil }
        return MetalTileSettings(
            width: s.width, height: s.height, imageblockSampleLength: s.imageblockSampleLength)
    }

    /// Valid keys: `portals_enabled`, `splats_count_readback`.
    public func setFlag(_ key: String, _ value: Bool) {
        key.withCString { gracia_splats_renderer_set_flag(raw, $0, value) }
    }

    /// Valid keys: `opacity_threshold`, `head_bounds_half`.
    public func setFloat(_ key: String, _ value: Float) {
        key.withCString { gracia_splats_renderer_set_float(raw, $0, value) }
    }

    /// Splats that survived culling last frame; reads 0 unless the `splats_count_readback` flag is set.
    public var visibleSplatsCount: UInt32 { gracia_splats_renderer_read_visible_splats_count(raw) }

    public func requestPick(ndcX: Float, ndcY: Float) {
        gracia_splats_renderer_set_pick_ndc(raw, ndcX, ndcY)
    }

    /// Index of the picked scene and its view-space depth, or `nil` when nothing was hit.
    public func readPickResult() -> (sceneIndex: Int, depth: Float)? {
        var depth: Float = 0
        let index = gracia_splats_renderer_read_pick_result(raw, &depth)
        return index < 0 ? nil : (Int(index), depth)
    }
}

/// Passes a pointer to `value`, or NULL when it is nil.
private func withOptionalPointer<T, R>(_ value: inout T?, _ body: (UnsafePointer<T>?) -> R) -> R {
    guard value != nil else { return body(nil) }
    return withUnsafePointer(to: &value!) { body($0) }
}

private func withOptionalFloats<R>(
    _ value: inout [Float]?, _ body: (UnsafeMutablePointer<Float>?) -> R
) -> R {
    guard value != nil else { return body(nil) }
    return value!.withUnsafeMutableBufferPointer { body($0.baseAddress) }
}
