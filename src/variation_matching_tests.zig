//! Real named SFNT/TTC discovery tests for complete variation sequences.
const std = @import("std");
const types = @import("types.zig");
const Discovery = @import("pure_discovery.zig").Discovery;
const index = @import("metadata_index.zig");
const font = @import("metadata/test_font.zig");
const variation = @import("metadata/test_variation.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = try a.dupe(u8, buffer[0..len]) };
    }

    fn deinit(self: *Fixture) void {
        index.reset(io);
        a.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, options: font.TestFontOptions, nominal: []const font.TestCoverageGroup, selectors: []const variation.Selector) !void {
        const bytes = try buildFont(options, nominal, selectors);
        defer a.free(bytes);
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }

    fn discovery(self: *Fixture) !Discovery {
        index.reset(io);
        const roots = [_][]const u8{self.root};
        try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
        return Discovery.initWithRoots(a, &roots);
    }
};

fn buildFont(options: font.TestFontOptions, nominal: []const font.TestCoverageGroup, selectors: []const variation.Selector) ![]u8 {
    const table = try variation.buildCmap(a, nominal, selectors);
    defer a.free(table);
    var opts = options;
    opts.cmap = table;
    opts.num_glyphs = 128;
    return font.buildTestFont(a, opts);
}

fn expectPostscript(resolution: types.Resolution, name: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), resolution.candidates.len);
    try std.testing.expectEqualStrings(name, resolution.candidates[0].postscript_name.?);
}

test "coverage matching variation sequence skips nominal best for nondefault only sibling" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a-nominal.ttf", .{ .family = "UVS Fixture", .postscript_name = "UVS-Nominal", .weight = 700 }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    try fixture.write("b-variation.ttf", .{ .family = "UVS Fixture", .postscript_name = "UVS-Only" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    var result = try discovery.resolve(a, .{ .family = "UVS Fixture", .weight = 700, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 });
    defer result.deinit();
    try expectPostscript(result, "UVS-Only");
}

test "coverage matching variation sequence default requires nominal and unsupported resolves empty" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a-default.ttf", .{ .family = "UVS Default", .postscript_name = "UVS-Default" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    var query = types.Query{ .family = "UVS Default", .postscript_name = "UVS-Default", .required_codepoint = 0x2764, .required_variation_selector = 0xfe0f, .max_candidates = 1 };
    var covered = try discovery.resolve(a, query);
    defer covered.deinit();
    try expectPostscript(covered, "UVS-Default");
    try std.testing.expectEqual(@as(u64, 1), discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(@as(u64, 5), discovery.stats().coverage_read_calls);
    const cold_bytes = discovery.stats().coverage_bytes_read;
    query.required_variation_selector = 0xfe0e;
    var missing = try discovery.resolve(a, query);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    try std.testing.expectEqual(cold_bytes, discovery.stats().coverage_bytes_read);
}

test "coverage matching variation sequence unfiltered metadata query fails closed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("font.ttf", .{ .family = "UVS Metadata", .postscript_name = "UVSMetadata-Regular" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    const options = index.Options{ .roots = &.{fixture.root}, .enable_cache = false };
    const query = types.Query{ .family = "UVS Metadata", .required_codepoint = 0x2764, .required_variation_selector = 0xfe0f };
    try std.testing.expect(index.findFace(io, query, options) == null);
    var lease = index.acquireRead(io, options);
    defer lease.deinit();
    try std.testing.expect(lease.findFace(query, options) == null);
    var scalar = query;
    scalar.required_variation_selector = null;
    try std.testing.expect(lease.findFace(scalar, options) != null);
    index.reset(io);
    const epoch = index.generation();
    try std.testing.expect(index.findFace(io, .{ .family = "UVS Metadata", .required_variation_selector = 0xfe0f }, options) == null);
    try std.testing.expectEqual(epoch, index.generation());
}

