EXTRA_CHECKS :: true;

#if EXTRA_CHECKS {
    Debug :: #import "Debug";

    example_debug_harness :: () #expand {
        #if EXTRA_CHECKS {
            Debug.init();
            `defer {
                has_leaks := false;
                has_leaks |= show_jai_mem_leaks();
                has_leaks |= gpu_log_memory_leaks();
                if has_leaks {
                    exit(1);
                }
            }
            // TODO: exit with code 1 if there are any leaks.
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
}

#import "Basic"()(
    MEMORY_DEBUGGER=EXTRA_CHECKS,
    VISUALIZE_MEMORY_DEBUGGER=false,
    TEMP_ALLOCATOR_POISON_FREED_MEMORY=true,
);
