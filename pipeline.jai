gpu_create_compute_pipeline :: (spirv: [] u8) -> Gpu_Pipeline {
    // TODO: implement me
}

#scope_module

NUM_SHADER_STAGES :: #run enum_values_as_enum(Shader_Stage).count;

Pipeline :: struct {
    type: Pipeline_Type;
    mtl_pipeline: *MTLRenderPipelineState;
}

live_pipelines: Pool(Gpu_Pipeline, Pipeline);


Pipeline_Type :: enum {
    GRAPHICS;
    COMPUTE;
}

Shader_Stage :: enum {
    VERTEX  :: 0x1;
    PIXEL   :: 0x10;
    COMPUTE :: 0x20;
    TASK    :: 0x40;
    MESH    :: 0x80;
}
