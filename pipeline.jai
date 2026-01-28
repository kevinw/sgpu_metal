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

    // Create compile options with Metal 3.2 language version (required for MTL4)
    compile_options := objc_new(MTLCompileOptions);
    defer release(compile_options);
    MTLCompileOptions.setLanguageVersion(compile_options, ._3_2);

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

    queue := get_queue(cmd_info.queue);
    if queue == null || queue.mtl4_queue == null then return;

    // End any existing blit encoder before starting compute
    end_current_encoder(cmd_info);

    // Ensure bindless argument table is initialized
    if global_argument_table == null {
        init_bindless();
    }

    // For MTL4 bindless features, create a command allocator and command buffer
    allocator := MTLDevice.newCommandAllocator(mtl_device);
    if allocator == null then return;
    defer release(allocator);

    mtl4_cmd_buffer := MTLDevice.newCommandBuffer(mtl_device);
    if mtl4_cmd_buffer == null then return;

    // Begin the command buffer with the allocator
    MTL4CommandBuffer.beginCommandBufferWithAllocator(mtl4_cmd_buffer, allocator);

    // Create MTL4 compute encoder
    compute_encoder := MTL4CommandBuffer.computeCommandEncoder(mtl4_cmd_buffer);
    if compute_encoder == null {
        release(mtl4_cmd_buffer);
        return;
    }

    // Cast to MTL4ComputeCommandEncoder for MTL4-specific methods
    mtl4_encoder := cast(*MTL4ComputeCommandEncoder) compute_encoder;

    // Set the pipeline state
    MTL4ComputeCommandEncoder.setComputePipelineState(mtl4_encoder, pipeline.mtl_compute_pipeline);

    // Set the buffer address in the argument table at index 0
    MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) data, 0);

    // Bind the argument table to the encoder
    MTL4ComputeCommandEncoder.setArgumentTable(mtl4_encoder, global_argument_table);

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

    MTL4ComputeCommandEncoder.dispatchThreadgroups(mtl4_encoder, threadgroups, threads_per_group);

    // End the command buffer recording
    MTL4CommandEncoder.endEncoding(cast(*MTL4CommandEncoder) mtl4_encoder);
    MTL4CommandBuffer.endCommandBuffer(mtl4_cmd_buffer);

    // Submit the MTL4 command buffer through the MTL4 queue
    cmd_buffers: [1] *MTL4CommandBuffer;
    cmd_buffers[0] = mtl4_cmd_buffer;
    MTL4CommandQueue.commit(queue.mtl4_queue, cmd_buffers.data, 1);

    // Wait for the MTL4 queue to finish (synchronous for now)
    // We can use an MTLSharedEvent for proper synchronization
    event := MTLDevice.newSharedEvent(mtl_device);
    if event != null {
        defer release(event);

        // Signal the event after the command buffer completes
        signal_value := cast(u64) 1;
        MTL4CommandQueue.signalEvent(queue.mtl4_queue, event, signal_value);

        // Wait for the event on the CPU
        MTLSharedEvent.notifyListener(event, null, signal_value, null);  // Synchronous wait
    }
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
