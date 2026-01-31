#scope_export

Native_Window_Type :: enum {
    UNKNOWN;
    WIN32;
    X11;
    WAYLAND;
    COCOA;
}

gpu_init_swapchain :: (native_window: u64, window_type: Native_Window_Type) {
    assert(window_type == .COCOA, "Only Cocoa windows are supported on Metal");

    native_window_handle = native_window;
    native_window_type = window_type;

    // Get the CAMetalLayer from the NSWindow
    ns_window := cast(*NSWindow) native_window;
    swapchain_layer = ns_window_get_metal_layer(ns_window);
    assert(swapchain_layer != null, "Failed to get CAMetalLayer from window");

    // Configure the Metal layer
    CAMetalLayer.setDevice(swapchain_layer, mtl_device);
    CAMetalLayer.setPixelFormat(swapchain_layer, .BGRA8Unorm);
    CAMetalLayer.setFramebufferOnly(swapchain_layer, NO);  // Allow reading from swapchain textures

    // Get the initial drawable size
    drawable_size := CAMetalLayer.drawableSize(swapchain_layer);
    surface_width = cast(u32) drawable_size.width;
    surface_height = cast(u32) drawable_size.height;

    // Create the frame timeline semaphore for synchronization
    gpu_frame_timeline = gpu_create_semaphore(0);
}

gpu_swapchain_resize :: () {
    // Wait for any pending work to complete
    gpu_wait_idle();

    // Get the new drawable size
    drawable_size := CAMetalLayer.drawableSize(swapchain_layer);
    surface_width = cast(u32) drawable_size.width;
    surface_height = cast(u32) drawable_size.height;

    // Clean up old swapchain texture views
    cleanup_swapchain_views();
}

gpu_destroy_swapchain :: () {
    cleanup_swapchain_views();

    if gpu_frame_timeline != 0 {
        gpu_destroy_semaphore(gpu_frame_timeline);
        gpu_frame_timeline = 0;
    }

    swapchain_layer = null;
}

gpu_swapchain_acquire :: () -> Gpu_Result, Gpu_Texture_View {
    // Wait for the next frame slot to be available
    wait_next_frame();

    // Create an autorelease pool for this frame
    release_and_set_null(*swapchain_autorelease_pool);
    swapchain_autorelease_pool = objc_new(NSAutoreleasePool);

    // Get the next drawable from the layer
    current_drawable = CAMetalLayer.nextDrawable(swapchain_layer);
    if current_drawable == null {
        return .SUCCESS, 0;  // No drawable available (timeout or error)
    }

    cpu_frame_timeline += 1;

    // Get the drawable's texture
    drawable_texture := CAMetalDrawable.texture(current_drawable);
    if drawable_texture == null {
        return .SUCCESS, 0;
    }

    // Create or update the texture view for this drawable
    current_swapchain_view = create_swapchain_texture_view(drawable_texture);

    return .SUCCESS, current_swapchain_view;
}

gpu_submit_and_present :: (cmd_buff: Gpu_Command_Buffer, signals: [] Gpu_Timeline_Pair = .[], waits: [] Gpu_Timeline_Pair = .[]) {
    cmd_info := get_cmd_info(cmd_buff);
    if cmd_info == null then return;

    queue := get_queue(cmd_info.queue);
    if queue == null then return;

    // End any active encoder (render or compute)
    end_current_compute_encoder(cmd_info);
    end_current_render_encoder(cmd_info);

    // End the command buffer recording
    MTL4CommandBuffer.endCommandBuffer(cmd_info.mtl4_cmd_buffer);

    // Metal 4 presentation flow:
    // 1. Wait for drawable to be ready
    // 2. Commit command buffer
    // 3. Signal drawable completion
    // 4. Present drawable

    MTL4CommandQueue.waitForDrawable(queue.mtl4_queue, current_drawable);

    // Commit the command buffer
    cmd_buffers: [1] *MTL4CommandBuffer;
    cmd_buffers[0] = cmd_info.mtl4_cmd_buffer;
    MTL4CommandQueue.commit(queue.mtl4_queue, cmd_buffers.data, 1);

    // Signal that rendering to drawable is complete
    MTL4CommandQueue.signalDrawable(queue.mtl4_queue, current_drawable);

    // Signal the frame timeline
    if gpu_frame_timeline != 0 {
        semaphore := get_semaphore(gpu_frame_timeline);
        if semaphore != null && semaphore.mtl_event != null {
            MTL4CommandQueue.signalEvent(queue.mtl4_queue, semaphore.mtl_event, cpu_frame_timeline);
        }
    }

    // Present the drawable
    CAMetalDrawable.present(current_drawable);

    // Clear the current drawable reference (Metal owns it now)
    current_drawable = null;

    release_and_set_null(*swapchain_autorelease_pool);
}

