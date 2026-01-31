#scope_export

gpu_get_queue :: (queue_type: Gpu_Queue_Type, queue_index: u32) -> Gpu_Queue {
    for queues {
        if it.type == queue_type && it.index_in_type == queue_index {
            return (it_index + 1).(Gpu_Queue);
        }
    }

    return 0;
}

gpu_start_command_recording :: (queue_handle: Gpu_Queue) -> Gpu_Result, Gpu_Command_Buffer {
    queue := get_queue(queue_handle);
    if queue == null return .FATAL_ERROR_UNKNOWN, 0;

    // Create MTL4 command allocator and command buffer
    mtl4_allocator := MTLDevice.newCommandAllocator(mtl_device);
    if mtl4_allocator == null {
        return .ERROR_COMMAND_BUFFER_LIMIT_EXCEEDED, 0;
    }

    mtl4_cmd_buffer := MTLDevice.newCommandBuffer(mtl_device);
    if mtl4_cmd_buffer == null {
        release(mtl4_allocator);
        return .ERROR_COMMAND_BUFFER_LIMIT_EXCEEDED, 0;
    }

    // Begin the command buffer with the allocator
    MTL4CommandBuffer.beginCommandBufferWithAllocator(mtl4_cmd_buffer, mtl4_allocator);

    // Store the command buffer info
    cmd_info: Command_Buffer_Info = {
        mtl4_cmd_buffer = mtl4_cmd_buffer,
        mtl4_allocator = mtl4_allocator,
        queue = queue_handle,
    };

    // Find an empty slot in live command buffers
    found_slot := false;
    slot_index: s64 = -1;
    for * live_command_buffers {
        if it.mtl4_cmd_buffer == null {
            it.* = cmd_info;
            slot_index = it_index;
            found_slot = true;
            break;
        }
    }

    if !found_slot {
        slot_index = live_command_buffers.count;
        array_add(*live_command_buffers, cmd_info);
    }

    cmd_buff_handle := cast(Gpu_Command_Buffer) (slot_index + 1);

    return .SUCCESS, cmd_buff_handle;
}

gpu_memcpy :: (cmd: Gpu_Command_Buffer, dest: Gpu_Ptr, src: Gpu_Ptr, num_bytes: s64) -> Gpu_Result {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null return .ERROR_INVALID_BUFFER;

    dest_result, dest_buffer, dest_offset := get_buffer_and_offset(dest);
    if dest_result != .SUCCESS return dest_result;

    src_result, src_buffer, src_offset := get_buffer_and_offset(src);
    if src_result != .SUCCESS return src_result;

    // End any render encoder before starting compute/blit
    end_current_render_encoder(cmd_info);

    // Get or create the MTL4 compute encoder (handles blit operations in Metal 4)
    compute_encoder := ensure_compute_encoder(cmd_info);
    if compute_encoder == null return .FATAL_ERROR_UNKNOWN;

    // Perform the copy using MTL4ComputeCommandEncoder
    MTL4ComputeCommandEncoder.copyFromBuffer(
        compute_encoder,
        src_buffer,
        src_offset.(NSUInteger),
        dest_buffer,
        dest_offset.(NSUInteger),
        num_bytes.(NSUInteger)
    );

    return .SUCCESS;
}

gpu_barrier :: (cmd: Gpu_Command_Buffer, src_stage: Stage, dst_stage: Stage) {
    using cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    // In Metal 4, barriers are handled by ending and starting new encoders
    if current_compute_encoder != null  end_current_compute_encoder(cmd_info);
    if current_render_encoder != null   end_current_render_encoder(cmd_info);
}

gpu_submit :: (cmd_buff: Gpu_Command_Buffer, signals: [] Gpu_Timeline_Pair = .[], waits: [] Gpu_Timeline_Pair = .[]) {
    cmd_info := get_cmd_info(cmd_buff);
    if cmd_info == null then return;

    queue := get_queue(cmd_info.queue);
    if queue == null then return;

    // End any active encoder
    end_current_compute_encoder(cmd_info);
    end_current_render_encoder(cmd_info);

    // End the command buffer recording
    MTL4CommandBuffer.endCommandBuffer(cmd_info.mtl4_cmd_buffer);

    // Submit via MTL4 command queue
    cmd_buffers: [1] *MTL4CommandBuffer;
    cmd_buffers[0] = cmd_info.mtl4_cmd_buffer;
    MTL4CommandQueue.commit(queue.mtl4_queue, cmd_buffers.data, 1);

    // Mark slot as available (don't clear mtl4_cmd_buffer yet - we need it for wait_idle)
    // The command buffer is now owned by Metal until completion
}

