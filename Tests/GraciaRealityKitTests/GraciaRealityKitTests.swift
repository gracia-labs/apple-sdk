import Foundation
import GraciaSDK
import Metal
import Testing

@testable import GraciaRealityKit

@Suite("GraciaRealityKit")
struct GraciaRealityKitTests {
    @Test func defaultsUseCompact8BitColorAnd16BitDepth() {
        let bridge = GraciaRealityBridge()
        #expect(bridge.colorFormat == .rgba8Unorm)
        #expect(bridge.depthFormat == .d16Unorm)
        #expect(!bridge.vr)
        #expect(!bridge.boundingBox.isValid)
    }

    @Test func controlsClampPlaybackSpeed() {
        let bridge = GraciaRealityBridge()
        bridge.playbackSpeed = 99
        #expect(bridge.playbackSpeed == 8)
        bridge.playbackSpeed = -2
        #expect(bridge.playbackSpeed == 0)
        bridge.load(url: URL(fileURLWithPath: "/tmp/example.sog"))
        bridge.unload()
    }

    @Test(arguments: [false, true])
    func compositorPreservesSrgbSplatsAndBlendsInLinearSpace(usesDepth: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try GraciaRealityBridge.Compositor(device: device)
        guard device.supportsFamily(.apple2) else { return }
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let region = MTLRegionMake2D(0, 0, 3, 1)
        let bytesPerRow = region.size.width * 4

        func makeTexture(_ format: MTLPixelFormat, usage: MTLTextureUsage) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: region.size.width, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = usage
            return try #require(device.makeTexture(descriptor: descriptor))
        }

        let reality = try makeTexture(.bgra8Unorm_srgb, usage: .shaderRead)
        let splats = try makeTexture(.rgba8Unorm, usage: .shaderRead)
        let target = try makeTexture(.bgra8Unorm_srgb, usage: .shaderWrite)
        let realityPixels: [UInt8] = [100, 60, 20, 255, 0, 0, 0, 0, 40, 80, 120, 255]
        let splatPixels: [UInt8] = [128, 64, 8, 255, 64, 32, 16, 128, 0, 0, 0, 0]
        reality.replace(region: region, mipmapLevel: 0, withBytes: realityPixels, bytesPerRow: bytesPerRow)
        splats.replace(region: region, mipmapLevel: 0, withBytes: splatPixels, bytesPerRow: bytesPerRow)

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth16Unorm, width: region.size.width, height: 1, mipmapped: false)
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.shaderRead, .renderTarget]
        let depth = try #require(device.makeTexture(descriptor: depthDescriptor))
        if usesDepth {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.clearDepth = 0.5
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.endEncoding()
        }

        compositor.composite(
            realityColor: reality, realityDepth: usesDepth ? depth : nil, splatColor: splats, splatDepth: depth,
            targetColor: target, reverseZ: true, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)

        var pixels = [UInt8](repeating: 0, count: bytesPerRow)
        target.getBytes(&pixels, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        // Each pixel is in BGRA order. Allow one code value of GPU rounding for RGB.
        let expected = [8, 64, 128, 255, 20, 44, 92, 128, 40, 80, 120, 255]
        for (index, expectedByte) in expected.enumerated() {
            #expect(abs(Int(pixels[index]) - expectedByte) <= (index % 4 == 3 ? 0 : 1))
        }
    }
}
