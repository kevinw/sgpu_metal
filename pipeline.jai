#scope_export

gpu_create_compute_pipeline :: (metal_source: string) -> Gpu_Pipeline {
    // Create compile options with Metal 3.2 language version (required for MTL4)
    compile_options := objc_new_defer_release(MTLCompileOptions);
    MTLCompileOptions.setLanguageVersion(compile_options, ._3_2);

    error: *NSError;
    mtl_library := MTLDevice.newLibraryWithSource(mtl_device, to_temp_nsstring(metal_source), compile_options, *error);
    defer if mtl_library release(mtl_library);
    if log_error_if_not_null(error) || mtl_library == null {
        log_error("Failed to create Metal library");
        return 0;
    }

    // Get the entry point function from the library
    // Try "computeMain" first (our convention), then fall back to "main"
    mtl_function := MTLLibrary.newFunctionWithName(mtl_library, to_temp_nsstring("computeMain"));
    defer if mtl_function then release(mtl_function);

    // If computeMain not found, try "main"
    if mtl_function == null {
        mtl_function = MTLLibrary.newFunctionWithName(mtl_library, to_temp_nsstring("main"));
    }

    if mtl_function == null {
        log_error("Failed to find 'main' function in Metal shader");
        return 0;
    }

    // Create the compute pipeline state
    mtl_pipeline := MTLDevice.newComputePipelineStateWithFunction(mtl_device, mtl_function, *error);
    if log_error_if_not_null(error) {
        log_error("Failed to create compute pipeline.");
        return 0;
    }

    if mtl_pipeline == null {
        log_error("Failed to create compute pipeline state");
        return 0;
    }

    return pool_add(*live_pipelines, {
        type = .COMPUTE,
        mtl_compute_pipeline = mtl_pipeline
    });
}