gpu_wait_idle :: () {
    // Wait for all queues to complete using shared events
    for * queues {
        if it.mtl4_queue != null {
            // Create a shared event for synchronization
            event := MTLDevice.newSharedEvent(mtl_device);
            if event == null then continue;
            defer release(event);

            // Signal the event after all pending work
            signal_value: u64 = 1;
            MTL4CommandQueue.signalEvent(it.mtl4_queue, event, signal_value);

            // Spin-wait for the event to be signaled
            while MTLSharedEvent.signaledValue(event) < signal_value {
                // Busy wait - could add a small sleep here for efficiency
            }
        }
    }

    // Clear all command buffer slots and release allocators
    for * live_command_buffers {
        release_and_set_null(*it.mtl4_cmd_buffer);
        release_and_set_null(*it.mtl4_allocator);

        if it.current_compute_encoder log("WARNING: current_compute_encoder is not null, but we called gpu_wait_idle");
        if it.current_render_encoder  log("WARNING: current_render_encoder is not null, but we called gpu_wait_idle");

        // TODO: @Leak?

        it.current_compute_encoder = null;
        it.current_render_encoder = null;
    }
}

gpu_queue_wait_idle :: (queue_handle: Gpu_Queue) {
    queue := get_queue(queue_handle);
    if queue == null || queue.mtl4_queue == null then return;

    // Create a shared event for synchronization
    event := MTLDevice.newSharedEvent(mtl_device);
    if event == null then return;
    defer release(event);

    // Signal the event after all pending work on this queue
    signal_value: u64 = 1;
    MTL4CommandQueue.signalEvent(queue.mtl4_queue, event, signal_value);

    // Spin-wait for the event to be signaled
    while MTLSharedEvent.signaledValue(event) < signal_value {
        // Busy wait - could add a small sleep here for efficiency
    }

    // Clear command buffer slots for this queue and release allocators
    for * live_command_buffers {
        if it.mtl4_cmd_buffer != null && it.queue == queue_handle {
            release_and_set_null(it.mtl4_cmd_buffer);
            release_and_set_null(*it.mtl4_allocator);
            it.current_compute_encoder = null;
            it.current_render_encoder = null;
        }
    }
}

// =====================
// Render Pass Commands
// =====================

