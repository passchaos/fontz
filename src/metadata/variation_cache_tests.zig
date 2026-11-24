const std = @import("std");
const cmap = @import("cmap.zig");
const coverage = @import("coverage_cache.zig");
const font = @import("test_font.zig");
const variation = @import("test_variation.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn pathFor(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(a, &.{ buffer[0..len], name });
}

fn writeFont(tmp: *std.testing.TmpDir, name: []const u8) !void {
    const bytes = try variation.buildFont(a, .{ .family = "UVS Cache" }, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{
        .{ .selector = 0xfe00, .mappings = &.{.{ .base = 0x4e2d }} },
        .{ .selector = 0xfe0d, .mappings = &.{.{ .base = 0x4e00 }} },
        .{ .selector = 0xfe0e, .defaults = &.{.{ .start = 0x2764 }} },
        .{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} },
        .{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} },
    });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

test "variation sequence coverage cache shares table without base selector or scalar pollution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFont(&tmp, "font.ttf");
    const path = try pathFor(&tmp, "font.ttf");
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expectEqual(@as(u64, 1), cache.reads.file_opens);
    try std.testing.expectEqual(@as(u64, 5), cache.reads.read_calls);
    const cold = cache.reads;
    for (0..2) |_| {
        try std.testing.expect(!try cache.coversCodepoint(io, path, 0, 0x4e2d, 1));
        try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 1));
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0e, 1));
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 1));
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xfe00, 1));
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e00, 0xfe0d, 1));
        try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xfe0d, 1));
        try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x2764, 0xe0100, 1));
        try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0101, 1));
    }
    try std.testing.expectEqual(cold, cache.reads);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expectEqual(@as(u64, 18), cache.hits);
    try std.testing.expect(!try cache.coversVariationSequence(io, "/missing/uvs.ttf", 0, 0x2764, 0xfe10, 99));
    try std.testing.expectEqual(@as(?u64, 1), cache.generation);
    try std.testing.expectEqual(cold, cache.reads);
    // Direct file API agrees with retained byte-table coverage.
    try std.testing.expect(try cmap.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100));
    try std.testing.expect(!try cmap.coversVariationSequence(io, path, 0, 0x2764, 0xe0100));
}

test "variation sequence coverage cache lazily loads maxp after scalar and retries IO failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFont(&tmp, "font.ttf");
    const path = try pathFor(&tmp, "font.ttf");
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 1));
    try std.testing.expectEqual(@as(u64, 4), cache.reads.read_calls);
    try std.testing.expect(!cache.entries.items[0].glyph_count_loaded);
    try tmp.dir.deleteFile(io, "font.ttf");
    try std.testing.expectError(error.FileNotFound, cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expect(!cache.entries.items[0].glyph_count_loaded);
    try writeFont(&tmp, "font.ttf");
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    try std.testing.expectEqual(@as(u64, 8), cache.reads.read_calls);
    const warm = cache.reads;
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xfe0d, 1));
    try std.testing.expectEqual(warm, cache.reads);
}

test "variation sequence coverage cache TTC indexes and epochs stay independent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try variation.buildFont(a, .{ .family = "UVS First" }, &.{}, &.{.{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} }});
    defer a.free(first);
    const second = try variation.buildFont(a, .{ .family = "UVS Second" }, &.{}, &.{.{ .selector = 0xe0101, .mappings = &.{.{ .base = 0x4e2d }} }});
    defer a.free(second);
    const bytes = try font.buildTestCollection(a, &.{ first, second });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts.ttc", .data = bytes });
    const path = try pathFor(&tmp, "fonts.ttc");
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 1, 0x4e2d, 0xe0100, 1));
    try std.testing.expect(try cache.coversVariationSequence(io, path, 1, 0x4e2d, 0xe0101, 1));
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0101, 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    try std.testing.expectEqual(@as(u64, 12), cache.reads.read_calls);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    const replacement = try font.buildTestCollection(a, &.{ second, first });
    defer a.free(replacement);
    try tmp.dir.writeFile(io, .{ .sub_path = "fonts.ttc", .data = replacement });
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 2));
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0101, 2));
    try std.testing.expectEqual(@as(u64, 3), cache.reads.file_opens);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
}

test "variation sequence coverage cache allocation failure preserves success or retries table read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFont(&tmp, "font.ttf");
    const path = try pathFor(&tmp, "font.ttf");
    defer a.free(path);
    for ([_]usize{ 1, 2 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var cache = coverage.Cache.init(failing.allocator());
        defer cache.deinit();
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
        try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var cache = coverage.Cache.init(failing.allocator());
    defer cache.deinit();
    try std.testing.expectError(error.OutOfMemory, cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x4e2d, 0xe0100, 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
}

test "variation sequence invalid coverage does no IO and missing maxp fails closed" {
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    for ([_]u21{ 0xfe10, 0xdead, 0xe00ff, 0xe01f0 }) |selector| {
        try std.testing.expect(!try cache.coversVariationSequence(io, "/missing/uvs.ttf", 0, 0x2764, selector, 99));
        try std.testing.expect(!try cmap.coversVariationSequence(io, "/missing/uvs.ttf", 0, 0x2764, selector));
    }
    for ([_]u21{ 0xd800, 0xdfff, 0x110000 }) |base| {
        try std.testing.expect(!try cache.coversVariationSequence(io, "/missing/uvs.ttf", 0, base, 0xfe0f, 99));
        try std.testing.expect(!try cache.coversCodepoint(io, "/missing/uvs.ttf", 0, base, 99));
        try std.testing.expect(!try cmap.coversVariationSequence(io, "/missing/uvs.ttf", 0, base, 0xfe0f));
        try std.testing.expect(!try cmap.coversCodepoint(io, "/missing/uvs.ttf", 0, base));
    }
    try std.testing.expectEqual(cmap.ReadStats{}, cache.reads);
    try std.testing.expectEqual(@as(?u64, null), cache.generation);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try variation.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(table);
    const bytes = try font.buildTestFont(a, .{ .family = "Missing Maxp", .cmap = table });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "font.ttf", .data = bytes });
    const path = try pathFor(&tmp, "font.ttf");
    defer a.free(path);
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 1));
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 1));
    const warm = cache.reads;
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 1));
    try std.testing.expectEqual(warm, cache.reads);
    const bounded = try font.buildTestFont(a, .{ .family = "Malformed Maxp", .cmap = table, .num_glyphs = 128 });
    defer a.free(bounded);
    const maxp_record = 12 + 4 * 16;
    const maxp_offset = std.mem.readInt(u32, bounded[maxp_record + 8 ..][0..4], .big);
    for ([_]struct { version: u32, count: u16 }{
        .{ .version = 0x00005000, .count = 0 },
        .{ .version = 0x00010000, .count = 128 }, // truncated v1 maxp
        .{ .version = 0x00020000, .count = 128 },
    }, 2..) |case, epoch| {
        std.mem.writeInt(u32, bounded[maxp_offset..][0..4], case.version, .big);
        std.mem.writeInt(u16, bounded[maxp_offset + 4 ..][0..2], case.count, .big);
        try tmp.dir.writeFile(io, .{ .sub_path = "font.ttf", .data = bounded });
        try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, epoch));
        try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, epoch));
    }
}
