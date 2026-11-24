//! Exercise the root's actual fallback builder through a private function
//! passed by its small in-module test adapter.
const std = @import("std");
const pure = @import("pure_discovery.zig");
const root = @import("root.zig");
const index = @import("metadata_index.zig");
const types = @import("types.zig");
const variation = @import("metadata/test_variation.zig");
const a = std.testing.allocator;
const io = std.testing.io;

pub fn exerciseBuilder(builder: anytype) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer index.reset(io);
    const nominal = try variation.buildFont(a, .{ .family = "Fallback Nominal" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{});
    defer a.free(nominal);
    const variant = try variation.buildFont(a, .{ .family = "Fallback UVS" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{
        .{ .selector = 0xfe0e, .defaults = &.{.{ .start = 0x2764 }} },
        .{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} },
    });
    defer a.free(variant);
    try tmp.dir.writeFile(io, .{ .sub_path = "nominal.ttf", .data = nominal });
    try tmp.dir.writeFile(io, .{ .sub_path = "variant.ttf", .data = variant });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const nominal_path = try std.fs.path.join(a, &.{ buffer[0..len], "nominal.ttf" });
    defer a.free(nominal_path);
    const variant_path = try std.fs.path.join(a, &.{ buffer[0..len], "variant.ttf" });
    defer a.free(variant_path);
    var discovery = try pure.Discovery.initWithRoots(a, &.{buffer[0..len]});
    defer discovery.deinit();
    const paths = [_]root.fallback_paths.CandidatePath{ .{ .path = nominal_path }, .{ .path = variant_path } };
    const cases = [_]struct { base: u21, selector: ?u21, count: usize }{
        .{ .base = 0x4e2d, .selector = 0xe0100, .count = 1 },
        .{ .base = 0x2764, .selector = 0xfe0e, .count = 1 },
        .{ .base = 0x2764, .selector = 0xfe0f, .count = 0 },
        .{ .base = 0x2764, .selector = 0xe0100, .count = 0 },
        .{ .base = 0x2764, .selector = null, .count = 2 },
        .{ .base = 0x4e2d, .selector = null, .count = 0 },
    };
    for (cases) |case| {
        var result = try builder(&discovery, a, &paths, false, .{ .family = "Fallback UVS", .required_codepoint = case.base, .required_variation_selector = case.selector });
        defer result.deinit();
        try std.testing.expectEqual(case.count, result.candidates.len);
        if (case.count == 1) {
            try std.testing.expectEqualStrings(variant_path, result.candidates[0].path);
            try std.testing.expectEqual(types.Provider.fallback_paths, result.candidates[0].provider);
        }
    }
    try std.testing.expectEqual(@as(u64, 2), discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(@as(u64, 10), discovery.stats().coverage_read_calls);
    const before = discovery.stats();
    for ([_]types.Query{
        .{ .family = "Fallback UVS", .required_variation_selector = 0xfe0f },
        .{ .family = "Fallback UVS", .required_codepoint = 0x2764, .required_variation_selector = 0xfe10 },
        .{ .family = "Fallback UVS", .required_codepoint = 0xd800, .required_variation_selector = 0xfe0f },
    }) |query| {
        var invalid = try builder(&discovery, a, &paths, false, query);
        defer invalid.deinit();
        try std.testing.expectEqual(@as(usize, 0), invalid.candidates.len);
    }
    try std.testing.expectEqual(before.coverage_file_opens, discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(before.coverage_read_calls, discovery.stats().coverage_read_calls);
    // Read OOM must propagate out of the actual root fallback path and retry.
    discovery.coverage.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    discovery.coverage = @import("metadata/coverage_cache.zig").Cache.init(failing.allocator());
    const sequence = types.Query{ .family = "Fallback UVS", .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100 };
    try std.testing.expectError(error.OutOfMemory, builder(&discovery, a, &paths, false, sequence));
    failing.fail_index = std.math.maxInt(usize);
    var retried = try builder(&discovery, a, &paths, false, sequence);
    defer retried.deinit();
    try std.testing.expectEqual(@as(usize, 1), retried.candidates.len);
}

pub fn exerciseRoleBuilder(builder: anytype) !void {
    var discovery = try pure.Discovery.initWithRoots(a, &.{"/missing/uvs-fonts"});
    defer discovery.deinit();
    for ([_]types.Role{ .ui, .cjk, .emoji, .monospace, .symbol }) |role| {
        var result = try builder(&discovery, a, role, .{ .family = "", .required_variation_selector = 0xfe0f });
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
    }
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().coverage_file_opens);
}

test "variation sequence public root discovery empty family retains selector and nondefault base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer index.reset(io);
    const bytes = try variation.buildFont(a, .{ .family = "UVS Root", .postscript_name = "UVSRoot-Regular" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "font.ttf", .data = bytes });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const roots = [_][]const u8{buffer[0..len]};
    index.reset(io);
    try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
    var discovery = root.Discovery{ .allocator = a, .platform = try pure.Discovery.initWithRoots(a, &roots) };
    defer discovery.deinit();
    discovery.platform.generic_mappings = &.{.{ .generic = .sans_serif, .families = &.{"UVS Root"} }};
    var result = try discovery.resolveQuery(a, .{ .family = "", .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
    try std.testing.expectEqualStrings("UVSRoot-Regular", result.candidates[0].postscript_name.?);
    try std.testing.expect(try discovery.coversVariationSequence(result.candidates[0].path, 0, 0x4e2d, 0xe0100));
    const before = discovery.stats();
    for ([_]types.Query{
        .{ .family = "", .required_variation_selector = 0xfe0f },
        .{ .family = "", .required_codepoint = 0x2764, .required_variation_selector = 0xfe10 },
        .{ .family = "", .required_codepoint = 0xdead, .required_variation_selector = 0xfe0f },
    }) |query| {
        var invalid = try discovery.resolveQuery(a, query);
        defer invalid.deinit();
        try std.testing.expectEqual(@as(usize, 0), invalid.candidates.len);
    }
    try std.testing.expectEqual(before.coverage_file_opens, discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(before.cache_misses, discovery.stats().cache_misses);
}