gpu_create_graphics_pipeline :: (vertex_metal: string, pixel_metal: string, raster_desc: Gpu_Raster_Desc) -> Gpu_Pipeline {
    auto_release_temp();

    // Create library from vertex shader Metal source
    compile_options := objc_new_defer_release(MTLCompileOptions);
    MTLCompileOptions.setLanguageVersion(compile_options, ._3_2);

    error: *NSError;
    vertex_library := MTLDevice.newLibraryWithSource(mtl_device, to_temp_nsstring(vertex_metal), compile_options, *error);
    defer if vertex_library release(vertex_library);
    if log_error_if_not_null(error) {
        log_error("Failed to compile vertex shader.");
        return 0;
    }
    if vertex_library == null {
        log_error("Failed to create vertex library");
        return 0;
    }

    // Create library from pixel shader Metal source
    error = null;
    pixel_library := MTLDevice.newLibraryWithSource(mtl_device, to_temp_nsstring(pixel_metal), compile_options, *error);
    defer if pixel_library release(pixel_library);
    if log_error_if_not_null(error) {
        log_error("Failed to compile pixel shader.");
        return 0;
    }
    if pixel_library == null {
        log_error("Failed to create pixel library");
        return 0;
    }

    // Get vertex function - try various names (Slang may rename "main" to "main_0")
    vertex_function := get_function_from_library(vertex_library, "vertexMain");
    if vertex_function == null vertex_function = get_function_from_library(vertex_library, "vertexMain_0");
    if vertex_function == null vertex_function = get_function_from_library(vertex_library, "main");
    if vertex_function == null vertex_function = get_function_from_library(vertex_library, "main_0");
    if vertex_function == null {
        log_error("Failed to find vertex function in shader");
        return 0;
    }
    defer release(vertex_function);

    // Get fragment function - try various names (Slang may rename "main" to "main_0")
    fragment_function := get_function_from_library(pixel_library, "fragmentMain");
    if fragment_function == null fragment_function = get_function_from_library(pixel_library, "fragmentMain_0");
    if fragment_function == null fragment_function = get_function_from_library(pixel_library, "main");
    if fragment_function == null fragment_function = get_function_from_library(pixel_library, "main_0");
    if fragment_function == null {
        log_error("Failed to find fragment function in shader");
        return 0;
    }
    defer release(fragment_function);

    // Create MTL4 render pipeline descriptor
    pipeline_desc := objc_new_defer_release(MTL4RenderPipelineDescriptor);

    // Create function descriptors for MTL4
    vertex_func_desc := objc_new_defer_release(MTL4LibraryFunctionDescriptor);
    MTL4LibraryFunctionDescriptor.setLibrary(vertex_func_desc, vertex_library);
    MTL4LibraryFunctionDescriptor.setName(vertex_func_desc, MTLFunction.name(vertex_function));

    fragment_func_desc := objc_new_defer_release(MTL4LibraryFunctionDescriptor);
    MTL4LibraryFunctionDescriptor.setLibrary(fragment_func_desc, pixel_library);
    MTL4LibraryFunctionDescriptor.setName(fragment_func_desc, MTLFunction.name(fragment_function));

    pipeline_desc.setVertexFunctionDescriptor(pipeline_desc, vertex_func_desc);
    pipeline_desc.setFragmentFunctionDescriptor(pipeline_desc, fragment_func_desc);

    // Configure color attachments
    color_attachments := pipeline_desc.colorAttachments(pipeline_desc);
    for raster_desc.color_targets {
        color_attachment := MTL4RenderPipelineColorAttachmentDescriptorArray.objectAtIndexedSubscript(color_attachments, it_index.(NSUInteger));

        using color_attachment;
        setPixelFormat(color_attachment, format_to_mtl(it.format));

        // Configure blending if we have a blend state
        if raster_desc.blend_state != null {
            blend := raster_desc.blend_state;

            // Enable blending if any factor is not the default
            if blend.src_color_factor != .ZERO || blend.dst_color_factor != .ZERO {
                setBlendingState(color_attachment, .Enabled);

                setSourceRGBBlendFactor(color_attachment, blend_factor_to_mtl(blend.src_color_factor));
                setDestinationRGBBlendFactor(color_attachment, blend_factor_to_mtl(blend.dst_color_factor));
                setRgbBlendOperation(color_attachment, blend_op_to_mtl(blend.color_op));

                setSourceAlphaBlendFactor(color_attachment, blend_factor_to_mtl(blend.src_alpha_factor));
                setDestinationAlphaBlendFactor(color_attachment, blend_factor_to_mtl(blend.dst_alpha_factor));
                setAlphaBlendOperation(color_attachment, blend_op_to_mtl(blend.alpha_op));
            }

            // Set write mask
            setWriteMask(color_attachment, color_write_mask_to_mtl(blend.color_write_mask));
        }
    }

    // Set sample count
    if raster_desc.sample_count > 0 {
        MTL4RenderPipelineDescriptor.setRasterSampleCount(pipeline_desc, raster_desc.sample_count.(NSUInteger));
    }

    // Create the compiler and pipeline state
    compiler_desc := objc_new_defer_release(MTL4CompilerDescriptor);

    error = null;
    compiler := MTLDevice.newCompilerWithDescriptor(mtl_device, compiler_desc, *error);
    if error != null || compiler == null {
        log_error_if_not_null(error, "newCompilerWithDescriptor");
        return 0;
    }
    defer release(compiler);

    // Create compiler task options (can be null for default options)
    task_options: *MTL4CompilerTaskOptions = null;

    error = null;

    // Cast pipeline_desc to base type MTL4PipelineDescriptor
    render_pipeline := MTL4Compiler.newRenderPipelineStateWithDescriptor(compiler, pipeline_desc, task_options, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to create render pipeline: %", error_str);
        return 0;
    }

    if render_pipeline == null {
        log_error("Failed to create render pipeline state");
        return 0;
    }

    add_to_residency(render_pipeline);
    handle := pool_add(*live_pipelines, .{
        type = .GRAPHICS,
        mtl_compute_pipeline = null,
        mtl_render_pipeline = render_pipeline,
    });

    return handle;
}

gpu_free_pipeline :: (pipeline_handle: Gpu_Pipeline) {
    removed, pipeline := pool_remove(*live_pipelines, pipeline_handle);
    if !removed return;

    using pipeline;
    release_and_set_null(*mtl_compute_pipeline);
    release_and_set_null(*mtl_render_pipeline);
}

