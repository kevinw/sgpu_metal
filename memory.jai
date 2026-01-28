Gpu_Ptr :: #type,distinct u64;

Memory_Type :: enum {
    DEFAULT;
    GPU;
    READBACK;
}

gpu_malloc :: ($type: Type, memory_type: Memory_Type = .DEFAULT) -> (mapped: *type, gpu: Gpu_Ptr) {
    cpu_ptr, gpu_ptr := gpu_malloc(size_of(type), memory_type);
    return cpu_ptr.(*type), gpu_ptr;
}

gpu_malloc :: (size: s64, memory_type: Memory_Type = .DEFAULT) -> (mapped: *void, gpu: Gpu_Ptr) {
    // Determine Metal storage mode based on memory type
    options: MTLResourceOptions;
    if #complete memory_type == {
        case .DEFAULT;
            // Shared storage - accessible by both CPU and GPU
            options = cast(MTLResourceOptions) MTLResource.StorageModeShared;
        case .GPU;
            // Private storage - only accessible by GPU
            options = cast(MTLResourceOptions) MTLResource.StorageModePrivate;
        case .READBACK;
            // Shared storage for readback (same as DEFAULT on unified memory architecture)
            options = cast(MTLResourceOptions) MTLResource.StorageModeShared;
    }

    // Create the Metal buffer
    mtl_buffer := MTLDevice.newBufferWithLength(mtl_device, size.(NSUInteger), options);
    if mtl_buffer == null {
        return null, 0;
    }

    // Get the GPU address
    gpu_ptr := cast(Gpu_Ptr) MTLBuffer.gpuAddress(mtl_buffer);
    if gpu_ptr == 0 {
        // Failed to get GPU address - this shouldn't happen on modern Metal
        // Release the buffer (Metal uses reference counting, but we created it)
        release(mtl_buffer);
        return null, 0;
    }

    // Build allocation info
    result: Alloc_Info;
    result.mtl_buffer = mtl_buffer;
    result.gpu_ptr = gpu_ptr;
    result.type = memory_type;
    result.size = size;

    // Get CPU pointer if applicable
    mapped: *void = null;
    if memory_type != .GPU {
        mapped = MTLBuffer.contents(mtl_buffer);
        table_add(*cpu_allocations, mapped, result);
    }

    table_add(*gpu_allocations, gpu_ptr, result);
    array_add(*gpu_memory_ranges, .{start = gpu_ptr, end = gpu_ptr + size.(Gpu_Ptr)});

    return mapped, gpu_ptr;
}

gpu_free :: (ptr: *void) {
    removed, alloc := table_remove(*cpu_allocations, ptr);
    if removed {
        release(alloc.mtl_buffer);

        removed = table_remove(*gpu_allocations, alloc.gpu_ptr);
        debug_assert(removed);

        removed = remove_gpu_memory_range(alloc.gpu_ptr);
        debug_assert(removed);
    }
}

gpu_free :: (gpu_ptr: Gpu_Ptr) {
    removed, alloc := table_remove(*gpu_allocations, gpu_ptr);
    if removed {
        release(alloc.mtl_buffer);

        removed = remove_gpu_memory_range(alloc.gpu_ptr);
        debug_assert(removed);
    }
}

gpu_host_to_device_ptr :: (host: *void) -> Gpu_Ptr {
    found, alloc := table_find(*cpu_allocations, host);
    if found {
        return alloc.gpu_ptr;
    }
    return 0;
}

#scope_module

Alloc_Info :: struct {
    mtl_buffer: *MTLBuffer;
    gpu_ptr: Gpu_Ptr;
    type: Memory_Type;
    size: s64;
}

/** Maps the mapped cpu accessible pointer to a given gpu memory allocation */
cpu_allocations: Table(*void, Alloc_Info);
/** Maps the gpu accessible pointer to a given gpu memory allocation */
gpu_allocations: Table(Gpu_Ptr, Alloc_Info);

Gpu_Memory_Range :: struct {
    start: Gpu_Ptr;
    end: Gpu_Ptr;
}

// Store memory ranges for lookup during copies
gpu_memory_ranges: [..] Gpu_Memory_Range;

find_memory_range :: (ptr: Gpu_Ptr) -> Gpu_Result, Gpu_Memory_Range {
    for gpu_memory_ranges {
        if ptr >= it.start && ptr < it.end then return .SUCCESS, it;
    }
    return .ERROR_UNKNOWN_GPU_POINTER, .{};
}

remove_gpu_memory_range :: (start_ptr: Gpu_Ptr) -> bool {
    for gpu_memory_ranges {
        if it.start == start_ptr {
            remove it;
            return true;
        }
    }
    return false;
}

get_buffer :: (gpu_ptr: Gpu_Ptr) -> *MTLBuffer {
    found, alloc := table_find(*gpu_allocations, gpu_ptr);
    if !found {
        return null;
    }
    return alloc.mtl_buffer;
}

get_buffer_and_offset :: (gpu_ptr: Gpu_Ptr) -> Gpu_Result, *MTLBuffer, s64 {
    result, range := find_memory_range(gpu_ptr);
    if result != .SUCCESS then return result, null, 0;
    debug_assert(range.start != 0);

    mtl_buffer := get_buffer(range.start);
    debug_assert(mtl_buffer != null);
    return .SUCCESS, mtl_buffer, (gpu_ptr - range.start).(s64);
}

#import "Hash_Table";
