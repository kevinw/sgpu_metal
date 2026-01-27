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
    cf_path         := sprint("%/CoreFoundation.framework/Headers", frameworks_path);
    metal_path      := tprint("%/Metal.framework/Headers", frameworks_path);

    print("METAL is at %\n\n", metal_path);

    all_metal_files := string.[
        "MTLTypes.h",
        "MTLBuffer.h",
        "MTLResource.h",
        "MTLTexture.h",
        "MTLResourceViewPool.h",
        "MTLResourceStateCommandEncoder.h",
        "MTLComputeCommandEncoder.h",
        "MTLHeap.h",
        "MTLArgumentEncoder.h",
        "MTLCommandBuffer.h",
        "MTLDevice.h",
        "MTLIOCommandBuffer.h",
        "MTLIOCommandQueue.h",
        "MTLLogState.h",
        "MTLLibrary.h",
        "MTLComputePipeline.h",
        "MTLBinaryArchive.h",
        "MTLComputePass.h",
        "MTLDrawable.h",
        "MTLDynamicLibrary.h",
        "MTLRasterizationRate.h",
        "MTLParallelRenderCommandEncoder.h",
        "MTLRenderCommandEncoder.h",
        "MTLTextureViewPool.h",
        "MTLEvent.h",
        "MTLSampler.h",
        "MTLFunctionLog.h",
        "MTLRenderPipeline.h",
        "MTLIntersectionFunctionTable.h",
        "MTLResidencySet.h",
        "MTLFunctionStitching.h",
        "MTLVertexDescriptor.h",
        "MTLVisibleFunctionTable.h",
        "MTL4StitchedFunctionDescriptor.h",
        "MTL4RenderPass.h",
    ];

    simple_metal_files := string.[
        "MTLTypes.h",
        "MTLTexture.h",
        "MTLCommandEncoder.h",
        "MTLRenderCommandEncoder.h",
    ];

    single_metal_files := string.[
        "Metal.h",
    ];

    // What to point the Bindings_Generator at.
    src_files: [..]string;
    for header_name: single_metal_files {
        filename := sprint("%/%", metal_path, header_name);
        array_add(*src_files, filename);
        assert(file_exists(filename), tprint("Expected file to exist: %", filename));
    }

    if !is_directory(metal_path) {
        log_error("Metal headers not found at expected location '%'", metal_path);
        return false;
    }

    opts: Generate_Bindings_Options;
    {
        using opts;
        log_unsupported = true;
        generate_compile_time_struct_checks = false;  // ObjC interfaces have opaque layouts
        array_add(*source_files,  ..src_files);
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
#import "macOS";

// Types not automatically imported
IOSurfaceRef :: *void;
Block :: *void;  // Objective-C blocks - opaque pointer
task_id_token_t :: u32;  // Mach task identity token

// Forward declaration for NSNumber (used by Metal but not in base Objective_C module)
NSNumber :: struct { #as using nsobject: NSObject; }

// Empty protocol structs for inheritance
NSFastEnumeration :: struct {}
NSCopying :: struct {}
NSSecureCoding :: struct {}

HEADER;
    }

    return generate_bindings(opts, "module.jai");
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

    if parent_decl == null && decl.kind == .STRUCT && starts_with(decl.output_name, "MTL") {
        // The bindings generator will "helpfully" give us output names which
        // might clash with other functions with identical argument types.
        //
        // Here we disambiguate by turning "presentDrawable" into "presentDrawable_atTime"

        fns: [..]struct { hash_val: u32; fn: *Function; };
        for child: decl.(*Struct).declarations {
            if child.kind != .FUNCTION continue;
            fn := child.(*Function);
            h := hash_function_output_name_and_argument_types(fn);
            other_count := 0;
            for fns if it.hash_val == h {
                other_count += 1;
            }
            print("% % %\n", fn.output_name, fn.name, h);
            if other_count > 0 {
                fn.output_name = convert_objc_fn_name(fn.name);
            }
            array_add(*fns, {h, fn});
            //found, new_val := table_find(*dup_fn_names, h);
            //value_ptr := table_set(*dup_fn_names, h, new_val + 1);
            //print("% % % % % %\n", fn.name, h, decl.kind, new_val, *dup_fn_names, value_ptr);
        }
    }

    if parent_decl && parent_decl.kind == .STRUCT && starts_with(parent_decl.output_name, "MTL") {
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
    for 0..output.count-1 {
        if output.data[it] == #char ":" {
            output.data[it] = #char "_";
        }
    }
    if output[output.count - 1] == ":" {
        output.count -= 1;
    }
    return output;
}

dup_fn_names: Table(u32, u64);

#import "Bindings_Generator";
#import "Process";
#import "Compiler";
#import "Basic";
#import "String";
#import "File_Utilities";
#import "macOS/Toolchain";
#import "Hash_Table";
#import "Hash";