test "coverage matching variation sequence TTC preserves nondefault face and named instance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const nominal = try buildFont(.{ .family = "UVS TTC", .postscript_name = "UVSTTC-Nominal", .weight = 700 }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    defer a.free(nominal);
    const variant = try buildFont(.{ .family = "UVS TTC", .postscript_name = "UVSTTC-Regular", .instances = &.{.{ .subfamily = "Light", .postscript_name = "UVSTTC-Light", .weight = 300 }} }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    defer a.free(variant);
    const bad = [_]u8{0} ** 12;
    const collection = try font.buildTestCollection(a, &.{ &bad, nominal, &bad, variant });
    defer a.free(collection);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "uvs.ttc", .data = collection });
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    var result = try discovery.resolve(a, .{ .family = "UVS TTC", .weight = 300, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 });
    defer result.deinit();
    try expectPostscript(result, "UVSTTC-Light");
    try std.testing.expectEqual(@as(?u32, 3), result.candidates[0].face_index);
    try std.testing.expectEqual(@as(u16, 1), result.candidates[0].named_instance);
}

test "coverage matching variation sequence rejects default without nominal and invalid glyph bounds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const defaults = [_]variation.Selector{.{ .selector = 0xe0100, .defaults = &.{.{ .start = 0x4e2d }} }};
    try fixture.write("a-no-base.ttf", .{ .family = "UVS Bounds", .postscript_name = "UVS-NoBase", .weight = 900 }, &.{}, &defaults);
    try fixture.write("b-default-bounds.ttf", .{ .family = "UVS Bounds", .postscript_name = "UVS-DefaultBounds", .weight = 800 }, &.{.{ .start = 0x4e2d, .end = 0x4e2d, .glyph = 128 }}, &defaults);
    try fixture.write("c-variant-bounds.ttf", .{ .family = "UVS Bounds", .postscript_name = "UVS-VariantBounds", .weight = 700 }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d, .glyph = 128 }} }});
    try fixture.write("d-valid.ttf", .{ .family = "UVS Bounds", .postscript_name = "UVS-Valid" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    var result = try discovery.resolve(a, .{ .family = "UVS Bounds", .weight = 900, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 });
    defer result.deinit();
    try expectPostscript(result, "UVS-Valid");
    try std.testing.expectEqual(@as(u64, 4), discovery.stats().coverage_file_opens);
}

test "coverage matching variation sequence invalid query fails closed without catalog or file IO" {
    index.reset(io);
    defer index.reset(io);
    var discovery = try Discovery.initWithRoots(a, &.{"/missing/uvs-fonts"});
    defer discovery.deinit();
    const epoch = index.generation();
    for ([_]types.Query{
        .{ .family = "UVS Missing Base", .required_variation_selector = 0xfe0f },
        .{ .family = "UVS Invalid", .required_codepoint = 0x2764, .required_variation_selector = 0xfe10 },
        .{ .family = "UVS Invalid", .required_codepoint = 0x2764, .required_variation_selector = 0xdead },
        .{ .family = "UVS Invalid", .required_codepoint = 0xd800, .required_variation_selector = 0xfe0f },
        .{ .family = "UVS Invalid", .required_codepoint = 0x110000, .required_variation_selector = 0xe0100 },
        .{ .family = "UVS Invalid Scalar", .required_codepoint = 0xdfff },
    }) |query| {
        var resolved = try discovery.resolve(a, query);
        defer resolved.deinit();
        var uncached = try discovery.resolveUncached(a, query);
        defer uncached.deinit();
        try std.testing.expectEqual(@as(usize, 0), resolved.candidates.len);
        try std.testing.expectEqual(@as(usize, 0), uncached.candidates.len);
    }
    try std.testing.expectEqual(epoch, index.generation());
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().cache_misses);
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().cache_entries);
}

