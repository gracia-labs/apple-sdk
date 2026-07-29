import Foundation
import Metal
import Testing
import simd

@testable import GraciaSDK

private func ~= (a: Float, b: Float) -> Bool { abs(a - b) < 1e-4 }
private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
    simd_length(a - b) < eps
}

// MARK: - Projection

@Suite("Projection")
struct ProjectionTests {
    private func ndcZ(_ p: simd_float4x4, viewZ: Float) -> Float {
        let clip = p * SIMD4<Float>(0, 0, viewZ, 1)
        return clip.z / clip.w
    }

    /// The renderer clips against 0 <= z <= 1, so the projection must produce zero-to-one depth.
    @Test func zeroToOneDepthRange() {
        let p = GraciaMatrix.perspective(
            fovYDegrees: 90, aspect: 1, near: 1, far: 100, reverseZ: false)
        #expect(ndcZ(p, viewZ: -1) ~= 0)  // near plane
        #expect(ndcZ(p, viewZ: -100) ~= 1)  // far plane
    }

    @Test func reverseZFlipsNearAndFar() {
        let p = GraciaMatrix.perspective(
            fovYDegrees: 90, aspect: 1, near: 1, far: 100, reverseZ: true)
        #expect(ndcZ(p, viewZ: -1) ~= 1)
        #expect(ndcZ(p, viewZ: -100) ~= 0)
        // Still inside the clip volume, so the shader's frustum cull stays valid.
        #expect(ndcZ(p, viewZ: -50) > 0 && ndcZ(p, viewZ: -50) < 1)
    }

    /// Metal's viewport maps NDC +Y to the top row, so no Y flip belongs in the matrix.
    @Test func noYFlip() {
        let projection = GraciaMatrix.perspective(
            fovYDegrees: 90, aspect: 1, near: 0.1, far: 100)
        let cameraToWorld = GraciaMatrix.cameraWorld(eye: .zero, target: SIMD3(0, 0, -1))
        let vp = projection * simd_inverse(cameraToWorld)

        let above = vp * SIMD4<Float>(0, 1, -5, 1)
        let below = vp * SIMD4<Float>(0, -1, -5, 1)
        #expect(above.y / above.w > 0)
        #expect(below.y / below.w < 0)
    }

    @Test func aspectScalesXOnly() {
        let p = GraciaMatrix.perspective(
            fovYDegrees: 90, aspect: 2, near: 1, far: 100, reverseZ: false)
        #expect(p.columns.0.x ~= 0.5)  // 1 / (aspect * tan(45°))
        #expect(p.columns.1.y ~= 1.0)
        #expect(p.columns.2.w ~= -1.0)
    }

    @Test func columnMajorMatchesGLMLayout() {
        let m = simd_float4x4(
            SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16))
        #expect(m.columnMajor == (1...16).map(Float.init))
    }

    @Test func cameraWorldColumnsAreRightUpBackEye() {
        let eye = SIMD3<Float>(0, 0, 5)
        let m = GraciaMatrix.cameraWorld(eye: eye, target: .zero)

        #expect(close(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(1, 0, 0)))
        #expect(close(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3(0, 1, 0)))
        #expect(close(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z), SIMD3(0, 0, 1)))  // back
        #expect(close(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), eye))
    }

    /// `cameraToWorld` is not the view matrix — the SDK inverts it.
    @Test func cameraWorldMapsTheOriginToTheEye() {
        let eye = SIMD3<Float>(1, 2, 3)
        let m = GraciaMatrix.cameraWorld(eye: eye, target: SIMD3(1, 2, 0))
        #expect(close(m.transform(point: .zero), eye))
    }

    /// simd_normalize returns NaN on a zero vector; the fallback semantics must survive.
    @Test func normalizedFallsBackOnZero() {
        #expect(close(normalized(.zero, fallback: SIMD3(0, 0, -1)), SIMD3(0, 0, -1)))
        #expect(close(normalized(SIMD3(0, 3, 0), fallback: SIMD3(1, 0, 0)), SIMD3(0, 1, 0)))
        #expect(close(withLength(.zero, 5, fallback: SIMD3(1, 0, 0)), SIMD3(5, 0, 0)))
    }
}

// MARK: - Pass descriptors

