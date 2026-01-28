#scope_export

global_argument_table: *MTL4ArgumentTable; // Global bindless argument table that holds all GPU resources
next_buffer_index: u32 = 0; // Counter for buffer binding indices

// Initialize the global bindless argument table
init_bindless :: () {
    if global_argument_table != null return; // Already initialized

    auto_release_temp();

    // Create the argument table descriptor
    descriptor := objc_new(MTL4ArgumentTableDescriptor);
    defer release(descriptor);
    {
        using MTL4ArgumentTableDescriptor;

        // Set maximum bind counts (these are generous limits for a bindless system)
        setMaxBufferBindCount      (descriptor, MAX_BUFFERS.(NSUInteger));
        setMaxTextureBindCount     (descriptor, MAX_IMAGES.(NSUInteger));
        setMaxSamplerStateBindCount(descriptor, MAX_SAMPLERS.(NSUInteger));

        // Enable support for attribute strides (optional but useful)
        setSupportAttributeStrides(descriptor, YES);

        // Don't initialize bindings - we'll set them as needed
        setInitializeBindings(descriptor, NO);
    }

    // Create the global argument table
    error: *NSError = null;
    global_argument_table = MTLDevice.newArgumentTableWithDescriptor(mtl_device, descriptor, *error);

    if error != null {
        error_str := to_string(NSError.localizedDescription(error));
        log_error("Failed to create global argument table: %", error_str);
        global_argument_table = null;
        return;
    }

    assert(global_argument_table != null, "Failed to create global argument table");

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
        assert(global_argument_table != null);
    }

    index := atomic_add(*next_buffer_index, 1);
    assert(index < MAX_BUFFERS, "Exceeded maximum buffer bind count in argument table");

    // Set the buffer address in the argument table
    MTL4ArgumentTable.setAddress(global_argument_table, cast(MTLGPUAddress) gpu_ptr, cast(NSUInteger)index);

    return index;
}

#scope_module

MTLGPUAddress :: #type u64;