test "coverage matching variation sequence query cache isolates positive negative base selector and scalar" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a-text.ttf", .{ .family = "UVS Cached", .postscript_name = "UVS-Text", .weight = 700 }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0e, .defaults = &.{.{ .start = 0x2764 }} }});
    try fixture.write("b-emoji.ttf", .{ .family = "UVS Cached", .postscript_name = "UVS-Emoji" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    try fixture.write("c-ivs.ttf", .{ .family = "UVS Cached", .postscript_name = "UVS-IVS" }, &.{}, &.{
        .{ .selector = 0xfe00, .mappings = &.{.{ .base = 0x4e2d }} },
        .{ .selector = 0xfe0d, .mappings = &.{.{ .base = 0x4e00 }} },
        .{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} },
    });
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    const cases = [_]struct { base: u21, selector: ?u21, face: ?[]const u8 }{
        .{ .base = 0x2764, .selector = null, .face = "UVS-Text" },
        .{ .base = 0x2764, .selector = 0xfe0f, .face = "UVS-Emoji" },
        .{ .base = 0x2764, .selector = 0xfe0e, .face = "UVS-Text" },
        .{ .base = 0x2764, .selector = 0xe0100, .face = null },
        .{ .base = 0x4e2d, .selector = 0xe0100, .face = "UVS-IVS" },
        .{ .base = 0x4e2d, .selector = 0xfe0d, .face = null },
        .{ .base = 0x4e2d, .selector = 0xfe00, .face = "UVS-IVS" },
        .{ .base = 0x4e00, .selector = 0xfe0d, .face = "UVS-IVS" },
        .{ .base = 0x4e2d, .selector = null, .face = null },
    };
    for (0..2) |round| {
        const before = discovery.stats();
        for (cases) |case| {
            var result = try discovery.resolve(a, .{ .family = "UVS Cached", .weight = 700, .required_codepoint = case.base, .required_variation_selector = case.selector, .max_candidates = 1 });
            defer result.deinit();
            if (case.face) |name| try expectPostscript(result, name) else try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
        }
        if (round == 0) {
            try std.testing.expectEqual(@as(u64, 9), discovery.stats().cache_misses);
            // Rejected descriptors can also screen deterministic host fallback
            // paths; all fixture faces must have been read by this point.
            try std.testing.expect(discovery.stats().coverage_file_opens >= 3);
            // Repeating an exact descriptor must retain positive and negative
            // resolutions even after their coverage tables have been dropped.
            discovery.coverage.clear();
        } else {
            try std.testing.expectEqual(before.coverage_file_opens, discovery.stats().coverage_file_opens);
            try std.testing.expectEqual(before.cache_hits + cases.len, discovery.stats().cache_hits);
        }
    }
}

test "coverage matching variation sequence preserves authored generic family language and CSS descriptors" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a-nominal.ttf", .{ .family = "UVS First", .postscript_name = "UVS-Nominal" }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    const mappings = [_]variation.Selector{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }};
    try fixture.write("b-condensed.ttf", .{ .family = "UVS Next", .postscript_name = "UVS-Condensed", .width_class = 3 }, &.{}, &mappings);
    try fixture.write("c-normal.ttf", .{ .family = "UVS Next", .postscript_name = "UVS-Normal" }, &.{}, &mappings);
    try fixture.write("d-near.ttf", .{ .family = "UVS Next", .postscript_name = "UVS-Near", .weight = 700, .italic = true, .opsz = .{ .min = 8, .default = 12, .max = 18 }, .localized_family = .{ .name = "UVS Local", .language = 0x0411 } }, &.{}, &mappings);
    try fixture.write("e-far.ttf", .{ .family = "UVS Next", .postscript_name = "UVS-Far", .weight = 700, .italic = true, .opsz = .{ .min = 30, .default = 40, .max = 72 }, .localized_family = .{ .name = "UVS Local", .language = 0x0411 } }, &.{}, &mappings);
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    discovery.generic_mappings = &.{.{ .generic = .sans_serif, .families = &.{ "UVS First", "UVS Next" } }};
    var query = types.Query{ .family = "UVS First, UVS Next", .weight = 700, .style = .italic, .language = "ja", .opsz = 12, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 };
    for ([_][]const u8{ "UVS First, UVS Next", "sans-serif", "UVS Local" }) |family_name| {
        query.family = family_name;
        var result = try discovery.resolve(a, query);
        defer result.deinit();
        try expectPostscript(result, "UVS-Near");
        try std.testing.expectEqual(@as(u16, 700), result.candidates[0].weight);
        try std.testing.expectEqual(@as(u16, 100), result.candidates[0].stretch);
        try std.testing.expectEqual(types.Style.italic, result.candidates[0].style);
    }
    query.family = "UVS Next";
    query.stretch = 75;
    query.style = .normal;
    query.weight = 400;
    var condensed = try discovery.resolve(a, query);
    defer condensed.deinit();
    try expectPostscript(condensed, "UVS-Condensed");
    query.stretch = 100;
    query.postscript_name = "UVS-Condensed";
    var exact = try discovery.resolve(a, query);
    defer exact.deinit();
    try expectPostscript(exact, "UVS-Condensed");
    query.postscript_name = "UVS-Nominal";
    var missing = try discovery.resolve(a, query);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
}

