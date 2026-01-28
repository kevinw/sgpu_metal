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
    if queue == null {
        return .FATAL_ERROR_UNKNOWN, 0;
    }

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
    cmd_info: Command_Buffer_Info;
    cmd_info.mtl4_cmd_buffer = mtl4_cmd_buffer;
    cmd_info.mtl4_allocator = mtl4_allocator;
    cmd_info.queue = queue_handle;
    cmd_info.current_compute_encoder = null;

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
    if cmd_info == null then return .ERROR_INVALID_BUFFER;

    dest_result, dest_buffer, dest_offset := get_buffer_and_offset(dest);
    if dest_result != .SUCCESS then return dest_result;

    src_result, src_buffer, src_offset := get_buffer_and_offset(src);
    if src_result != .SUCCESS then return src_result;

    // Get or create the MTL4 compute encoder (handles blit operations in Metal 4)
    compute_encoder := ensure_compute_encoder(cmd_info);
    if compute_encoder == null then return .FATAL_ERROR_UNKNOWN;

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
    cmd_info := get_cmd_info(cmd);
    if cmd_info == null then return;

    // In Metal 4, barriers are handled by ending and starting new encoders
    if cmd_info.current_compute_encoder != null {
        // End the current encoder and start a new one to ensure ordering
        end_current_encoder(cmd_info);
    }
}

gpu_submit :: (cmd_buff: Gpu_Command_Buffer, signals: [] Gpu_Timeline_Pair = .[], waits: [] Gpu_Timeline_Pair = .[]) {
    cmd_info := get_cmd_info(cmd_buff);
    if cmd_info == null then return;

    queue := get_queue(cmd_info.queue);
    if queue == null then return;

    // End any active encoder
    end_current_encoder(cmd_info);

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
        if it.mtl4_cmd_buffer != null {
            release(it.mtl4_cmd_buffer);
            it.mtl4_cmd_buffer = null;
        }
        if it.mtl4_allocator != null {
            release(it.mtl4_allocator);
            it.mtl4_allocator = null;
        }
        it.current_compute_encoder = null;
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
            release(it.mtl4_cmd_buffer);
            it.mtl4_cmd_buffer = null;
            if it.mtl4_allocator != null {
                release(it.mtl4_allocator);
                it.mtl4_allocator = null;
            }
            it.current_compute_encoder = null;
        }
    }
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

// Pre-defined queue slots
queues: [7] Queue;

init_queues :: () {
    auto_release_temp();

    // Create MTL4 command queues for each type
    mtl4_desc := objc_new(MTL4CommandQueueDescriptor);
    defer release(mtl4_desc);
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
    current_compute_encoder: *MTL4ComputeCommandEncoder;  // Used for both compute and blit ops in MTL4
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

ensure_compute_encoder :: (cmd_info: *Command_Buffer_Info) -> *MTL4ComputeCommandEncoder {
    if cmd_info.current_compute_encoder != null {
        return cmd_info.current_compute_encoder;
    }

    // Create a new MTL4 compute encoder (handles both compute and blit operations)
    cmd_info.current_compute_encoder = MTL4CommandBuffer.computeCommandEncoder(cmd_info.mtl4_cmd_buffer);
    return cmd_info.current_compute_encoder;
}

end_current_encoder :: (cmd_info: *Command_Buffer_Info) {
    if cmd_info.current_compute_encoder != null {
        MTL4CommandEncoder.endEncoding(cast(*MTL4CommandEncoder) cmd_info.current_compute_encoder);
        cmd_info.current_compute_encoder = null;
    }
}