/// The render pass the caller builds must agree with the pipeline the SDK builds from the same
/// descriptor, or Metal rejects the encoder. These pin the mapping.
@Suite("Pass descriptor")
struct PassDescriptorTests {
    @Test func colorFormatsMapToTheMatchingDrawableFormat() {
        // GraciaColorFormat has no BGRA, so MTKView's default .bgra8Unorm can never be used.
        #expect(ColorFormat.rgba8Unorm.metalPixelFormat == .rgba8Unorm)
        #expect(ColorFormat.rgba8Srgb.metalPixelFormat == .rgba8Unorm_srgb)
        #expect(ColorFormat.rgba16Float.metalPixelFormat == .rgba16Float)
        #expect(ColorFormat.rg16Float.metalPixelFormat == .rg16Float)
        #expect(ColorFormat.rgba32Float.metalPixelFormat == .rgba32Float)
    }

    @Test func undefinedDepthMapsToInvalid() {
        #expect(DepthFormat.undefined.metalPixelFormat == .invalid)
        #expect(DepthFormat.d16Unorm.metalPixelFormat == .depth16Unorm)
        #expect(DepthFormat.d32Float.metalPixelFormat == .depth32Float)
    }

    /// Splats resolve their own visibility: they write depth for later passes but never test.
    @Test func splatsDepthWritesButDoesNotTest() {
        let d = DepthDescription.splats(format: .d16Unorm, reverseZ: true)
        #expect(d.test == false)
        #expect(d.write == true)
        #expect(d.compareOp == .greater)

        let mesh = DepthDescription.mesh(format: .d16Unorm, reverseZ: true)
        #expect(mesh.test == true && mesh.write == true)
    }

    @Test func compareOpFollowsTheProjectionZDirection() {
        #expect(DepthDescription.splats(format: .d16Unorm, reverseZ: true).compareOp == .greater)
        #expect(DepthDescription.splats(format: .d16Unorm, reverseZ: false).compareOp == .less)
    }

    /// Reverse-Z maps near to 1, so the buffer clears to 0.
    @Test func clearDepthFollowsTheCompareOp() {
        let reverse = SplatsPassDescriptor(depth: .splats(format: .d16Unorm, reverseZ: true))
        #expect(reverse.usesReverseZ)
        #expect(reverse.clearDepth == 0)
        #expect(reverse.hasDepthAttachment)

        let forward = SplatsPassDescriptor(depth: .splats(format: .d16Unorm, reverseZ: false))
        #expect(!forward.usesReverseZ)
        #expect(forward.clearDepth == 1)
    }

    /// No depth attachment means no imageblock tile path, so no tile settings to apply.
    @Test func passWithoutDepthHasNoAttachment() {
        let plain = SplatsPassDescriptor(depth: .none)
        #expect(!plain.hasDepthAttachment)
        #expect(plain.depth.format.metalPixelFormat == .invalid)
    }

    /// The ready-made viewer pass, and what pins d16 + reverse-Z.
    @Test func viewerPassIsDepth16ReverseZ() {
        let pass = SplatsPassDescriptor.viewer
        #expect(pass.colorFormat == .rgba8Unorm)
        #expect(pass.depth.format == .d16Unorm)
        #expect(pass.hasDepthAttachment)
        #expect(pass.usesReverseZ)
        #expect(pass.clearDepth == 0)
        #expect(pass.sampleCount == 1)
    }
}

// MARK: - Against the real SDK