gpu_begin_render_pass :: (cmd: Gpu_Command_Buffer, desc: Gpu_Render_Pass_Desc) -> Gpu_Result {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return .ERROR_INVALID_BUFFER;

    // End any active compute encoder before starting render
    end_current_compute_encoder(cmd_info);

    auto_release_temp();

    // Create MTL4 render pass descriptor
    pass_desc := objc_new_defer_release(MTL4RenderPassDescriptor);

    // Configure color attachments
    color_attachments := MTL4RenderPassDescriptor.colorAttachments(pass_desc);

    render_width: u32 = 0;
    render_height: u32 = 0;

    for desc.color_targets {
        view := get_texture_view(it.view);
        if view == null return .ERROR_INVALID_TEXTURE;

        texture := get_texture(view.texture);
        if texture != null {
            render_width = texture.desc.dimensions[0];
            render_height = texture.desc.dimensions[1];
        }

        color_attachment := MTLRenderPassColorAttachmentDescriptorArray.objectAtIndexedSubscript(color_attachments, it_index.(NSUInteger));

        MTLRenderPassColorAttachmentDescriptor.setTexture(color_attachment, view.mtl_texture);
        MTLRenderPassColorAttachmentDescriptor.setLoadAction(color_attachment, load_op_to_mtl(it.load_op));
        MTLRenderPassColorAttachmentDescriptor.setStoreAction(color_attachment, store_op_to_mtl(it.store_op));

        if it.load_op == .CLEAR {
            clear_color := MTLClearColor.{
                red = it.clear_color._float[0].(float64),
                green = it.clear_color._float[1].(float64),
                blue = it.clear_color._float[2].(float64),
                alpha = it.clear_color._float[3].(float64),
            };
            MTLRenderPassColorAttachmentDescriptor.setClearColor(color_attachment, clear_color);
        }
    }

    // Configure depth attachment if present
    if desc.depth_target.view != 0 {
        view := get_texture_view(desc.depth_target.view);
        if view != null {
            texture := get_texture(view.texture);
            if texture != null {
                render_width = texture.desc.dimensions[0];
                render_height = texture.desc.dimensions[1];
            }

            depth_attachment := MTL4RenderPassDescriptor.depthAttachment(pass_desc);
            MTLRenderPassDepthAttachmentDescriptor.setTexture(depth_attachment, view.mtl_texture);
            MTLRenderPassDepthAttachmentDescriptor.setLoadAction(depth_attachment, load_op_to_mtl(desc.depth_target.load_op));
            MTLRenderPassDepthAttachmentDescriptor.setStoreAction(depth_attachment, store_op_to_mtl(desc.depth_target.store_op));
            MTLRenderPassDepthAttachmentDescriptor.setClearDepth(depth_attachment, desc.depth_target.clear_value.depth.(float64));
        }
    }

    // Configure stencil attachment if present
    if desc.stencil_target.view != 0 {
        view := get_texture_view(desc.stencil_target.view);
        if view != null {
            stencil_attachment := MTL4RenderPassDescriptor.stencilAttachment(pass_desc);
            MTLRenderPassStencilAttachmentDescriptor.setTexture(stencil_attachment, view.mtl_texture);
            MTLRenderPassStencilAttachmentDescriptor.setLoadAction(stencil_attachment, load_op_to_mtl(desc.stencil_target.load_op));
            MTLRenderPassStencilAttachmentDescriptor.setStoreAction(stencil_attachment, store_op_to_mtl(desc.stencil_target.store_op));
            MTLRenderPassStencilAttachmentDescriptor.setClearStencil(stencil_attachment, desc.stencil_target.clear_value.stencil);
        }
    }

    // Create the render command encoder
    render_encoder := MTL4CommandBuffer.renderCommandEncoderWithDescriptor(cmd_info.mtl4_cmd_buffer, pass_desc);

    if render_encoder == null {
        return .FATAL_ERROR_UNKNOWN;
    }

    cmd_info.current_render_encoder = render_encoder;
    cmd_info.render_width = render_width;
    cmd_info.render_height = render_height;

    // Set default viewport and scissor
    render_encoder.setViewport(render_encoder, {
        originX = 0, originY = 0,
        width = render_width.(float64), height = render_height.(float64),
        znear = 0, zfar = 1,
    });

    render_encoder.setScissorRect(render_encoder, {
        x = 0, y = 0, width = render_width.(NSUInteger), height = render_height.(NSUInteger),
    });

    return .SUCCESS;
}

gpu_end_render_pass :: (cmd: Gpu_Command_Buffer) {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    end_current_render_encoder(cmd_info);
}

