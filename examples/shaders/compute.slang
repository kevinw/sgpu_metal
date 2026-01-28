// Cross-platform bindless compute shader
// Works with both Vulkan (pointer-based) and Metal 4 (argument table)

#ifdef SLANG_HLSL
// For Vulkan: Use raw pointer via push constants (original sgpu approach)
import common;

[[vk::push_constant]]
ComputeParams<float> params;

[shader("compute")]
[numthreads(64)]
void main(uint index: SV_DispatchThreadID) {
    float* p = params.get();
    p[index] = 1.0;
}
#else
// For Metal: Use RWStructuredBuffer bound via MTL4ArgumentTable at [[buffer(0)]]
[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    RWStructuredBuffer<float> outputBuffer)
{
    uint index = dispatchThreadID.x;
    outputBuffer[index] = 1.0;
}
#endif
