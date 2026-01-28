#scope_export

// Load and compile a Metal shader from a .metal file
load_and_compile_metal_shader :: (metal_file_path: string) -> bool, string {
    // Read the Metal shader source file
    metal_source, success := read_entire_file(metal_file_path);
    if !success {
        log_error("Failed to read Metal shader file: %", metal_file_path);
        return false, "";
    }

    return true, metal_source;
}

#scope_module

#import "File";