gpu_set_depth_stencil_state :: (cmd: Gpu_Command_Buffer, desc: Gpu_Depth_Stencil_Desc) {
    using cmd_info := get_cmd_info(cmd);
    if cmd_info == null || cmd_info.current_render_encoder == null then return;

    // Create depth stencil state
    depth_desc := objc_new_defer_release(MTLDepthStencilDescriptor);

    // Set depth compare function
    MTLDepthStencilDescriptor.setDepthCompareFunction(depth_desc, compare_op_to_mtl(desc.depth_test));

    // Set depth write enable
    depth_write := (desc.depth_mode & .WRITE) != 0;
    MTLDepthStencilDescriptor.setDepthWriteEnabled(depth_desc, ifx depth_write then YES else NO);

    // Configure front face stencil if needed
    if desc.stencil_front.test != .NEVER || desc.stencil_back.test != .NEVER {
        front_stencil := MTLDepthStencilDescriptor.frontFaceStencil(depth_desc);
        MTLStencilDescriptor.setStencilCompareFunction(front_stencil, compare_op_to_mtl(desc.stencil_front.test));
        MTLStencilDescriptor.setStencilFailureOperation(front_stencil, stencil_op_to_mtl(desc.stencil_front.fail_op));
        MTLStencilDescriptor.setDepthFailureOperation(front_stencil, stencil_op_to_mtl(desc.stencil_front.depth_fail_op));
        MTLStencilDescriptor.setDepthStencilPassOperation(front_stencil, stencil_op_to_mtl(desc.stencil_front.pass_op));
        MTLStencilDescriptor.setReadMask(front_stencil, desc.stencil_read_mask.(u32));
        MTLStencilDescriptor.setWriteMask(front_stencil, desc.stencil_write_mask.(u32));

        back_stencil := MTLDepthStencilDescriptor.backFaceStencil(depth_desc);
        MTLStencilDescriptor.setStencilCompareFunction(back_stencil, compare_op_to_mtl(desc.stencil_back.test));
        MTLStencilDescriptor.setStencilFailureOperation(back_stencil, stencil_op_to_mtl(desc.stencil_back.fail_op));
        MTLStencilDescriptor.setDepthFailureOperation(back_stencil, stencil_op_to_mtl(desc.stencil_back.depth_fail_op));
        MTLStencilDescriptor.setDepthStencilPassOperation(back_stencil, stencil_op_to_mtl(desc.stencil_back.pass_op));
        MTLStencilDescriptor.setReadMask(back_stencil, desc.stencil_read_mask.(u32));
        MTLStencilDescriptor.setWriteMask(back_stencil, desc.stencil_write_mask.(u32));
    }

    // Create depth stencil state
    depth_state := MTLDevice.newDepthStencilStateWithDescriptor(mtl_device, depth_desc);
    if depth_state != null {
        MTL4RenderCommandEncoder.setDepthStencilState(cmd_info.current_render_encoder, depth_state);
        release(depth_state);
    }

    // Set depth bias if needed
    if desc.depth_bias != 0 || desc.depth_bias_slope_factor != 0 {
        MTL4RenderCommandEncoder.setDepthBias(current_render_encoder, desc.depth_bias, desc.depth_bias_slope_factor, desc.depth_bias_clamp);
    }

    // Set stencil reference value
    if desc.stencil_front.reference != 0 || desc.stencil_back.reference != 0 {
        MTL4RenderCommandEncoder.setStencilFrontReferenceValue(current_render_encoder, desc.stencil_front.reference.(u32), desc.stencil_back.reference.(u32));
    }
}

gpu_set_pipeline :: (cmd: Gpu_Command_Buffer, pipeline_handle: Gpu_Pipeline) -> Gpu_Result {
    using cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return .ERROR_INVALID_BUFFER;

    pipeline := pool_get(live_pipelines, pipeline_handle);
    if pipeline == null then return .ERROR_INVALID_PIPELINE;

    // Store the current pipeline in the command buffer info for later use during dispatch/draw
    current_pipeline = pipeline_handle;

    // Set the pipeline on the appropriate encoder
    if pipeline.type == .GRAPHICS && cmd_info.current_render_encoder != null {
        if pipeline.mtl_render_pipeline != null {
            MTL4RenderCommandEncoder.setRenderPipelineState(current_render_encoder, pipeline.mtl_render_pipeline);
        } else {
            log_error("pipeline.mtl_render_pipeline is null");
        }
    } else if pipeline.type == .COMPUTE && cmd_info.current_compute_encoder != null {
        if pipeline.mtl_compute_pipeline != null {
            MTL4ComputeCommandEncoder.setComputePipelineState(current_compute_encoder, pipeline.mtl_compute_pipeline);
        } else {
            log_error("pipeline.mtl_compute_pipeline is null");
        }
    }

    return .SUCCESS;
}