/// Serialized, and the only suite that touches the GPU: the SDK is not internally synchronized, so
/// two tests creating a context or compiling a pipeline variant at once race, and
/// `gracia_splats_renderer_create` returns null.
@Suite("Live SDK", .serialized)
struct LiveSDKTests {
    /// `nil` when there is no Metal device (headless CI); the tests then no-op.
    private func makeContext() throws -> GraciaContext? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { return nil }
        return try GraciaContext(device: device, commandQueue: queue)
    }

    /// Attaching depth is what selects the Metal imageblock path, and that is the only case where a
    /// render pass needs tile geometry.
    @Test func depthAttachmentSelectsTheTilePath() throws {
        guard let context = try makeContext() else { return }
        let renderer = try SplatsRenderer(context: context, maxSplatsCount: 1024)

        #expect(renderer.metalTileSettings(for: SplatsPassDescriptor(depth: .none)) == nil)

        let settings = try #require(renderer.metalTileSettings(for: .viewer))
        #expect(settings.width == 32 && settings.height == 32)
        #expect(settings.imageblockSampleLength > 0)
    }

    @Test func applyTileSettingsWritesTheDescriptorOnlyForTheTilePath() throws {
        guard let context = try makeContext() else { return }
        let renderer = try SplatsRenderer(context: context, maxSplatsCount: 1024)

        let descriptor = MTLRenderPassDescriptor()
        let untouchedWidth = descriptor.tileWidth

        let plain = SplatsPassDescriptor(depth: .none)
        #expect(renderer.applyTileSettings(to: descriptor, for: plain) == nil)
        #expect(descriptor.tileWidth == untouchedWidth)
        #expect(descriptor.imageblockSampleLength == 0)

        let applied = try #require(renderer.applyTileSettings(to: descriptor, for: .viewer))
        #expect(descriptor.tileWidth == Int(applied.width))
        #expect(descriptor.tileHeight == Int(applied.height))
        #expect(descriptor.imageblockSampleLength == Int(applied.imageblockSampleLength))
    }

    @Test func missingFileFailsToLoad() throws {
        guard let context = try makeContext() else { return }
        let missing = URL(fileURLWithPath: "/nonexistent/scene.ply")
        #expect(throws: GraciaError.self) { try Scene(url: missing, context: context) }
    }

    /// The GPU goes idle without a scene, a renderer, or anything submitted.
    @Test func waitUntilIdleOnAnEmptyQueueReturns() throws {
        guard let context = try makeContext() else { return }
        context.waitUntilIdle()
    }
}

// MARK: - Scene (no GPU)

@Suite("Scene")
struct SceneTests {
    @Test func supportedExtensionsCoverStaticAndVideo() {
        #expect(Scene.supportedExtensions == ["ply", "guf", "sog", "mint"])
    }

    @Test func kindIsNamedAfterTheExtension() {
        #expect(Scene.Kind(rawValue: "sog") == .sog)
        #expect(Scene.Kind(rawValue: "mint") == .mint)
        #expect(Scene.Kind(rawValue: "obj") == nil)
        #expect(Scene.Kind.mint.isVideo)
        #expect(!Scene.Kind.sog.isVideo)
    }

    /// The extension is the only thing `canLoad` has to go on; content stored under a bare id has
    /// none, and takes ``Scene/init(url:kind:context:)`` instead.
    @Test func canLoadRejectsWhatItCannotName() {
        #expect(!Scene.canLoad(URL(fileURLWithPath: "/nonexistent/scene.ply")))
        #expect(!Scene.canLoad(URL(fileURLWithPath: "/nonexistent/9f2c1a")))
    }

    /// A freshly created video stream reports an inverted, uninitialised box.
    @Test func invertedBoundingBoxIsNotValid() {
        let uninitialised = BoundingBox(
            min: SIMD3(repeating: .greatestFiniteMagnitude),
            max: SIMD3(repeating: .leastNormalMagnitude))
        #expect(!uninitialised.isValid)

        let infinite = BoundingBox(min: SIMD3(repeating: 0), max: SIMD3(repeating: .infinity))
        #expect(!infinite.isValid)

        #expect(BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)).isValid)
    }

    /// A video scene's bounds are invalid until its first frame decodes, so a union must not let
    /// that poison the group's framing.
    @Test func unionIgnoresInvalidBoxes() {
        let a = BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(0, 0, 0))
        let b = BoundingBox(min: SIMD3(0, 0, 0), max: SIMD3(2, 3, 4))
        let uninitialised = BoundingBox(
            min: SIMD3(repeating: .greatestFiniteMagnitude),
            max: SIMD3(repeating: .leastNormalMagnitude))

        let u = a.union(b)
        #expect(close(u.min, SIMD3(-1, -1, -1)))
        #expect(close(u.max, SIMD3(2, 3, 4)))

        #expect(a.union(uninitialised) == a)
        #expect(uninitialised.union(a) == a)
        #expect(BoundingBox.empty.union(a) == a)
        #expect(!BoundingBox.empty.isValid)
    }

    @Test func boundingBoxGeometry() {
        let b = BoundingBox(min: SIMD3(-1, -2, -3), max: SIMD3(1, 2, 3))
        #expect(close(b.center, .zero))
        #expect(close(b.size, SIMD3(2, 4, 6)))
        #expect(b.radius ~= simd_length(SIMD3<Float>(2, 4, 6)) * 0.5)
    }
}
