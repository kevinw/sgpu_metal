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

struct VertexParams {
    device ParamsBlock* paramsBlock;
};

vertex RasterizerData vertexMain(uint vertexID [[vertex_id]], constant VertexParams* vertexParams [[buffer(0)]]) {
    auto paramsBlock = vertexParams->paramsBlock;
    return {
        .position = float4(paramsBlock->positions[vertexID].xy, 0, 1),
        .color = paramsBlock->colors[vertexID],
    };
}
