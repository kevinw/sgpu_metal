OMIT_TYPE_INFO_FOR_METAL_TYPES :: true; // Info: This struct is generating a lot of Type_Info data (10096 bytes). If you don't need Type_Info for this struct's members, you can use #type_info_none to eliminate almost all this data.

#if false {
    #run {
        set_build_options_dc(.{do_output = false});
        if !build() {
            compiler_set_workspace_status(.FAILED);
        }
    }
} else {
    main :: () {
        build();
    }
}

build :: () -> bool {
    print("Generating Metal bindings...\n");

    frameworks_path := sprint("%/System/Library/Frameworks", get_macos_sdk_path());

    if !is_directory(frameworks_path) {
        log_error("Frameworks path not found at expected location '%'", frameworks_path);
        return false;
    }

    cf_path           := sprint("%/CoreFoundation.framework/Headers", frameworks_path);
    metal_path        := tprint("%/Metal.framework/Headers", frameworks_path);
    quartzcore_path   := tprint("%/QuartzCore.framework/Headers", frameworks_path);
    coregraphics_path := tprint("%/CoreGraphics.framework/Headers", frameworks_path);

    if !is_directory(metal_path) {
        log_error("Metal headers not found at expected location '%'", metal_path);
        return false;
    }

    input_source_files := string.[
        tprint("%/Metal.h", metal_path),
        tprint("%/CAMetalLayer.h", quartzcore_path),
        tprint("%/CAEDRMetadata.h", quartzcore_path),
        tprint("%/CGColorSpace.h", coregraphics_path)
    ];

    for input_source_files assert(file_exists(it), tprint("Expected file to exist: %", it));

    opts: Generate_Bindings_Options;
    {
        using opts;
        log_unsupported = true;
        generate_compile_time_struct_checks = false;  // ObjC interfaces have opaque layouts
        alias_original_enum_names = false; // omit enum aliases like MTLVertexFormatUChar2Normalized :: UChar2Normalized;
        array_add(*source_files,  ..input_source_files);
        array_add(*extra_clang_arguments,
            "-isysroot", get_macos_sdk_path(),
            "-x", "objective-c++",
            tprint("-F%", frameworks_path),
        );
        array_add(*path_fragments_to_treat_as_non_system_paths, "Metal.framework/");
        array_add(*system_libraries, .{filename = "libobjc"});
        visitor = metal_visitor;

        header = #string HEADER
#import "Objective_C";
#import "macOS"; // TODO: iOS optionally instead

// Types not automatically imported
IOSurfaceRef :: *void;
Block :: *void;  // Objective-C blocks - opaque pointer
task_id_token_t :: u32;  // Mach task identity token
CGColorSpaceRef :: *void;
CAEDRMetadata :: *void;

// Forward declaration for NSNumber (used by Metal but not in base Objective_C module)
NSNumber :: struct { #as using nsobject: NSObject; }

// Empty protocol structs for inheritance
NSFastEnumeration :: struct {}
NSCopying :: struct {}
NSSecureCoding :: struct {}

Metal :: #library,system,link_always "Metal";  // We were having some problems on Mac, so, try this...
MTLCreateSystemDefaultDevice :: () -> *MTLDevice #foreign Metal;

MTLClearColorMake :: (red: float64, green: float64, blue: float64, alpha: float64) -> MTLClearColor {
    col: MTLClearColor = ---;
    col.red = red;
    col.green = green;
    col.blue = blue;
    col.alpha = alpha;
    return col;
}

init_metal :: () {

}

HEADER;
    }

    ok := generate_bindings(opts, "module.jai");
    if ok {
        print("Metal bindings generated from headers at %\n", metal_path);
    }
    return ok;
}

metal_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    // Types to omit - either provided by Objective_C module or defined in header
    TYPES_TO_OMIT :: string.[
        "NSObject",
        "NSString",
        "NSArray",
        "NSDictionary",
        "NSError",
        "NSBundle",
        "NSURL",
        "NSData",
        "NSNumber",
        "NSUInteger",
        "NSInteger",
        "NSSecureCoding",
        "NSCopying",
        "NSFastEnumeration",
        "IOSurfaceRef",
        "Block",
        "task_id_token_t",
        "BOOL",
        "YES",
        "NO",
        "id",
        "ID",   // Capitalized version
        "Class",
        "SEL",
        "Selector",
        "nil",
        "Nil",
        "isa",  // Member of NSObject, conflicts when using #as using
    ];

    if !parent_decl {
        if array_find(TYPES_TO_OMIT, decl.output_name) {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }
    }

    do_objc_logic :: (decl: *Declaration) -> bool { return starts_with(decl.output_name, "MTL") || starts_with(decl.output_name, "CAMetal"); }

    if parent_decl == null && decl.kind == .STRUCT && do_objc_logic(decl) {
        if OMIT_TYPE_INFO_FOR_METAL_TYPES {
            decl.decl_flags |= .TYPE_INFO_NONE;
        }

        // The bindings generator will "helpfully" give us output names which
        // might clash with other functions with identical argument types.
        //
        // Here we disambiguate by turning "presentDrawable" into "presentDrawable_atTime"

        fns: [..]struct { hash_val: u32; fn: *Function; };
        defer array_reset(*fns);

        for child: decl.(*Struct).declarations {
            if child.kind != .FUNCTION continue;
            fn := child.(*Function);
            h := hash_function_output_name_and_argument_types(fn);
            other_count := 0;
            for fns if it.hash_val == h {
                other_count += 1;
            }
            if other_count > 0 {
                fn.output_name = convert_objc_fn_name(fn.name);
            }
            array_add(*fns, {h, fn});
        }
    }

    if parent_decl && parent_decl.kind == .STRUCT && do_objc_logic(parent_decl) {
        // The bindings generator doesn't handle NSObject hierarchies at the moment.
        // Skip them for now, since all we use all MTL objects by pointer anyways.
        if decl.output_name == "nsobject" || decl.output_name == "isa" || decl.output_name == "ID" {
            parent_decl.(*Struct).flags |= .OMIT_PARENTS;
        }

    }

    return .RECURSE;
}

#scope_file

hash_function_output_name_and_argument_types :: (fn: *Function) -> u32 {
    assert(fn != null);
    assert(fn.output_name != "");

    sb: String_Builder;
    sb.allocator = temp;
    hash_val: u32 = get_hash(fn.output_name);
    for arg: fn.type.type_of_function.arguments {
        // TODO: is there a better way to compare type equality than getting the Bindings_Generator to dump it as a string?
        type_reference: Type_Reference =  { type = arg.type };
        print_expression_to_builder(*sb, *type_reference);
        arg_types_string: string = builder_to_string(*sb,, temp);
        reset(*sb);

        hash_val = get_hash(arg_types_string, hash_val);
    }
    return hash_val;
}

convert_objc_fn_name :: (name: string) -> string {
    assert(name != "");

    output := copy_string(name);

    // Convert colons to underscores.
    for 0..output.count-1 {
        if output[it] == #char ":" {
            output[it] = #char "_";
        }
    }

    // Remove trailing underscore.
    if output.count > 2 && output[output.count - 1] == #char "_" {
        output.count -= 1;
    }
    return output;
}

#import "Bindings_Generator";
#import "Process";
#import "Compiler";
#import "Basic";
#import "String";
#import "File_Utilities";
#import "macOS/Toolchain";
#import "Hash_Table";
#import "Hash";
