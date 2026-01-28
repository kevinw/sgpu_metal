#scope_export

// Global bindless argument table that holds all GPU resources
global_argument_table: *MTL4ArgumentTable;

// Counter for buffer binding indices
next_buffer_index: u32 = 0;

// Initialize the global bindless argument table
init_bindless :: () {
    if global_argument_table != null return; // Already initialized

    auto_release_temp();

    // Create the argument table descriptor
    descriptor := objc_new(MTL4ArgumentTableDescriptor);
    defer release(descriptor);

    // Set maximum bind counts (these are generous limits for a bindless system)
    MTL4ArgumentTableDescriptor.setMaxBufferBindCount(descriptor, MAX_BUFFERS.(NSUInteger));
    MTL4ArgumentTableDescriptor.setMaxTextureBindCount(descriptor, MAX_IMAGES.(NSUInteger));
    MTL4ArgumentTableDescriptor.setMaxSamplerStateBindCount(descriptor, MAX_SAMPLERS.(NSUInteger));

    // Enable support for attribute strides (optional but useful)
    MTL4ArgumentTableDescriptor.setSupportAttributeStrides(descriptor, 1);

    // Don't initialize bindings - we'll set them as needed
    MTL4ArgumentTableDescriptor.setInitializeBindings(descriptor, 0);

    // Create the global argument table
    error: *NSError = null;
    global_argument_table = MTLDevice.newArgumentTableWithDescriptor(mtl_device, descriptor, *error);

    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to create global argument table: %", error_str);
        global_argument_table = null;
        return;
    }

    if global_argument_table == null {
        log_error("Failed to create global argument table");
        return;
    }

    if 0 log("Bindless argument table initialized with % buffer slots, % texture slots, % sampler slots",
        MAX_BUFFERS, MAX_IMAGES, MAX_SAMPLERS);
}

shutdown_bindless :: () {
    if global_argument_table != null {
        release(global_argument_table);
        global_argument_table = null;
    }
}

// Add a buffer to the global argument table and return its index
register_buffer_in_argument_table :: (gpu_ptr: Gpu_Ptr) -> u32 {
    if global_argument_table == null {
        init_bindless();
        if global_argument_table == null return 0xFFFFFFFF; // Error
    }

    index := atomic_add(*next_buffer_index, 1);

    if index >= MAX_BUFFERS {
        log_error("Exceeded maximum buffer bind count in argument table");
        return 0xFFFFFFFF;
    }

    // Set the buffer address in the argument table
    MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) gpu_ptr, index.(NSUInteger));

    return index;
}

#scope_module

MTLGPUAddress :: #type u64;
