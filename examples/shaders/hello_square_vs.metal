#include <metal_stdlib>
using namespace metal;


struct RasterizerData {
    float4 position [[position]];
    float4 color;
};


struct ParamsBlock {
    device simd_float2* positions;
    device simd_float4* colors;
};

vertex RasterizerData vertexMain(uint vertexID [[vertex_id]], constant ParamsBlock* paramsBlock [[buffer(0)]]) {
    RasterizerData out;
    out.position.xy = paramsBlock->positions[vertexID].xy;
    out.position.zw = float2(0.0, 1.0);
    out.color = paramsBlock->colors[vertexID];
    out.color.w = 1.0;
    return out;
}
