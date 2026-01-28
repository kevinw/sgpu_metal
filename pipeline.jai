#scope_export

gpu_create_compute_pipeline :: (metal_source: string) -> Gpu_Pipeline {
    // Create a library from the Metal source code
    ns_source := NSString.initWithBytes(
        objc_alloc(NSString),
        metal_source.data,
        metal_source.count.(NSUInteger),
        NSUTF8StringEncoding
    );
    defer release(ns_source);

    // Create compile options with Metal 3.0 language version
    compile_options := objc_new(MTLCompileOptions);
    defer release(compile_options);
    MTLCompileOptions.setLanguageVersion(compile_options, ._3_0);

    error: *NSError;
    mtl_library := MTLDevice.newLibraryWithSource(mtl_device, ns_source, compile_options, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to compile Metal shader: %", error_str);
        return 0;
    }
    if mtl_library == null {
        log_error("Failed to create Metal library");
        return 0;
    }

    // Get the entry point function from the library
    // Try "computeMain" first (our convention), then fall back to "main"
    function_name := "computeMain";
    main_name := NSString.initWithBytes(
        objc_alloc(NSString),
        function_name.data,
        function_name.count.(NSUInteger),
        NSUTF8StringEncoding
    );
    defer release(main_name);

    mtl_function := MTLLibrary.newFunctionWithName(mtl_library, main_name);

    // If computeMain not found, try "main"
    if mtl_function == null {
        release(main_name);
        function_name = "main";
        main_name = NSString.initWithBytes(
            objc_alloc(NSString),
            function_name.data,
            function_name.count.(NSUInteger),
            NSUTF8StringEncoding
        );
        mtl_function = MTLLibrary.newFunctionWithName(mtl_library, main_name);
    }
    if mtl_function == null {
        log_error("Failed to find 'main' function in Metal shader");
        release(mtl_library);
        return 0;
    }

    // Create the compute pipeline state
    mtl_pipeline := MTLDevice.newComputePipelineStateWithFunction(mtl_device, mtl_function, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to create compute pipeline: %", error_str);
        release(mtl_function);
        release(mtl_library);
        return 0;
    }
    if mtl_pipeline == null {
        log_error("Failed to create compute pipeline state");
        release(mtl_function);
        release(mtl_library);
        return 0;
    }

    // We can release the function and library now - the pipeline state retains what it needs
    release(mtl_function);
    release(mtl_library);

    handle := pool_add(*live_pipelines, .{
        type = .COMPUTE,
        mtl_compute_pipeline = mtl_pipeline,
        mtl_render_pipeline = null,
    });

    return handle;
}

gpu_free_pipeline :: (pipeline_handle: Gpu_Pipeline) {
    removed, pipeline := pool_remove(*live_pipelines, pipeline_handle);
    if removed {
        if pipeline.mtl_compute_pipeline != null {
            release(pipeline.mtl_compute_pipeline);
        }
        if pipeline.mtl_render_pipeline != null {
            release(pipeline.mtl_render_pipeline);
        }
    }
}

gpu_set_pipeline :: (cmd: Gpu_Command_Buffer, pipeline_handle: Gpu_Pipeline) -> Gpu_Result {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return .ERROR_INVALID_BUFFER;

    pipeline := pool_get(live_pipelines, pipeline_handle);
    if pipeline == null then return .ERROR_INVALID_PIPELINE;

    // Store the current pipeline in the command buffer info for later use during dispatch
    cmd_info.current_pipeline = pipeline_handle;

    return .SUCCESS;
}

gpu_dispatch :: (cmd: Gpu_Command_Buffer, data: Gpu_Ptr, dimensions: [3] u32) {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    pipeline := pool_get(live_pipelines, cmd_info.current_pipeline);
    if pipeline == null || pipeline.type != .COMPUTE then return;

    // End any existing blit encoder before starting compute
    end_current_encoder(cmd_info);

    // Create a compute encoder
    compute_encoder := MTLCommandBuffer.computeCommandEncoder(cmd_info.mtl_cmd_buffer);
    if compute_encoder == null then return;

    // Set the pipeline state
    MTLComputeCommandEncoder.setComputePipelineState(compute_encoder, pipeline.mtl_compute_pipeline);

    // Get the buffer for the data pointer and bind it
    result, mtl_buffer, offset := get_buffer_and_offset(data);
    if result == .SUCCESS && mtl_buffer != null {
        MTLComputeCommandEncoder.setBuffer(compute_encoder, mtl_buffer, offset.(NSUInteger), 0);
    }

    // Get thread execution width and calculate threads per threadgroup
    thread_execution_width := MTLComputePipelineState.threadExecutionWidth(pipeline.mtl_compute_pipeline);
    max_threads := MTLComputePipelineState.maxTotalThreadsPerThreadgroup(pipeline.mtl_compute_pipeline);

    // Use a reasonable threadgroup size (typically 64 for compute shaders)
    threads_per_group := MTLSize.{ width = 64, height = 1, depth = 1 };
    if threads_per_group.width > max_threads {
        threads_per_group.width = max_threads;
    }

    // Dispatch threadgroups
    threadgroups := MTLSize.{
        width = dimensions[0].(NSUInteger),
        height = dimensions[1].(NSUInteger),
        depth = dimensions[2].(NSUInteger)
    };

    MTLComputeCommandEncoder.dispatchThreadgroups(compute_encoder, threadgroups, threads_per_group);

    // End the compute encoder
    MTLCommandEncoder.endEncoding(compute_encoder);
}

#scope_module

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

NUM_SHADER_STAGES :: #run enum_values_as_enum(Shader_Stage).count;

Pipeline :: struct {
    type: Pipeline_Type;
    mtl_compute_pipeline: *MTLComputePipelineState;
    mtl_render_pipeline: *MTLRenderPipelineState;
}

live_pipelines: Pool(Gpu_Pipeline, Pipeline);

get_pipeline :: (handle: Gpu_Pipeline) -> *Pipeline {
    return pool_get(live_pipelines, handle);
}

NSUTF8StringEncoding :: 4;
