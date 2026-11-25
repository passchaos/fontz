//! Synthetic catalog coverage matching; installed fallback fonts cannot pass.

const std = @import("std");
const types = @import("types.zig");
const Discovery = @import("pure_discovery.zig").Discovery;
const index = @import("metadata_index.zig");
const test_font = @import("metadata/test_font.zig");
const matching = @import("metadata/matching.zig");
const coverage_filter = @import("metadata/coverage_filter.zig");
const coverage_cache = @import("metadata/coverage_cache.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;

comptime {
    _ = @import("variation_matching_tests.zig");
    _ = @import("css_matching_tests.zig");
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = try allocator.dupe(u8, buffer[0..len]) };
    }

    fn deinit(self: *Fixture) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, options: test_font.TestFontOptions, codepoint: u21) !void {
        const bytes = try font(options, codepoint);
        defer allocator.free(bytes);
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }

    fn prewarm(self: *Fixture) !void {
        index.reset(io);
        const roots = [_][]const u8{self.root};
        try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
    }

    fn expectFace(self: *Fixture, resolution: types.Resolution, name: []const u8, postscript: []const u8, face_index: u32, instance: u16) !void {
        try std.testing.expectEqual(@as(usize, 1), resolution.candidates.len);
        const selected = resolution.candidates[0];
        try std.testing.expectEqual(types.Provider.metadata_index, selected.provider);
        const path = try std.fs.path.join(allocator, &.{ self.root, name });
        defer allocator.free(path);
        try std.testing.expectEqualStrings(path, selected.path);
        try std.testing.expectEqualStrings(postscript, selected.postscript_name.?);
        try std.testing.expectEqual(@as(?u32, face_index), selected.face_index);
        try std.testing.expectEqual(face_index, selected.provider_index);
        try std.testing.expectEqual(instance, selected.named_instance);
    }
};

fn font(options: test_font.TestFontOptions, codepoint: u21) ![]u8 {
    const table = try test_font.buildTestCmap(allocator, &.{.{ .start = codepoint, .end = codepoint }}, 12);
    defer allocator.free(table);
    var with_coverage = options;
    with_coverage.cmap = table;
    return test_font.buildTestFont(allocator, with_coverage);
}

test "coverage matching chooses covering sibling after best weight misses" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-best.ttf", .{ .family = "Fixture Alpha", .weight = 700, .postscript_name = "FixtureAlpha-Bold" }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .weight = 400, .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(allocator, .{ .family = "Fixture Alpha", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
    try std.testing.expectEqual(@as(u16, 400), resolution.candidates[0].weight);
    try std.testing.expectEqual(@as(u64, 2), discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().coverage_cache_hits);
}

test "coverage matching cold best face reads only its own cmap" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-best.ttf", .{ .family = "Fixture Cold", .postscript_name = "FixtureCold-Bold", .weight = 700 }, 'B');
    try fixture.write("b-sibling.ttf", .{ .family = "Fixture Cold", .postscript_name = "FixtureCold-Regular", .weight = 400 }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(allocator, .{ .family = "Fixture Cold", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "a-best.ttf", "FixtureCold-Bold", 0, 0);
    const stats = discovery.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.coverage_file_opens);
    try std.testing.expectEqual(@as(u64, 4), stats.coverage_read_calls);
    try std.testing.expectEqual(@as(u64, 128), stats.coverage_bytes_read);
}

