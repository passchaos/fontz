const std = @import("std");
const cmap = @import("cmap.zig");
const coverage = @import("coverage_cache.zig");
const test_font = @import("test_font.zig");

fn writeFont(tmp: *std.testing.TmpDir, name: []const u8, start: u32, end: u32) !void {
    const table = try test_font.buildTestCmap(std.testing.allocator, &.{.{ .start = start, .end = end }}, 12);
    defer std.testing.allocator.free(table);
    const font = try test_font.buildTestFont(std.testing.allocator, .{ .family = "Coverage Sans", .cmap = table });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = font });
}

fn absolutePath(tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.fs.path.join(std.testing.allocator, &.{ buffer[0..len], name });
}

test "coverage cache separates TTC faces and reuses positive and negative codepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const latin = try test_font.buildTestCmap(std.testing.allocator, &.{.{ .start = 'A', .end = 'Z' }}, 12);
    defer std.testing.allocator.free(latin);
    const emoji = try test_font.buildTestCmap(std.testing.allocator, &.{.{ .start = 0x1f600, .end = 0x1f64f }}, 13);
    defer std.testing.allocator.free(emoji);
    const first = try test_font.buildTestFont(std.testing.allocator, .{ .family = "Latin", .cmap = latin });
    defer std.testing.allocator.free(first);
    const second = try test_font.buildTestFont(std.testing.allocator, .{ .family = "Emoji", .cmap = emoji });
    defer std.testing.allocator.free(second);
    const collection = try test_font.buildTestCollection(std.testing.allocator, &.{ first, second });
    defer std.testing.allocator.free(collection);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "faces.ttc", .data = collection });
    const path = try absolutePath(&tmp, "faces.ttc");
    defer std.testing.allocator.free(path);
    var cache = coverage.Cache.init(std.testing.allocator);
    defer cache.deinit();
    const cases = [_]struct { face: u32, codepoint: u21, expected: bool }{
        .{ .face = 0, .codepoint = 'A', .expected = true },
        .{ .face = 1, .codepoint = 'A', .expected = false },
        .{ .face = 0, .codepoint = 0x1f600, .expected = false },
        .{ .face = 1, .codepoint = 0x1f600, .expected = true },
        .{ .face = 1, .codepoint = 0x1f650, .expected = false },
        .{ .face = 0, .codepoint = 'Z', .expected = true },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try cache.coversCodepoint(std.testing.io, path, case.face, case.codepoint, 1));
        try std.testing.expectEqual(case.expected, try cmap.coversCodepoint(std.testing.io, path, case.face, case.codepoint));
    }
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    try std.testing.expectEqual(@as(u64, 4), cache.hits);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expect(!try cache.coversCodepoint(std.testing.io, path, 2, 'A', 1));
}

test "coverage cache invalidates malformed tables and does not retain IO failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try absolutePath(&tmp, "font.ttf");
    defer std.testing.allocator.free(path);
    var cache = coverage.Cache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expectError(error.FileNotFound, cache.coversCodepoint(std.testing.io, path, 0, 'A', 1));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "font.ttf", .data = "bad" });
    try std.testing.expect(!try cache.coversCodepoint(std.testing.io, path, 0, 'A', 1));
    try writeFont(&tmp, "font.ttf", 'A', 'Z');
    // Structural negatives remain stable within an explicitly refreshed index.
    try std.testing.expect(!try cache.coversCodepoint(std.testing.io, path, 0, 'B', 1));
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, path, 0, 'A', 2));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    cache.clear();
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, path, 0, 'Z', 2));
    try std.testing.expectEqual(@as(u64, 3), cache.reads.file_opens);
}

test "coverage cache bounds LRU entries and bytes while oversized tables remain queryable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFont(&tmp, "first.ttf", 'A', 'Z');
    try writeFont(&tmp, "second.ttf", 'a', 'z');
    try writeFont(&tmp, "third.ttf", 'A', 'Z');
    const first = try absolutePath(&tmp, "first.ttf");
    defer std.testing.allocator.free(first);
    const second = try absolutePath(&tmp, "second.ttf");
    defer std.testing.allocator.free(second);
    const third = try absolutePath(&tmp, "third.ttf");
    defer std.testing.allocator.free(third);
    var cache = coverage.Cache.initWithLimits(std.testing.allocator, .{ .entries = 2 });
    defer cache.deinit();
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, first, 0, 'A', 1));
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, second, 0, 'b', 1));
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, first, 0, 'C', 1));
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, third, 0, 'D', 1));
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, first, 0, 'E', 1));
    try std.testing.expectEqual(@as(u64, 3), cache.reads.file_opens);
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, second, 0, 'f', 1));
    try std.testing.expect(!try cache.coversCodepoint(std.testing.io, second, 0, 'A', 1));
    try std.testing.expectEqual(@as(u64, 4), cache.reads.file_opens);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);

    // One format-12 group needs 40 bytes plus the owned path. An over-budget
    // cache keeps coverage correct and falls back to one read per query.
    var oversized = coverage.Cache.initWithLimits(std.testing.allocator, .{ .bytes = first.len + 39 });
    defer oversized.deinit();
    try std.testing.expect(try oversized.coversCodepoint(std.testing.io, first, 0, 'A', 1));
    try std.testing.expect(try oversized.coversCodepoint(std.testing.io, first, 0, 'B', 1));
    try std.testing.expectEqual(@as(u64, 2), oversized.reads.file_opens);
    try std.testing.expectEqual(@as(usize, 0), oversized.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), oversized.resident_bytes);

    var byte_bound = coverage.Cache.initWithLimits(std.testing.allocator, .{ .bytes = @max(first.len, second.len) + 40 });
    defer byte_bound.deinit();
    try std.testing.expect(try byte_bound.coversCodepoint(std.testing.io, first, 0, 'A', 1));
    try std.testing.expect(try byte_bound.coversCodepoint(std.testing.io, second, 0, 'b', 1));
    try std.testing.expectEqual(@as(usize, 1), byte_bound.entries.items.len);
    try std.testing.expect(byte_bound.resident_bytes <= byte_bound.limits.bytes);
}

test "coverage cache keeps successful coverage on installation OOM and retries read OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFont(&tmp, "font.ttf", 'A', 'Z');
    const path = try absolutePath(&tmp, "font.ttf");
    defer std.testing.allocator.free(path);
    for ([_]usize{ 1, 2 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var cache = coverage.Cache.init(failing.allocator());
        defer cache.deinit();
        try std.testing.expect(try cache.coversCodepoint(std.testing.io, path, 0, 'A', 1));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var cache = coverage.Cache.init(failing.allocator());
    defer cache.deinit();
    try std.testing.expectError(error.OutOfMemory, cache.coversCodepoint(std.testing.io, path, 0, 'A', 1));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try cache.coversCodepoint(std.testing.io, path, 0, 'A', 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
}
