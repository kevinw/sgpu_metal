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

gpu_create_graphics_pipeline :: (vertex_metal: string, pixel_metal: string, raster_desc: Gpu_Raster_Desc) -> Gpu_Pipeline {
    auto_release_temp();

    // Create library from vertex shader Metal source
    ns_vertex_source := NSString.initWithBytes(
        objc_alloc(NSString),
        vertex_metal.data,
        vertex_metal.count.(NSUInteger),
        NSUTF8StringEncoding
    );
    defer release(ns_vertex_source);

    compile_options := objc_new(MTLCompileOptions);
    defer release(compile_options);
    MTLCompileOptions.setLanguageVersion(compile_options, ._3_2);

    error: *NSError;
    vertex_library := MTLDevice.newLibraryWithSource(mtl_device, ns_vertex_source, compile_options, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to compile vertex shader: %", error_str);
        return 0;
    }
    if vertex_library == null {
        log_error("Failed to create vertex library");
        return 0;
    }
    defer release(vertex_library);

    // Create library from pixel shader Metal source
    ns_pixel_source := NSString.initWithBytes(
        objc_alloc(NSString),
        pixel_metal.data,
        pixel_metal.count.(NSUInteger),
        NSUTF8StringEncoding
    );
    defer release(ns_pixel_source);

    error = null;
    pixel_library := MTLDevice.newLibraryWithSource(mtl_device, ns_pixel_source, compile_options, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to compile pixel shader: %", error_str);
        return 0;
    }
    if pixel_library == null {
        log_error("Failed to create pixel library");
        return 0;
    }
    defer release(pixel_library);

    // Get vertex function - try various names (Slang may rename "main" to "main_0")
    vertex_function := get_function_from_library(vertex_library, "vertexMain");
    if vertex_function == null {
        vertex_function = get_function_from_library(vertex_library, "vertexMain_0");
    }
    if vertex_function == null {
        vertex_function = get_function_from_library(vertex_library, "main");
    }
    if vertex_function == null {
        vertex_function = get_function_from_library(vertex_library, "main_0");
    }
    if vertex_function == null {
        log_error("Failed to find vertex function in shader");
        return 0;
    }
    defer release(vertex_function);

    // Get fragment function - try various names (Slang may rename "main" to "main_0")
    fragment_function := get_function_from_library(pixel_library, "fragmentMain");
    if fragment_function == null {
        fragment_function = get_function_from_library(pixel_library, "fragmentMain_0");
    }
    if fragment_function == null {
        fragment_function = get_function_from_library(pixel_library, "main");
    }
    if fragment_function == null {
        fragment_function = get_function_from_library(pixel_library, "main_0");
    }
    if fragment_function == null {
        log_error("Failed to find fragment function in shader");
        return 0;
    }
    defer release(fragment_function);

    // Create MTL4 render pipeline descriptor
    pipeline_desc := objc_new(MTL4RenderPipelineDescriptor);
    defer release(pipeline_desc);

    // Create function descriptors for MTL4
    vertex_func_desc := objc_new(MTL4LibraryFunctionDescriptor);
    defer release(vertex_func_desc);
    MTL4LibraryFunctionDescriptor.setLibrary(vertex_func_desc, vertex_library);
    {
        name := get_function_name(vertex_function);
        MTL4LibraryFunctionDescriptor.setName(vertex_func_desc, name);
    }

    fragment_func_desc := objc_new(MTL4LibraryFunctionDescriptor);
    defer release(fragment_func_desc);
    MTL4LibraryFunctionDescriptor.setLibrary(fragment_func_desc, pixel_library);
    {
        name := get_function_name(fragment_function);
        MTL4LibraryFunctionDescriptor.setName(fragment_func_desc, name);
    }

    MTL4RenderPipelineDescriptor.setVertexFunctionDescriptor(pipeline_desc, vertex_func_desc);
    MTL4RenderPipelineDescriptor.setFragmentFunctionDescriptor(pipeline_desc, fragment_func_desc);

    // Configure color attachments
    color_attachments := MTL4RenderPipelineDescriptor.colorAttachments(pipeline_desc);

    for raster_desc.color_targets {
        color_attachment := MTL4RenderPipelineColorAttachmentDescriptorArray.objectAtIndexedSubscript(color_attachments, it_index.(NSUInteger));

        MTL4RenderPipelineColorAttachmentDescriptor.setPixelFormat(color_attachment, format_to_mtl(it.format));

        // Configure blending if we have a blend state
        if raster_desc.blend_state != null {
            blend := raster_desc.blend_state;

            // Enable blending if any factor is not the default
            if blend.src_color_factor != .ZERO || blend.dst_color_factor != .ZERO {
                MTL4RenderPipelineColorAttachmentDescriptor.setBlendingState(color_attachment, .Enabled);

                MTL4RenderPipelineColorAttachmentDescriptor.setSourceRGBBlendFactor(color_attachment, blend_factor_to_mtl(blend.src_color_factor));
                MTL4RenderPipelineColorAttachmentDescriptor.setDestinationRGBBlendFactor(color_attachment, blend_factor_to_mtl(blend.dst_color_factor));
                MTL4RenderPipelineColorAttachmentDescriptor.setRgbBlendOperation(color_attachment, blend_op_to_mtl(blend.color_op));

                MTL4RenderPipelineColorAttachmentDescriptor.setSourceAlphaBlendFactor(color_attachment, blend_factor_to_mtl(blend.src_alpha_factor));
                MTL4RenderPipelineColorAttachmentDescriptor.setDestinationAlphaBlendFactor(color_attachment, blend_factor_to_mtl(blend.dst_alpha_factor));
                MTL4RenderPipelineColorAttachmentDescriptor.setAlphaBlendOperation(color_attachment, blend_op_to_mtl(blend.alpha_op));
            }

            // Set write mask
            MTL4RenderPipelineColorAttachmentDescriptor.setWriteMask(color_attachment, color_write_mask_to_mtl(blend.color_write_mask));
        }
    }

    // Set sample count
    if raster_desc.sample_count > 0 {
        MTL4RenderPipelineDescriptor.setRasterSampleCount(pipeline_desc, raster_desc.sample_count.(NSUInteger));
    }

    // Create the compiler and pipeline state
    compiler_desc := objc_new(MTL4CompilerDescriptor);
    defer release(compiler_desc);

    error = null;
    compiler := MTLDevice.newCompilerWithDescriptor(mtl_device, compiler_desc, *error);
    if error != null || compiler == null {
        if error != null {
            error_str := to_string(NSError.localizedDescription(error));
            log_error("Failed to create compiler: %", error_str);
        }
        return 0;
    }
    defer release(compiler);

    // Create compiler task options (can be null for default options)
    task_options: *MTL4CompilerTaskOptions = null;

    error = null;
    // Cast pipeline_desc to base type MTL4PipelineDescriptor
    render_pipeline := MTL4Compiler.newRenderPipelineStateWithDescriptor(compiler, cast(*MTL4PipelineDescriptor) pipeline_desc, task_options, *error);
    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to create render pipeline: %", error_str);
        return 0;
    }
    if render_pipeline == null {
        log_error("Failed to create render pipeline state");
        return 0;
    }

    handle := pool_add(*live_pipelines, .{
        type = .GRAPHICS,
        mtl_compute_pipeline = null,
        mtl_render_pipeline = render_pipeline,
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

gpu_dispatch :: (cmd: Gpu_Command_Buffer, data: Gpu_Ptr, dimensions: [3] u32) {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    pipeline := pool_get(live_pipelines, cmd_info.current_pipeline);
    if pipeline == null || pipeline.type != .COMPUTE then return;

    queue := get_queue(cmd_info.queue);
    if queue == null || queue.mtl4_queue == null then return;

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
    ns_name := NSString.initWithBytes(
        objc_alloc(NSString),
        name.data,
        name.count.(NSUInteger),
        NSUTF8StringEncoding
    );
    defer release(ns_name);

    return MTLLibrary.newFunctionWithName(library, ns_name);
}

get_function_name :: (func: *MTLFunction) -> *NSString {
    return MTLFunction.name(func);
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
    result: MTLColorWriteMask = 0;
    if mask & .R then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Red;
    if mask & .G then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Green;
    if mask & .B then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Blue;
    if mask & .A then result |= cast(MTLColorWriteMask) MTLColorWriteMask_1.Alpha;
    if mask == .ALL then result = cast(MTLColorWriteMask) MTLColorWriteMask_1.All;
    return result;
}

NSUTF8StringEncoding :: 4;