test "coverage matching continues to next authored family in user roots" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-first.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'A');
    try fixture.write("b-next.ttf", .{ .family = "Fixture Beta", .postscript_name = "FixtureBeta-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(allocator, .{ .family = "Fixture Alpha, Fixture Beta", .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "b-next.ttf", "FixtureBeta-Regular", 0, 0);
}

test "coverage matching continues through generic mapping families" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-first.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'A');
    try fixture.write("b-next.ttf", .{ .family = "Fixture Beta", .postscript_name = "FixtureBeta-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    discovery.generic_mappings = &.{.{ .generic = .sans_serif, .families = &.{ "Fixture Alpha", "Fixture Beta" } }};
    var resolution = try discovery.resolve(allocator, .{ .family = "sans-serif", .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "b-next.ttf", "FixtureBeta-Regular", 0, 0);
}

test "coverage matching honors user generic CJK mapping before script hints" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-first.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'A');
    try fixture.write("b-next.ttf", .{ .family = "Fixture Beta", .postscript_name = "FixtureBeta-Regular" }, 0x4e2d);
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    discovery.generic_mappings = &.{.{ .generic = .sans_serif, .families = &.{ "Fixture Alpha", "Fixture Beta" } }};
    var resolution = try discovery.resolve(allocator, .{ .family = "sans-serif", .required_codepoint = 0x4e2d, .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "b-next.ttf", "FixtureBeta-Regular", 0, 0);
}

test "coverage matching keeps next authored CJK family after a generic miss" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-first.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'A');
    try fixture.write("b-next.ttf", .{ .family = "Fixture Beta", .postscript_name = "FixtureBeta-Regular" }, 0x4e2d);
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    discovery.generic_mappings = &.{.{ .generic = .sans_serif, .families = &.{"Fixture Alpha"} }};
    var resolution = try discovery.resolve(allocator, .{ .family = "sans-serif, Fixture Beta", .required_codepoint = 0x4e2d, .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "b-next.ttf", "FixtureBeta-Regular", 0, 0);
}

test "coverage matching preserves original TTC index and named instance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    const first = try font(.{ .family = "Fixture Collection", .weight = 700, .postscript_name = "FixtureCollection-Bold" }, 'A');
    defer allocator.free(first);
    const second = try font(.{
        .family = "Fixture Collection",
        .postscript_name = "FixtureCollection-Regular",
        .instances = &.{.{ .subfamily = "Light", .postscript_name = "FixtureCollection-Light", .weight = 300 }},
    }, 'B');
    defer allocator.free(second);
    const malformed = [_]u8{0} ** 12;
    const collection = try test_font.buildTestCollection(allocator, &.{ &malformed, first, &malformed, second });
    defer allocator.free(collection);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "fixture.ttc", .data = collection });
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(allocator, .{ .family = "Fixture Collection", .weight = 300, .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "fixture.ttc", "FixtureCollection-Light", 3, 1);
    var after_best_miss = try discovery.resolve(allocator, .{ .family = "Fixture Collection", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 });
    defer after_best_miss.deinit();
    try fixture.expectFace(after_best_miss, "fixture.ttc", "FixtureCollection-Regular", 3, 0);
}

test "coverage matching screens before CSS stretch style and weight ranking" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-missing.ttf", .{ .family = "Fixture CSS", .postscript_name = "FixtureCSS-Missing" }, 'A');
    try fixture.write("b-stretch.ttf", .{ .family = "Fixture CSS", .postscript_name = "FixtureCSS-Condensed", .width_class = 3 }, 'B');
    try fixture.write("c-style.ttf", .{ .family = "Fixture CSS", .postscript_name = "FixtureCSS-Italic", .italic = true }, 'B');
    try fixture.write("d-weight.ttf", .{ .family = "Fixture CSS", .postscript_name = "FixtureCSS-Bold", .weight = 700 }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(allocator, .{ .family = "Fixture CSS", .required_codepoint = 'B', .max_candidates = 1 });
    defer resolution.deinit();
    try fixture.expectFace(resolution, "d-weight.ttf", "FixtureCSS-Bold", 0, 0);
    try std.testing.expectEqual(@as(u16, 100), resolution.candidates[0].stretch);
    try std.testing.expectEqual(types.Style.normal, resolution.candidates[0].style);
    try std.testing.expectEqual(@as(u16, 700), resolution.candidates[0].weight);
}

