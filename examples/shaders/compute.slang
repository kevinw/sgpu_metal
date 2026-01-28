// Metal-compatible compute shader
// Simple shader that writes 1.0 to each element

[shader("compute")]
[numthreads(64, 1, 1)]
void computeMain(uint3 dispatchThreadID : SV_DispatchThreadID,
                 uniform RWStructuredBuffer<float> outputBuffer)
{
    uint index = dispatchThreadID.x;
    outputBuffer[index] = index;
}
