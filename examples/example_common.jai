EXTRA_CHECKS :: true;
SHOW_MEMORY_LEAKS :: true;

#if EXTRA_CHECKS {
    Debug :: #import "Debug";

    Example_Options :: struct {
        max_frames: int;
    }

    gpu_example_harness :: () -> Example_Options #expand {
        Debug.init();

        // Check for -singleframe argument for automated testing
        args_ok, args, is_set := parse_arguments(struct { singleframe: bool; });
        singleframe := args_ok && is_set.singleframe;
        max_frames := ifx singleframe then 5 else 0x7FFF_FFFF_FFFF_FFFF;

        #if SHOW_MEMORY_LEAKS `defer exit_with_error_on_memory_leak();

        return { max_frames=max_frames };
    }

    exit_with_error_on_memory_leak :: () {
        has_leaks := false;
        has_leaks |= show_jai_mem_leaks();
        has_leaks |= gpu_log_memory_leaks();
        if has_leaks {
            exit(1);
        }
    }

    show_jai_mem_leaks :: (options: Leak_Report_Options = .{}) -> (has_leaks: bool) {
        report := make_leak_report(options);
        defer deinit(*report);
        log_leak_report(report, options);

        has_leaks := false;
        for report.sorted_summaries if it.count > 0 {
            has_leaks = true;
        }
        return has_leaks;
    }
} else {
    example_debug_harness :: () #expand {}
}

// TODO: let the user specify these module parameters to basic, and use #if #exists ?
#import "Basic"()(
    MEMORY_DEBUGGER=EXTRA_CHECKS,
    VISUALIZE_MEMORY_DEBUGGER=false,
    TEMP_ALLOCATOR_POISON_FREED_MEMORY=EXTRA_CHECKS,
);

#import "Command_Line";