gpu_present :: () {
    if current_drawable != null {
        CAMetalDrawable.present(current_drawable);
        current_drawable = null;
    }
}

gpu_get_frame_timeline :: () -> Gpu_Semaphore {
    return gpu_frame_timeline;
}

gpu_frame_index :: () -> u32 {
    return (cpu_frame_timeline % MAX_FRAMES_IN_FLIGHT).(u32);
}

#scope_module

native_window_handle: u64;
native_window_type: Native_Window_Type;
swapchain_layer: *CAMetalLayer;
surface_width: u32;
surface_height: u32;

current_drawable: *CAMetalDrawable;
current_swapchain_view: Gpu_Texture_View;

// Frame timeline for synchronization
gpu_frame_timeline: Gpu_Semaphore;
cpu_frame_timeline: u64;

// Swapchain texture tracking
Swapchain_Texture_Entry :: struct {
    texture_handle: Gpu_Texture;
    view_handle: Gpu_Texture_View;
    mtl_texture: *MTLTexture;
}

swapchain_textures: [..] Swapchain_Texture_Entry;

wait_next_frame :: () {
    if cpu_frame_timeline >= MAX_FRAMES_IN_FLIGHT {
        wait_value := cpu_frame_timeline + 1 - MAX_FRAMES_IN_FLIGHT;
        gpu_wait_semaphore(.{gpu_frame_timeline, wait_value});
    }
}

create_swapchain_texture_view :: (mtl_texture: *MTLTexture) -> Gpu_Texture_View {
    // Check if we already have a view for this texture
    for * swapchain_textures {
        if it.mtl_texture == mtl_texture {
            return it.view_handle;
        }
    }

    // Create new texture and view handles
    width := MTLTexture.width(mtl_texture).(u32);
    height := MTLTexture.height(mtl_texture).(u32);

    texture_desc := Gpu_Texture_Desc.{
        type = ._2D,
        dimensions = .[width, height, 1],
        mip_count = 1,
        layer_count = 1,
        sample_count = 1,
        format = .B8G8R8A8_UNORM,
        usage = .COLOR_ATTACHMENT | .TRANSFER_DST,
    };

    // Add to textures pool
    texture_handle := pool_add(*live_textures, .{
        desc = texture_desc,
        mtl_texture = mtl_texture,
    });

    // Create texture view
    view_handle := pool_add(*live_texture_views, .{
        texture = texture_handle,
        mtl_texture = mtl_texture,
        desc = .{
            format = .B8G8R8A8_UNORM,
            base_mip = 0,
            mip_count = 1,
            base_layer = 0,
            layer_count = 1,
        },
    });

    // Track this swapchain texture
    entry: Swapchain_Texture_Entry;
    entry.texture_handle = texture_handle;
    entry.view_handle = view_handle;
    entry.mtl_texture = mtl_texture;
    array_add(*swapchain_textures, entry);

    return view_handle;
}

cleanup_swapchain_views :: () {
    for swapchain_textures {
        pool_remove(*live_texture_views, it.view_handle);
        pool_remove(*live_textures, it.texture_handle);
    }
    array_reset(*swapchain_textures);
    current_swapchain_view = 0;
}

ns_window_get_metal_layer :: (window: *NSWindow) -> *CAMetalLayer {
    ns_view := NSWindow.contentView(window);
    if !ns_view {
        return null;
    }

    layer := NSView.layer(ns_view);
    if !layer {
        return null;
    }

    // Check if the layer is a CAMetalLayer
    if !is_kind_of_class(cast(id) layer, objc_getClass("CAMetalLayer")) {
        return null;
    }

    return cast(*CAMetalLayer) layer;
}

is_kind_of_class :: (obj: id, class: Class) -> bool {
    sel := sel_registerName("isKindOfClass:");
    func: (id, Selector, Class) -> BOOL #c_call;
    func = xx objc_msgSend;
    return func(obj, sel, class) == YES;
}

swapchain_autorelease_pool: *NSAutoreleasePool;

#import "Objective_C";
#import "Objective_C/AppKit";
