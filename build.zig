const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fontz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run fontz tests");
    test_step.dependOn(&run_tests.step);

    const concurrency_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/concurrency_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{ "catalog concurrency", "catalog OOM" },
    });
    const run_concurrency_tests = b.addRunArtifact(concurrency_tests);
    const concurrency_step = b.step("test-concurrency", "Run catalog lifecycle, cache epoch, and OOM regressions");
    concurrency_step.dependOn(&run_concurrency_tests.step);
    test_step.dependOn(&run_concurrency_tests.step);

    const coverage_matching_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/coverage_matching_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"coverage matching"},
    });
    const run_coverage_matching_tests = b.addRunArtifact(coverage_matching_tests);
    const coverage_matching_step = b.step("test-coverage-matching", "Run coverage-aware catalog matching regressions");
    coverage_matching_step.dependOn(&run_coverage_matching_tests.step);
    test_step.dependOn(&run_coverage_matching_tests.step);

    const prepared_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prepared_cmap_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"prepared cmap"},
    });
    const run_prepared_tests = b.addRunArtifact(prepared_tests);
    const prepared_step = b.step("test-prepared-cmap", "Run retained scalar cmap lookup and lifecycle regressions");
    prepared_step.dependOn(&run_prepared_tests.step);
    test_step.dependOn(&run_prepared_tests.step);

    const unicode_cmap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_cmap_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"unicode cmap"},
    });
    const run_unicode_cmap_tests = b.addRunArtifact(unicode_cmap_tests);
    const unicode_cmap_step = b.step("test-unicode-cmap", "Run Unicode format2/8/10 grammar, eligibility, and discovery regressions");
    unicode_cmap_step.dependOn(&run_unicode_cmap_tests.step);
    test_step.dependOn(&run_unicode_cmap_tests.step);

    const cmap_bench = b.addExecutable(.{
        .name = "cmap-lookup-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmap_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_cmap_bench = b.addInstallArtifact(cmap_bench, .{});
    const cmap_bench_step = b.step("bench-cmap", "Build the existing coverage-cache scalar lookup benchmark");
    cmap_bench_step.dependOn(&install_cmap_bench.step);

    const variation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/variation_sequence_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"variation sequence"},
    });
    const run_variation_tests = b.addRunArtifact(variation_tests);
    const variation_step = b.step("test-variation-sequences", "Run cmap14, coverage cache, and fallback sequence regressions");
    variation_step.dependOn(&run_variation_tests.step);
    test_step.dependOn(&run_variation_tests.step);

    const variation_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/variation_api_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fontz", .module = mod }},
        }),
        .filters = &.{"variation sequence published API"},
    });
    const run_variation_api_tests = b.addRunArtifact(variation_api_tests);
    const variation_api_step = b.step("test-variation-api", "Run published variation sequence API consumer regression");
    variation_api_step.dependOn(&run_variation_api_tests.step);
    test_step.dependOn(&run_variation_api_tests.step);

    if (target.result.os.tag == .macos) {
        const coretext_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/coretext_matching_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fontz", .module = mod }},
            }),
        });
        coretext_tests.root_module.linkFramework("CoreFoundation", .{});
        coretext_tests.root_module.linkFramework("CoreText", .{});
        const run_coretext_tests = b.addRunArtifact(coretext_tests);
        test_step.dependOn(&run_coretext_tests.step);
        const coretext_step = b.step(
            "test-macos-coretext",
            "Run the macOS Core Text font-matching differential",
        );
        coretext_step.dependOn(&run_coretext_tests.step);
    }

    const check_step = b.step("check", "Compile platform providers for Windows and macOS");

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const windows_mod = b.addModule("fontz-windows-check", .{
        .root_source_file = b.path("src/root.zig"),
        .target = windows_target,
        .optimize = optimize,
    });
    const windows_obj = b.addObject(.{
        .name = "fontz-windows-check",
        .root_module = windows_mod,
    });
    check_step.dependOn(&windows_obj.step);

    const macos_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const macos_mod = b.addModule("fontz-macos-check", .{
        .root_source_file = b.path("src/root.zig"),
        .target = macos_target,
        .optimize = optimize,
    });
    const macos_obj = b.addObject(.{
        .name = "fontz-macos-check",
        .root_module = macos_mod,
    });
    check_step.dependOn(&macos_obj.step);

    // Compile calls to the new published API on the affected native providers;
    // declaration-only objects can leave function bodies lazily unanalyzed.
    for ([_]std.Build.ResolvedTarget{
        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux }),
        macos_target,
    }) |check_target| {
        const check_fontz = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = check_target,
            .optimize = optimize,
        });
        const check_api = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/variation_api_test.zig"),
                .target = check_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fontz", .module = check_fontz }},
            }),
            .filters = &.{"variation sequence published API"},
        });
        check_step.dependOn(&check_api.step);
    }
}
