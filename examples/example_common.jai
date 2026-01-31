EXTRA_CHECKS :: true;

#if EXTRA_CHECKS {
    Debug :: #import "Debug";

    gpu_example_harness :: () #expand {
        Debug.init();
        `defer exit_with_error_on_memory_leak();
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


#import "Basic"()(
    MEMORY_DEBUGGER=EXTRA_CHECKS,
    VISUALIZE_MEMORY_DEBUGGER=false,
    TEMP_ALLOCATOR_POISON_FREED_MEMORY=true,
);
