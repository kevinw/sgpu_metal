#include <metal_stdlib>
using namespace metal;

struct RasterizerData {
    float4 position [[position]];
    float4 color;
};

fragment float4 fragmentMain(RasterizerData in [[stage_in]]) {
    return in.color;
}
