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
}