gpu_draw_instanced :: (cmd: Gpu_Command_Buffer, vertex_data: Gpu_Ptr, pixel_data: Gpu_Ptr, vertex_count: u32, instance_count: u32) -> Gpu_Result {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null || cmd_info.current_render_encoder == null then return .ERROR_INVALID_PIPELINE /* TODO probably the wrong error */;

    pipeline := pool_get(live_pipelines, cmd_info.current_pipeline);
    if pipeline == null || pipeline.mtl_render_pipeline == null then return .ERROR_INVALID_PIPELINE /* TODO probably the wrong error */;

    // Set argument table with buffer addresses
    if global_argument_table != null {
        MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) vertex_data, 0);
        MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) pixel_data, 1);
        MTL4RenderCommandEncoder.setArgumentTable(cmd_info.current_render_encoder, global_argument_table, cast(MTLRenderStages)(MTLRenderStage.Vertex | MTLRenderStage.Fragment));
    }

    MTL4RenderCommandEncoder.drawPrimitives(cmd_info.current_render_encoder, .Triangle, 0, vertex_count.(NSUInteger), instance_count.(NSUInteger));

    return .SUCCESS;
}

gpu_draw_indexed_instanced :: (cmd: Gpu_Command_Buffer, vertex_data: Gpu_Ptr, pixel_data: Gpu_Ptr, index_data: Gpu_Ptr, index_count: u32, instance_count: u32, index_size: u32 = size_of(u32)) -> Gpu_Result {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null || cmd_info.current_render_encoder == null {
        log_error("gpu_draw_indexed_instanced: cmd_info or cmd_info.current_render_encoder is null");
        return .ERROR_INVALID_BUFFER;
    }

    pipeline := pool_get(live_pipelines, cmd_info.current_pipeline);
    if pipeline == null || pipeline.mtl_render_pipeline == null {
        log_error("gpu_draw_indexed_instanced: pipeline is null or pipeline.mtl_render_pipeline is null");
        return .ERROR_INVALID_PIPELINE;
    }

    // Set argument table with buffer addresses
    if global_argument_table != null {
        MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) vertex_data, 0);
        MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) pixel_data, 1);
        MTL4RenderCommandEncoder.setArgumentTable(cmd_info.current_render_encoder, global_argument_table, cast(MTLRenderStages)(MTLRenderStage.Vertex | MTLRenderStage.Fragment));
    }

    if index_size != 4 && index_size != 2 then return .ERROR_INVALID_VERTEX_INDEX_SIZE;

    index_type: MTLIndexType = ifx index_size == 4 then .UInt32 else .UInt16;

    // Metal 4 uses GPU addresses for index buffers
    // The index_data is already a Gpu_Ptr (GPU address), so we use it directly
    index_buffer_address := cast(MTLGPUAddress) index_data;
    index_buffer_length := (index_count * index_size).(NSUInteger);

    log("index_count % - index_type % - index_buffer_address % - index_buffer_length % - instance_count %",
        index_count, index_type, index_buffer_address, index_buffer_length, instance_count);

    MTL4RenderCommandEncoder.drawIndexedPrimitives(
        cmd_info.current_render_encoder,
        .Triangle,
        index_count.(NSUInteger),
        index_type,
        index_buffer_address,
        index_buffer_length,
        instance_count.(NSUInteger)
    );

    return .SUCCESS;
}

Gpu_Timeline_Pair :: struct {
    semaphore: Gpu_Semaphore;
    value: u64;
}

#scope_module

Queue :: struct {
    mtl4_queue: *MTL4CommandQueue;
    index_in_type: u32;
    type: Gpu_Queue_Type;
}


init_queues :: () {
    auto_release_temp();

    // Create MTL4 command queues for each type
    mtl4_desc := objc_new_defer_release(MTL4CommandQueueDescriptor);
    error: *NSError = null;

    // MAIN queue
    queues[0].type = .MAIN;
    queues[0].index_in_type = 0;
    queues[0].mtl4_queue = MTLDevice.newMTL4CommandQueueWithDescriptor(mtl_device, mtl4_desc, *error);

    // COMPUTE queues (4 of them, but Metal doesn't really distinguish - they all go to same HW)
    for i: 0..MAX_COMPUTE_QUEUES-1 {
        queues[1 + i].type = .COMPUTE;
        queues[1 + i].index_in_type = i.(u32);
        error = null;
        queues[1 + i].mtl4_queue = MTLDevice.newMTL4CommandQueueWithDescriptor(mtl_device, mtl4_desc, *error);
    }

    // TRANSFER queues (2 of them)
    for i: 0..MAX_TRANSFER_QUEUES-1 {
        queues[5 + i].type = .TRANSFER;
        queues[5 + i].index_in_type = i.(u32);
        error = null;
        queues[5 + i].mtl4_queue = MTLDevice.newMTL4CommandQueueWithDescriptor(mtl_device, mtl4_desc, *error);
    }
}

