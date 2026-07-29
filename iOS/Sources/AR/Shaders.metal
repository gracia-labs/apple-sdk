//
//  Camera-background shaders for AR mode: a full-screen quad textured with ARKit's captured image.
//
//  The splats themselves are drawn by GraciaSDK's own pipelines; the only shader this demo ships is
//  the one that paints the live camera feed behind them. The captured frame is bi-planar
//  YCbCr (full-range 601), so the fragment shader converts to RGB.
//

#include <metal_stdlib>
using namespace metal;

typedef struct {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
} BackgroundVertex;

typedef struct {
    float4 position [[position]];
    float2 texCoord;
} BackgroundInOut;

// The quad is 4 vertices (position in clip space, texCoord already mapped through ARKit's
// display transform on the CPU), fed as a triangle strip via `setVertexBytes`.
vertex BackgroundInOut backgroundVertex(uint vid [[vertex_id]],
                                        constant float4 *quad [[buffer(0)]]) {
    BackgroundInOut out;
    // Each element packs (posX, posY, u, v).
    float4 v = quad[vid];
    out.position = float4(v.xy, 0.0, 1.0);
    out.texCoord = v.zw;
    return out;
}

fragment float4 backgroundFragment(BackgroundInOut in [[stage_in]],
                                   texture2d<float, access::sample> textureY [[texture(0)]],
                                   texture2d<float, access::sample> textureCbCr [[texture(1)]]) {
    constexpr sampler colorSampler(mag_filter::linear, min_filter::linear);

    // ITU-R BT.601, full range — the exact matrix Apple's ARKit Metal sample uses.
    const float4x4 ycbcrToRGBTransform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));

    float4 ycbcr = float4(textureY.sample(colorSampler, in.texCoord).r,
                          textureCbCr.sample(colorSampler, in.texCoord).rg,
                          1.0);
    return ycbcrToRGBTransform * ycbcr;
}

//
//  Environment-probe → SH projection support.
//
//  ARKit hands us the environment as a cube map (AREnvironmentProbeAnchor.environmentTexture), not
//  as SH. We sample it into a small equirectangular float target, then integrate on the CPU into
//  SH-L1 (see ARSplatsRenderer). A full-screen triangle covers the target; the fragment maps each
//  pixel to a world direction and samples the cube. Sampling (not a plain copy) means the cube can
//  be any pixel format.
//

vertex float4 equirectVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 equirectFragment(float4 pos [[position]],
                                 texturecube<float> cube [[texture(0)]],
                                 constant float2 &size [[buffer(0)]]) {
    constexpr sampler cubeSampler(mag_filter::linear, min_filter::linear, mip_filter::linear);
    // Pixel centre → [0,1] → (phi, theta). Must match the CPU's direction on read-back exactly.
    float2 uv = pos.xy / size;
    float phi = uv.x * 2.0 * M_PI_F;
    float theta = uv.y * M_PI_F;
    float sinTheta = sin(theta);
    float3 dir = float3(sinTheta * cos(phi), cos(theta), sinTheta * sin(phi));
    return cube.sample(cubeSampler, dir);
}