test "coverage matching ranks opsz after coverage and retains static faces" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-near.ttf", .{ .family = "Fixture Optical", .postscript_name = "FixtureOptical-Near", .opsz = .{ .min = 8, .default = 12, .max = 18 } }, 'A');
    try fixture.write("b-static.ttf", .{ .family = "Fixture Optical", .postscript_name = "FixtureOptical-Static" }, 'B');
    try fixture.write("c-large.ttf", .{ .family = "Fixture Optical", .postscript_name = "FixtureOptical-Large", .opsz = .{ .min = 30, .default = 40, .max = 72 } }, 'B');
    try fixture.write("d-static-only.ttf", .{ .family = "Fixture Static", .postscript_name = "FixtureStatic-Regular" }, 'B');
    try fixture.write("e-static-second.ttf", .{ .family = "Fixture Static", .postscript_name = "FixtureStatic-Second" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    var unfiltered = try discovery.resolve(allocator, .{ .family = "Fixture Optical", .opsz = 12, .max_candidates = 1 });
    defer unfiltered.deinit();
    try fixture.expectFace(unfiltered, "a-near.ttf", "FixtureOptical-Near", 0, 0);
    var covered = try discovery.resolve(allocator, .{ .family = "Fixture Optical", .opsz = 12, .required_codepoint = 'B', .max_candidates = 1 });
    defer covered.deinit();
    try fixture.expectFace(covered, "c-large.ttf", "FixtureOptical-Large", 0, 0);
    var static_without_codepoint = try discovery.resolve(allocator, .{ .family = "Fixture Static", .opsz = 12, .max_candidates = 1 });
    defer static_without_codepoint.deinit();
    try fixture.expectFace(static_without_codepoint, "d-static-only.ttf", "FixtureStatic-Regular", 0, 0);
    var static = try discovery.resolve(allocator, .{ .family = "Fixture Static", .opsz = 12, .required_codepoint = 'B', .max_candidates = 1 });
    defer static.deinit();
    try fixture.expectFace(static, "d-static-only.ttf", "FixtureStatic-Regular", 0, 0);
}

test "coverage matching keeps exact PostScript and reports no catalog match" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-missing.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    for ([_][]const u8{ "FixtureAlpha-Bold", "FixtureNotInstalled" }) |postscript| {
        var missing = try discovery.resolve(allocator, .{ .family = "Fixture Alpha", .postscript_name = postscript, .required_codepoint = 'B', .max_candidates = 1 });
        defer missing.deinit();
        try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    }
    var exact = try discovery.resolve(allocator, .{ .family = "Fixture Alpha", .weight = 700, .postscript_name = "FixtureAlpha-Regular", .required_codepoint = 'B', .max_candidates = 1 });
    defer exact.deinit();
    try fixture.expectFace(exact, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
    var lease = index.acquireRead(io, .{ .roots = &roots, .enable_cache = false });
    defer lease.deinit();
    const filter = coverage_filter.Filter{ .cache = &discovery.coverage, .io = io, .codepoint = 'C', .epoch = lease.epoch };
    try std.testing.expect((try lease.findFaceFiltered(allocator, .{ .family = "Fixture Alpha", .required_codepoint = 'C' }, .{}, &filter)) == null);
    try std.testing.expect((try lease.findFaceFiltered(allocator, .{ .family = "Fixture Missing", .required_codepoint = 'B' }, .{}, &filter)) == null);
}

test "coverage matching preserves no-codepoint choice and allocation-free exact hits" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-best.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var discovery = try Discovery.initWithRoots(failing.allocator(), &roots);
    defer discovery.deinit();
    var unfiltered = try discovery.resolve(allocator, .{ .family = "Fixture Alpha", .weight = 700, .max_candidates = 1 });
    defer unfiltered.deinit();
    try fixture.expectFace(unfiltered, "a-best.ttf", "FixtureAlpha-Bold", 0, 0);
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().coverage_file_opens);
    const query = types.Query{ .family = "Fixture Alpha", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 };
    var covered = try discovery.resolve(allocator, query);
    defer covered.deinit();
    try fixture.expectFace(covered, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
    const before = discovery.stats();
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    var output_fails = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var hit = try discovery.resolve(output_fails.allocator(), query);
    defer hit.deinit();
    try std.testing.expect(covered.shared == hit.shared);
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), output_fails.allocations);
    try std.testing.expectEqual(before.coverage_file_opens, discovery.stats().coverage_file_opens);
    try std.testing.expectEqual(before.coverage_read_calls, discovery.stats().coverage_read_calls);
    try std.testing.expectEqual(before.cache_hits + 1, discovery.stats().cache_hits);
}

