#include <metal_stdlib>
using namespace metal;

// With MTL4ArgumentTable, the buffer is bound via the argument table
// and accessed at buffer index 0 in the shader
kernel void computeMain(
    device float* outputBuffer [[buffer(0)]],
    uint index [[thread_position_in_grid]])
{
    outputBuffer[index] = 1.0;
}