gpu_dispatch :: (cmd: Gpu_Command_Buffer, data: Gpu_Ptr, dimensions: [3] u32) {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null return;

    pipeline := pool_get(live_pipelines, cmd_info.current_pipeline);
    return_if(pipeline == null, tprint("gpu_dispatch: no pipeline for %", cmd_info.current_pipeline));
    return_if(pipeline.type != .COMPUTE, "gpu_dispatch: pipeline is not .COMPUTE");

    queue := get_queue(cmd_info.queue);
    return_if(queue == null || queue.mtl4_queue == null, tprint("gpu_dispatch: no queue (cmd_info.queue is %)", cmd_info.queue));

    // End any existing render encoder before starting compute
    end_current_render_encoder(cmd_info);

    // Ensure compute encoder exists
    compute_encoder := ensure_compute_encoder(cmd_info);
    if compute_encoder == null then return;

    // Ensure bindless argument table is initialized
    if global_argument_table == null {
        init_bindless();
    }

    // Set the pipeline state
    MTL4ComputeCommandEncoder.setComputePipelineState(compute_encoder, pipeline.mtl_compute_pipeline);

    // Set the buffer address in the argument table at index 0
    MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) data, 0);

    // Bind the argument table to the encoder
    MTL4ComputeCommandEncoder.setArgumentTable(compute_encoder, global_argument_table);

    // Get thread execution width and calculate threads per threadgroup
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

    MTL4ComputeCommandEncoder.dispatchThreadgroups(compute_encoder, threadgroups, threads_per_group);
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

get_function_from_library :: (library: *MTLLibrary, name: string) -> *MTLFunction {
    ns_name := NSString.initWithBytes(objc_alloc(NSString), name.data, name.count.(NSUInteger), NSUTF8StringEncoding);
    defer release(ns_name);
    return MTLLibrary.newFunctionWithName(library, ns_name);
}

blend_factor_to_mtl :: (factor: Factor) -> MTLBlendFactor {
    if factor == {
        case .ZERO;                     return .Zero;
        case .ONE;                      return .One;
        case .SRC_COLOR;                return .SourceColor;
        case .ONE_MINUS_SRC_COLOR;      return .OneMinusSourceColor;
        case .DST_COLOR;                return .DestinationColor;
        case .ONE_MINUS_DST_COLOR;      return .OneMinusDestinationColor;
        case .SRC_ALPHA;                return .SourceAlpha;
        case .ONE_MINUS_SRC_ALPHA;      return .OneMinusSourceAlpha;
        case .DST_ALPHA;                return .DestinationAlpha;
        case .ONE_MINUS_DST_ALPHA;      return .OneMinusDestinationAlpha;
        case .CONSTANT_COLOR;           return .BlendColor;
        case .ONE_MINUS_CONSTANT_COLOR; return .OneMinusBlendColor;
        case .CONSTANT_ALPHA;           return .BlendAlpha;
        case .ONE_MINUS_CONSTANT_ALPHA; return .OneMinusBlendAlpha;
        case .SRC_ALPHA_SATURATE;       return .SourceAlphaSaturated;
    }
    return .Zero;
}

blend_op_to_mtl :: (op: Blend) -> MTLBlendOperation {
    if op == {
        case .ADD;          return .Add;
        case .SUBTRACT;     return .Subtract;
        case .REV_SUBTRACT; return .ReverseSubtract;
        case .MIN;          return .Min;
        case .MAX;          return .Max;
    }
    return .Add;
}

color_write_mask_to_mtl :: (mask: Component_Flags) -> MTLColorWriteMask {
    if mask == .ALL then return cast(MTLColorWriteMask)MTLColorWriteMask_1.All;

    result: MTLColorWriteMask = 0;
    if mask & .R then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Red;
    if mask & .G then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Green;
    if mask & .B then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Blue;
    if mask & .A then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Alpha;

    return result;
}

return_if :: (cond: bool, message: string) #expand {
    if cond {
        log_error(message);
        `return;
    }
}

NSUTF8StringEncoding :: 4;