test "coverage matching refresh changes selection while retained results stay owned" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-best.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    defer discovery.deinit();
    const query = types.Query{ .family = "Fixture Alpha", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 };
    var held = try discovery.resolve(allocator, query);
    defer held.deinit();
    try fixture.expectFace(held, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
    const old_epoch = discovery.coverage.generation.?;
    const before = discovery.stats();
    try fixture.write("a-best.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'B');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'A');
    try std.testing.expect(try discovery.refresh());
    try std.testing.expect(index.generation() != old_epoch);
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().cache_entries);
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().coverage_cache_entries);
    // Restore this embedder fixture's explicit roots after host config reload.
    discovery.roots = &roots;
    var next = try discovery.resolve(allocator, query);
    defer next.deinit();
    try fixture.expectFace(next, "a-best.ttf", "FixtureAlpha-Bold", 0, 0);
    try std.testing.expectEqual(index.generation(), discovery.coverage.generation.?);
    try std.testing.expectEqual(before.cache_misses + 1, discovery.stats().cache_misses);
    try std.testing.expect(held.shared != next.shared);
    try fixture.expectFace(held, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
}

const ResetFilter = struct {
    base: coverage_filter.Filter,
    reset_done: bool = false,

    pub fn accept(self: *ResetFilter, face: *const index.Face) !bool {
        if (!self.reset_done) {
            index.reset(io);
            self.reset_done = true;
        }
        return self.base.accept(face);
    }
};

test "coverage matching holds lease and proof epoch through reset during screening" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-missing.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    const options = index.Options{ .roots = &roots, .enable_cache = false };
    var lease = index.acquireRead(io, options);
    defer lease.deinit();
    var coverage = coverage_cache.Cache.init(allocator);
    defer coverage.deinit();
    var filter = ResetFilter{ .base = .{ .cache = &coverage, .io = io, .codepoint = 'B', .epoch = lease.epoch } };
    const selected = (try lease.findFaceFiltered(allocator, .{ .family = "Fixture Alpha", .weight = 700, .required_codepoint = 'B' }, options, &filter)).?;
    try std.testing.expectEqualStrings("FixtureAlpha-Regular", selected.postscript_name);
    try std.testing.expectEqual(@as(u16, 400), selected.weight);
    try std.testing.expect(index.generation() != lease.epoch);
    try std.testing.expectEqual(lease.epoch, coverage.generation.?);
    var newer = index.acquireRead(io, options);
    defer newer.deinit();
    const current = coverage_filter.Filter{ .cache = &coverage, .io = io, .codepoint = 'B', .epoch = newer.epoch };
    try std.testing.expect((try newer.findFaceFiltered(allocator, .{ .family = "Fixture Alpha", .required_codepoint = 'B' }, options, &current)) != null);
    try std.testing.expectEqual(newer.epoch, coverage.generation.?);
}

const ScreeningFilter = struct {
    calls: usize = 0,
    fail_at: ?usize = null,

    pub fn accept(self: *ScreeningFilter, face: *const index.Face) !bool {
        const call = self.calls;
        self.calls += 1;
        if (self.fail_at == call) return error.OutOfMemory;
        return face.weight == 400;
    }
};

