//
//  Projects an ARKit environment-probe cube map into SH-L1 lighting coefficients.
//
//  ARKit gives no spherical harmonics for a rear-camera (world-tracking) session — only an
//  `AREnvironmentProbeAnchor.environmentTexture` cube map. We sample that cube into a small
//  equirectangular float image (a Metal pass, so any pixel format works), then integrate it on the
//  CPU into four RGB coefficients (SH band 0 + band 1).
//
//  The convention matches three.js `SphericalHarmonics3` / `LightProbeGenerator.fromCubeTexture`,
//  which is what GraciaSDK's `setEnvironmentSH` expects:
//    • basis order [DC, y, z, x], constants 0.282095 and 0.488603
//    • coefficients are RAW radiance projection (the cosine/irradiance convolution — 0.886227 for
//      band 0, 2·0.511664 for band 1 — is applied by the consumer at evaluation, not baked in here)
//    • normalized by 4π / totalWeight, which makes the estimate independent of the sampling scheme.
//

import Metal
import simd

final class EnvironmentProbe {
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let equirect: any MTLTexture
    private let width = 128
    private let height = 64

    init(device: any MTLDevice, queue: any MTLCommandQueue) throws {
        self.queue = queue

        guard let library = device.makeDefaultLibrary(),
            let vertexFn = library.makeFunction(name: "equirectVertex"),
            let fragmentFn = library.makeFunction(name: "equirectFragment")
        else { throw ARSplatError.environmentPipeline }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { throw ARSplatError.environmentPipeline }
        equirect = tex
    }

    /// Renders the cube into the equirect target, reads it back, and integrates SH-L1. Returns four
    /// RGB coefficients in the cube's (world) frame, or nil if the input isn't a usable cube map.
    func project(_ cube: any MTLTexture) -> [SIMD3<Float>]? {
        guard cube.textureType == .typeCube else { return nil }

        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = equirect
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(cube, index: 0)
        var size = SIMD2<Float>(Float(width), Float(height))
        encoder.setFragmentBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        // Probe updates are seconds apart, so a synchronous read-back here is cheap.
        commandBuffer.waitUntilCompleted()

        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            equirect.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        var sh = [SIMD3<Float>](repeating: .zero, count: 4)
        var totalWeight: Float = 0
        for j in 0..<height {
            // Pixel centre → (phi, theta); must match equirectFragment exactly.
            let theta = (Float(j) + 0.5) / Float(height) * .pi
            let sinTheta = sin(theta), cosTheta = cos(theta)
            let weight = sinTheta  // solid-angle weight for an equirectangular grid
            for i in 0..<width {
                let phi = (Float(i) + 0.5) / Float(width) * 2 * .pi
                let dir = SIMD3<Float>(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi))
                let base = (j * width + i) * 4
                let color = SIMD3<Float>(pixels[base], pixels[base + 1], pixels[base + 2])
                // three.js SH basis, order [DC, y, z, x].
                sh[0] += color * (0.282095 * weight)
                sh[1] += color * (0.488603 * dir.y * weight)
                sh[2] += color * (0.488603 * dir.z * weight)
                sh[3] += color * (0.488603 * dir.x * weight)
                totalWeight += weight
            }
        }
        guard totalWeight > 0 else { return nil }
        let norm = (4 * Float.pi) / totalWeight
        for k in 0..<4 { sh[k] *= norm }
        return sh
    }
}