fn resolveUVSWithFailures(out: std.mem.Allocator, roots: []const []const u8) !void {
    var discovery = try Discovery.initWithRoots(out, roots);
    defer discovery.deinit();
    const query = types.Query{ .family = "UVS OOM", .weight = 700, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 };
    var result = try discovery.resolve(out, query);
    defer result.deinit();
    try expectPostscript(result, "UVS-Only");
    var hit = try discovery.resolve(out, query);
    defer hit.deinit();
    try std.testing.expect(result.shared == hit.shared);
}

test "coverage matching variation sequence OOM unwinds discovery and retries without negative caching" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("a-nominal.ttf", .{ .family = "UVS OOM", .postscript_name = "UVS-Nominal", .weight = 700 }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    try fixture.write("b-variant.ttf", .{ .family = "UVS OOM", .postscript_name = "UVS-Only" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    var prewarmed = try fixture.discovery();
    prewarmed.deinit();
    const roots = [_][]const u8{fixture.root};
    try std.testing.checkAllAllocationFailures(a, resolveUVSWithFailures, .{@as([]const []const u8, &roots)});
    var failing = std.testing.FailingAllocator.init(a, .{});
    var discovery = try Discovery.initWithRoots(failing.allocator(), &roots);
    defer discovery.deinit();
    failing.fail_index = failing.alloc_index;
    const query = types.Query{ .family = "UVS OOM", .weight = 700, .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 };
    try std.testing.expectError(error.OutOfMemory, discovery.resolve(a, query));
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().cache_entries);
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().coverage_cache_entries);
    failing.fail_index = std.math.maxInt(usize);
    var result = try discovery.resolve(a, query);
    defer result.deinit();
    try expectPostscript(result, "UVS-Only");
    const before = discovery.stats();
    failing.fail_index = failing.alloc_index;
    var out_failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var hit = try discovery.resolve(out_failure.allocator(), query);
    defer hit.deinit();
    try std.testing.expect(result.shared == hit.shared);
    try std.testing.expectEqual(before.coverage_file_opens, discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(@as(usize, 0), out_failure.allocations);
}

test "coverage matching variation sequence refresh invalidates coverage and negative query results" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("font.ttf", .{ .family = "UVS Refresh", .postscript_name = "UVS-Nominal" }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    var discovery = try fixture.discovery();
    defer discovery.deinit();
    const query = types.Query{ .family = "UVS Refresh", .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100, .max_candidates = 1 };
    var missing = try discovery.resolve(a, query);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    const before = discovery.stats();
    try fixture.write("font.ttf", .{ .family = "UVS Refresh", .postscript_name = "UVS-Added" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    try std.testing.expect(try discovery.refresh());
    const roots = [_][]const u8{fixture.root};
    discovery.roots = &roots;
    var found = try discovery.resolve(a, query);
    defer found.deinit();
    try expectPostscript(found, "UVS-Added");
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    try std.testing.expectEqual(before.coverage_file_opens + 1, discovery.stats().coverage_file_opens);
    // External index reset also invalidates a cached positive at the same owner generation.
    try fixture.write("font.ttf", .{ .family = "UVS Refresh", .postscript_name = "UVS-Nominal" }, &.{.{ .start = 0x4e2d, .end = 0x4e2d }}, &.{});
    index.reset(io);
    var gone = try discovery.resolve(a, query);
    defer gone.deinit();
    try std.testing.expectEqual(@as(usize, 0), gone.candidates.len);
    try expectPostscript(found, "UVS-Added");
}