test "coverage matching OOM frees large eligibility lists on filter errors" {
    var faces: [65]index.Face = undefined;
    var indices: [65]u32 = undefined;
    for (&faces, &indices, 0..) |*face, *face_index, number| {
        face.* = .{ .path = "/fixture.ttf", .family = "Fixture Alpha", .subfamily = "Regular", .weight = if (number == 64) 400 else 700 };
        face_index.* = @intCast(number);
    }
    var fail_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var filter: ScreeningFilter = .{};
    try std.testing.expectError(error.OutOfMemory, matching.selectFiltered(index.Face, fail_alloc.allocator(), &faces, &indices, .{ .family = "Fixture Alpha", .weight = 700 }, &filter));
    // Only the best face is checked before allocating the fallback index list.
    try std.testing.expectEqual(@as(usize, 1), filter.calls);
    var tracked = std.testing.FailingAllocator.init(allocator, .{});
    filter = .{ .fail_at = 2 };
    try std.testing.expectError(error.OutOfMemory, matching.selectFiltered(index.Face, tracked.allocator(), &faces, &indices, .{ .family = "Fixture Alpha", .weight = 700 }, &filter));
    try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    filter = .{};
    const selected = (try matching.selectFiltered(index.Face, tracked.allocator(), &faces, &indices, .{ .family = "Fixture Alpha", .weight = 700 }, &filter)).?;
    try std.testing.expect(selected == &faces[64]);
    try std.testing.expectEqual(faces.len, filter.calls);
    try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

fn resolveWithAllocationFailures(out_allocator: std.mem.Allocator, roots: []const []const u8, family: []const u8) !void {
    var discovery = try Discovery.initWithRoots(out_allocator, roots);
    defer discovery.deinit();
    const query = types.Query{ .family = family, .weight = 700, .required_codepoint = 'B', .max_candidates = 1 };
    var resolution = try discovery.resolve(out_allocator, query);
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.candidates.len);
    try std.testing.expectEqual(types.Provider.metadata_index, resolution.candidates[0].provider);
    try std.testing.expectEqualStrings("FixtureAlpha-Regular", resolution.candidates[0].postscript_name.?);
    var hit = try discovery.resolve(out_allocator, query);
    defer hit.deinit();
    try std.testing.expect(resolution.shared == hit.shared);
}

test "coverage matching OOM unwinds candidate copies and long-family scans" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    var long_name: [600]u8 = undefined;
    @memset(&long_name, 'x');
    try fixture.write("a-missing.ttf", .{ .family = &long_name, .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = &long_name, .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    try std.testing.checkAllAllocationFailures(allocator, resolveWithAllocationFailures, .{ @as([]const []const u8, &roots), @as([]const u8, &long_name) });
}

test "coverage matching OOM table failures remain retryable instead of caching a negative" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    defer index.reset(io);
    try fixture.write("a-missing.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Bold", .weight = 700 }, 'A');
    try fixture.write("b-covered.ttf", .{ .family = "Fixture Alpha", .postscript_name = "FixtureAlpha-Regular" }, 'B');
    try fixture.prewarm();
    const roots = [_][]const u8{fixture.root};
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var discovery = try Discovery.initWithRoots(failing.allocator(), &roots);
    defer discovery.deinit();
    failing.fail_index = failing.alloc_index;
    const query = types.Query{ .family = "Fixture Alpha", .weight = 700, .required_codepoint = 'B', .max_candidates = 1 };
    try std.testing.expectError(error.OutOfMemory, discovery.resolve(allocator, query));
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().cache_entries);
    try std.testing.expectEqual(@as(usize, 0), discovery.stats().coverage_cache_entries);
    failing.fail_index = std.math.maxInt(usize);
    var retry = try discovery.resolve(allocator, query);
    defer retry.deinit();
    try fixture.expectFace(retry, "b-covered.ttf", "FixtureAlpha-Regular", 0, 0);
    try std.testing.expectEqual(@as(u64, 2), discovery.stats().cache_misses);
}
