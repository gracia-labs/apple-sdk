//
//  Draws ARKit's captured camera image as a full-screen quad behind the splats.
//
//  `ARFrame.capturedImage` is a bi-planar YCbCr pixel buffer. We wrap each plane as an MTLTexture
//  through a `CVMetalTextureCache` (zero-copy), and the fragment shader converts to RGB. The quad's
//  texture coordinates come from `ARFrame.displayTransform(for:viewportSize:)`, so the image fills
//  the screen with the right crop and orientation.
//

import ARKit
import CoreVideo
import Metal
import simd

final class CameraBackground {
    private let pipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    /// Kept alive for the frame: `CVMetalTextureGetTexture` returns a view whose backing store is
    /// owned by these wrappers, so releasing them early frees the texture out from under the GPU.
    private var retained: [CVMetalTexture] = []

    /// (posX, posY, u, v) per corner, updated every frame from the display transform. Triangle strip.
    private var quad = [SIMD4<Float>](repeating: .zero, count: 4)

    init(device: any MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        guard let library = device.makeDefaultLibrary(),
            let vertexFn = library.makeFunction(name: "backgroundVertex"),
            let fragmentFn = library.makeFunction(name: "backgroundFragment")
        else { throw ARSplatError.backgroundPipeline }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn

        // Destination-over: the splats are already in the drawable (with coverage in alpha), and the
        // camera fills in behind them, weighted by 1 − coverage. So result = splat + camera·(1−α).
        // This is why the camera is drawn AFTER the splats — the SDK's tile resolve replaces the
        // colour attachment rather than blending over it, so a camera drawn first would be erased.
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = colorPixelFormat
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .oneMinusDestinationAlpha
        color.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
        color.destinationRGBBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { throw ARSplatError.textureCache }
        textureCache = cache
    }

    /// Recomputes the quad's texture coordinates for the current frame + viewport. Call once per
    /// frame before ``encode(into:frame:)``.
    func update(frame: ARFrame, orientation: UIInterfaceOrientation, viewportSize: CGSize) {
        // The display transform maps [0,1] image space → viewport; its inverse maps the quad's
        // corners back to the texture coordinates that sample the captured image (Apple's approach).
        let displayToCamera = frame
            .displayTransform(for: orientation, viewportSize: viewportSize)
            .inverted()

        // Clip-space corners paired with their base [0,1] texture coordinate, triangle-strip order.
        let corners: [(pos: SIMD2<Float>, uv: CGPoint)] = [
            (SIMD2(-1, -1), CGPoint(x: 0, y: 1)),
            (SIMD2(1, -1), CGPoint(x: 1, y: 1)),
            (SIMD2(-1, 1), CGPoint(x: 0, y: 0)),
            (SIMD2(1, 1), CGPoint(x: 1, y: 0)),
        ]
        for (i, corner) in corners.enumerated() {
            let t = corner.uv.applying(displayToCamera)
            quad[i] = SIMD4(corner.pos.x, corner.pos.y, Float(t.x), Float(t.y))
        }
    }

    /// Records the background draw into an open render encoder. Must be called after ``update``.
    func encode(into encoder: any MTLRenderCommandEncoder, frame: ARFrame) {
        retained.removeAll(keepingCapacity: true)
        let pixelBuffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
            let textureY = plane(pixelBuffer, 0, .r8Unorm),
            let textureCbCr = plane(pixelBuffer, 1, .rg8Unorm)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 0)
        encoder.setFragmentTexture(textureY, index: 0)
        encoder.setFragmentTexture(textureCbCr, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func plane(
        _ pixelBuffer: CVPixelBuffer, _ index: Int, _ format: MTLPixelFormat
    ) -> (any MTLTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format, width, height, index, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
            let texture = CVMetalTextureGetTexture(cvTexture)
        else { return nil }
        retained.append(cvTexture)
        return texture
    }
}

enum ARSplatError: Error, CustomStringConvertible {
    case backgroundPipeline
    case textureCache
    case environmentPipeline

    var description: String {
        switch self {
        case .backgroundPipeline: return "failed to build the camera-background pipeline"
        case .textureCache: return "failed to create the Metal texture cache"
        case .environmentPipeline: return "failed to build the environment-probe resources"
        }
    }
}