shutdown_queues :: () {
    for * queues {
        if it.mtl4_queue != null {
            release(it.mtl4_queue);
            it.mtl4_queue = null;
        }
    }
}

get_queue :: (queue_handle: Gpu_Queue) -> *Queue {
    queue_index := queue_handle - 1;
    if queue_index < 0 || queue_index >= queues.count {
        return null;
    }
    return *queues[queue_index];
}

Command_Buffer_Info :: struct {
    mtl4_cmd_buffer: *MTL4CommandBuffer;
    mtl4_allocator: *MTL4CommandAllocator;
    queue: Gpu_Queue;
    current_compute_encoder: *MTL4ComputeCommandEncoder;
    current_render_encoder: *MTL4RenderCommandEncoder;
    current_pipeline: Gpu_Pipeline;
    render_width: u32;
    render_height: u32;
}

get_cmd_info :: (cmd: Gpu_Command_Buffer) -> *Command_Buffer_Info {
    index := cast(s64) cmd - 1;
    if index < 0 || index >= live_command_buffers.count {
        return null;
    }
    return *live_command_buffers[index];
}

ensure_compute_encoder :: (using cmd_info: *Command_Buffer_Info) -> *MTL4ComputeCommandEncoder {
    assert(cmd_info != null);

    if current_compute_encoder == null {
        current_compute_encoder = mtl4_cmd_buffer.computeCommandEncoder(mtl4_cmd_buffer);
    }

    return current_compute_encoder;
}

end_current_compute_encoder :: (using cmd_info: *Command_Buffer_Info) {
    assert(cmd_info != null);

    if current_compute_encoder == null return;
    current_compute_encoder.endEncoding(current_compute_encoder);
    current_compute_encoder = null;
}

end_current_render_encoder :: (using cmd_info: *Command_Buffer_Info) {
    assert(cmd_info != null);

    if current_render_encoder == null return;
    current_render_encoder.endEncoding(current_render_encoder);
    current_render_encoder = null;
}

// Helper functions for Metal enum conversions
load_op_to_mtl :: (op: Load_Op) -> MTLLoadAction {
    if op == {
        case .LOAD;      return .Load;
        case .CLEAR;     return .Clear;
        case .DONT_CARE; return .DontCare;
    }
    return .DontCare;
}

store_op_to_mtl :: (op: Store_Op) -> MTLStoreAction {
    if op == {
        case .STORE;     return .Store;
        case .DONT_CARE; return .DontCare;
    }
    return .DontCare;
}

compare_op_to_mtl :: (op: Op) -> MTLCompareFunction {
    if op == {
        case .NEVER;            return .Never;
        case .LESS;             return .Less;
        case .EQUAL;            return .Equal;
        case .LESS_OR_EQUAL;    return .LessEqual;
        case .GREATER;          return .Greater;
        case .NOT_EQUAL;        return .NotEqual;
        case .GREATER_OR_EQUAL; return .GreaterEqual;
        case .ALWAYS;           return .Always;
    }
    return .Always;
}

stencil_op_to_mtl :: (op: Stencil_Op) -> MTLStencilOperation {
    if op == {
        case .KEEP;                return .Keep;
        case .ZERO;                return .Zero;
        case .REPLACE;             return .Replace;
        case .INVERT;              return .Invert;
        case .INCREMENT_AND_CLAMP; return .IncrementClamp;
        case .DECREMENT_AND_CLAMP; return .DecrementClamp;
        case .INCREMENT_AND_WRAP;  return .IncrementWrap;
        case .DECREMENT_AND_WARP;  return .DecrementWrap;
    }
    return .Keep;
}

live_command_buffers: [..] Command_Buffer_Info;
queues: [7] Queue;
