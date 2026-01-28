#scope_export

gpu_get_queue :: (queue_type: Gpu_Queue_Type, queue_index: u32) -> Gpu_Queue {
    for queues {
        if it.type == queue_type && it.index_in_type == queue_index then return (it_index + 1).(Gpu_Queue);
    }
    return 0;
}

gpu_start_command_recording :: (queue_handle: Gpu_Queue) -> Gpu_Result, Gpu_Command_Buffer {
    queue := get_queue(queue_handle);
    if queue == null {
        return .FATAL_ERROR_UNKNOWN, 0;
    }

    // Get a command buffer from the queue
    mtl_cmd_buffer := MTLCommandQueue.commandBuffer(queue.mtl_queue);
    if mtl_cmd_buffer == null {
        return .ERROR_COMMAND_BUFFER_LIMIT_EXCEEDED, 0;
    }

    // Store the command buffer info
    cmd_info: Command_Buffer_Info;
    cmd_info.mtl_cmd_buffer = mtl_cmd_buffer;
    cmd_info.queue = queue_handle;
    cmd_info.current_blit_encoder = null;

    // Find an empty slot in live command buffers
    found_slot := false;
    slot_index: s64 = -1;
    for * live_command_buffers {
        if it.mtl_cmd_buffer == null {
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
    if cmd_info == null then return .ERROR_INVALID_BUFFER;

    dest_result, dest_buffer, dest_offset := get_buffer_and_offset(dest);
    if dest_result != .SUCCESS then return dest_result;

    src_result, src_buffer, src_offset := get_buffer_and_offset(src);
    if src_result != .SUCCESS then return src_result;

    // Get or create the blit encoder
    blit_encoder := ensure_blit_encoder(cmd_info);
    if blit_encoder == null then return .FATAL_ERROR_UNKNOWN;

    // Perform the copy
    MTLBlitCommandEncoder.copyFromBuffer(
        blit_encoder,
        src_buffer,
        src_offset.(NSUInteger),
        dest_buffer,
        dest_offset.(NSUInteger),
        num_bytes.(NSUInteger)
    );

    return .SUCCESS;
}

gpu_barrier :: (cmd: Gpu_Command_Buffer, src_stage: Stage, dst_stage: Stage) {
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    // In Metal, barriers within blit encoders are typically handled by ending and starting new encoders
    // For simple transfer-to-transfer barriers, we can use memoryBarrier on the blit encoder
    if cmd_info.current_blit_encoder != null {
        // End the current encoder and start a new one to ensure ordering
        end_current_encoder(cmd_info);
    }
}

gpu_submit :: (cmd_buff: Gpu_Command_Buffer, signals: [] Gpu_Timeline_Pair = .[], waits: [] Gpu_Timeline_Pair = .[]) {
    cmd_info := get_cmd_info(cmd_buff);
    if cmd_info == null then return;

    // End any active encoder
    end_current_encoder(cmd_info);

    // Commit the command buffer
    MTLCommandBuffer.commit(cmd_info.mtl_cmd_buffer);

    // Mark slot as available (don't clear mtl_cmd_buffer yet - we need it for wait_idle)
    // The command buffer is now owned by Metal until completion
}

gpu_wait_idle :: () {
    // Wait for all submitted command buffers to complete
    for * live_command_buffers {
        if it.mtl_cmd_buffer != null {
            MTLCommandBuffer.waitUntilCompleted(it.mtl_cmd_buffer);
            // Now we can clear the slot
            it.mtl_cmd_buffer = null;
            it.current_blit_encoder = null;
        }
    }
}

gpu_queue_wait_idle :: (queue_handle: Gpu_Queue) {
    queue := get_queue(queue_handle);
    if queue == null then return;

    // Wait for all command buffers on this queue
    for * live_command_buffers {
        if it.mtl_cmd_buffer != null && it.queue == queue_handle {
            MTLCommandBuffer.waitUntilCompleted(it.mtl_cmd_buffer);
            it.mtl_cmd_buffer = null;
            it.current_blit_encoder = null;
        }
    }
}

Gpu_Timeline_Pair :: struct {
    semaphore: Gpu_Semaphore;
    value: u64;
}

#scope_module

Queue :: struct {
    mtl_queue: *MTLCommandQueue;
    index_in_type: u32;
    type: Gpu_Queue_Type;
}

// Pre-defined queue slots
queues: [7] Queue;

init_queues :: () {
    // Create command queues for each type
    // MAIN queue
    queues[0].type = .MAIN;
    queues[0].index_in_type = 0;
    queues[0].mtl_queue = MTLDevice.newCommandQueue(mtl_device);

    // COMPUTE queues (4 of them, but Metal doesn't really distinguish - they all go to same HW)
    for i: 0..MAX_COMPUTE_QUEUES-1 {
        queues[1 + i].type = .COMPUTE;
        queues[1 + i].index_in_type = i.(u32);
        queues[1 + i].mtl_queue = MTLDevice.newCommandQueue(mtl_device);
    }

    // TRANSFER queues (2 of them)
    for i: 0..MAX_TRANSFER_QUEUES-1 {
        queues[5 + i].type = .TRANSFER;
        queues[5 + i].index_in_type = i.(u32);
        queues[5 + i].mtl_queue = MTLDevice.newCommandQueue(mtl_device);
    }
}

shutdown_queues :: () {
    for * queues {
        if it.mtl_queue != null {
            release(it.mtl_queue);
            it.mtl_queue = null;
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
    mtl_cmd_buffer: *MTLCommandBuffer;
    queue: Gpu_Queue;
    current_blit_encoder: *MTLBlitCommandEncoder;
    current_pipeline: Gpu_Pipeline;
}

live_command_buffers: [..] Command_Buffer_Info;

get_cmd_info :: (cmd: Gpu_Command_Buffer) -> *Command_Buffer_Info {
    index := cast(s64) cmd - 1;
    if index < 0 || index >= live_command_buffers.count {
        return null;
    }
    return *live_command_buffers[index];
}

ensure_blit_encoder :: (cmd_info: *Command_Buffer_Info) -> *MTLBlitCommandEncoder {
    if cmd_info.current_blit_encoder != null {
        return cmd_info.current_blit_encoder;
    }

    // Create a new blit encoder
    cmd_info.current_blit_encoder = MTLCommandBuffer.blitCommandEncoder(cmd_info.mtl_cmd_buffer);
    return cmd_info.current_blit_encoder;
}

end_current_encoder :: (cmd_info: *Command_Buffer_Info) {
    if cmd_info.current_blit_encoder != null {
        MTLCommandEncoder.endEncoding(cmd_info.current_blit_encoder);
        cmd_info.current_blit_encoder = null;
    }
}
