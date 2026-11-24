const std = @import("std");
const cmap = @import("cmap.zig");
const coverage = @import("coverage_cache.zig");
const font = @import("test_font.zig");
const plans = @import("cmap_plan.zig");
const variation = @import("test_variation.zig");
const a = std.testing.allocator;
const io = std.testing.io;

fn largeTable(format: u16) ![]u8 {
    const groups = try a.alloc(font.TestCoverageGroup, 32768);
    defer a.free(groups);
    for (groups, 0..) |*group, i| group.* = .{ .start = 0x10000 + @as(u32, @intCast(i)) * 2, .end = 0x10000 + @as(u32, @intCast(i)) * 2, .glyph = @intCast(i + 1) };
    return font.buildTestCmap(a, groups, format);
}

fn writeTable(tmp: *std.testing.TmpDir, name: []const u8, table: []const u8) ![]u8 {
    const bytes = try font.buildTestFont(a, .{ .family = "Prepared Cmap", .cmap = table });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(a, &.{ buffer[0..len], name });
}

test "prepared cmap retained 32K ordered groups bound actual warm visits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try largeTable(12);
    defer a.free(table);
    const path = try writeTable(&tmp, "ordered.ttf", table);
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x10000, 1));
    const reads = cache.reads;
    var visits: [5]u64 = undefined;
    for ([_]u21{ 0x10000, 0x18000, 0x1fffe, 0x18001, 0x20000 }, 0..) |cp, i| {
        var work: cmap.WorkStats = .{};
        const result = try cache.coversCodepointCounted(io, path, 0, cp, 1, &work);
        try std.testing.expectEqual(cmap.tableCovers(table, cp), result);
        visits[i] = work.group_visits;
    }
    std.debug.print("prepared cmap 32K warm visits first/middle/tail/gap/miss: {any}\n", .{visits});
    try std.testing.expectEqual(reads, cache.reads);
    for (visits) |count| try std.testing.expect(count <= 16);
}

fn equivalent(table: []const u8, order: plans.Order) !void {
    var prep: cmap.WorkStats = .{};
    const plan = plans.prepare(true, table, &prep);
    try std.testing.expectEqual(order, plan.order);
    for ([_]u21{ 0, 1, 'A', 'B', 'C', 'Z', 'a', 'z', 0xd800, 0x10000, 0x10ffff, 0x110000 }) |cp| {
        var work: cmap.WorkStats = .{};
        const raw = cmap.tableCovers(table, cp);
        try std.testing.expectEqual(raw, plan.covers(false, table, cp, null));
        try std.testing.expectEqual(raw, plan.covers(true, table, cp, &work));
    }
}

test "prepared cmap format12 and13 preserve zero glyph overflow and ignored declared length" {
    for ([_]u16{ 12, 13 }) |format| {
        const table = try font.buildTestCmap(a, &.{ .{ .start = 0, .end = 1, .glyph = 0 }, .{ .start = 'A', .end = 'Z', .glyph = std.math.maxInt(u32) } }, format);
        defer a.free(table);
        try equivalent(table, .ordered);
        const plan = plans.prepare(false, table, null);
        try std.testing.expect(plan.covers(false, table, 'A', null));
        try std.testing.expectEqual(format == 13, plan.covers(false, table, 'B', null));
        try std.testing.expect(!plan.covers(false, table, 0, null));
        try std.testing.expectEqual(format == 12, plan.covers(false, table, 1, null));
        for ([_]u32{ 0, 16, 28, std.math.maxInt(u32) }) |length| {
            std.mem.writeInt(u32, table[16..20], length, .big);
            try equivalent(table, .ordered);
        }
    }
}

test "prepared cmap unsorted overlapping and reversed groups preserve first linear match" {
    for ([_][]const font.TestCoverageGroup{
        &.{ .{ .start = 'a', .end = 'z' }, .{ .start = 'A', .end = 'Z' } },
        &.{ .{ .start = 'A', .end = 'C', .glyph = 0 }, .{ .start = 'B', .end = 'Z', .glyph = 2 } },
        &.{ .{ .start = 'B', .end = 'A' }, .{ .start = 'A', .end = 'Z' } },
        &.{ .{ .start = 'A', .end = 'C' }, .{ .start = 'C', .end = 'Z' } },
    }) |groups| for ([_]u16{ 12, 13 }) |format| {
        const table = try font.buildTestCmap(a, groups, format);
        defer a.free(table);
        try equivalent(table, .fallback);
        var work: cmap.WorkStats = .{};
        _ = plans.prepare(false, table, null).covers(true, table, 'B', &work);
        try std.testing.expectEqual(@as(u64, 0), work.binary_queries);
        try std.testing.expectEqual(@as(u64, 1), work.linear_queries);
    };
}

test "prepared cmap truncated tables malformed records and subtable preference agree with raw" {
    const table = try font.buildTestCmap(a, &.{ .{ .start = 'A', .end = 'Z' }, .{ .start = 'a', .end = 'z' } }, 12);
    defer a.free(table);
    for (0..table.len) |len| try equivalent(table[0..len], .fallback);
    for ([_]u32{ 0, 1_000_001, std.math.maxInt(u32) }) |count| {
        std.mem.writeInt(u32, table[24..28], count, .big);
        try equivalent(table, .fallback);
    }
    std.mem.writeInt(u32, table[8..12], std.math.maxInt(u32), .big);
    try equivalent(table, .fallback);
    var bmp = [_]u8{0} ** 36;
    std.mem.writeInt(u16, bmp[2..4], 1, .big);
    std.mem.writeInt(u16, bmp[4..6], 3, .big);
    std.mem.writeInt(u16, bmp[6..8], 1, .big);
    std.mem.writeInt(u32, bmp[8..12], 12, .big);
    std.mem.writeInt(u16, bmp[12..14], 4, .big);
    std.mem.writeInt(u16, bmp[14..16], 24, .big);
    std.mem.writeInt(u16, bmp[18..20], 2, .big);
    std.mem.writeInt(u16, bmp[26..28], 'Z', .big);
    std.mem.writeInt(u16, bmp[30..32], 'A', .big);
    try equivalent(&bmp, .fallback);
    try std.testing.expect(cmap.tableCovers(&bmp, 'A'));
    // A higher-scoring format13 wins even when its glyph is zero; do not fall
    // through to another nonzero format12 subtable.
    var dual = [_]u8{0} ** 76;
    std.mem.writeInt(u16, dual[2..4], 2, .big);
    for (0..2) |i| {
        const record = 4 + i * 8;
        std.mem.writeInt(u16, dual[record..][0..2], if (i == 0) 0 else 3, .big);
        std.mem.writeInt(u16, dual[record + 2 ..][0..2], if (i == 0) 4 else 10, .big);
        std.mem.writeInt(u32, dual[record + 4 ..][0..4], @intCast(20 + i * 28), .big);
        const row = 20 + i * 28;
        std.mem.writeInt(u16, dual[row..][0..2], if (i == 0) 12 else 13, .big);
        std.mem.writeInt(u32, dual[row + 12 ..][0..4], 1, .big);
        std.mem.writeInt(u32, dual[row + 16 ..][0..4], 'A', .big);
        std.mem.writeInt(u32, dual[row + 20 ..][0..4], 'Z', .big);
        std.mem.writeInt(u32, dual[row + 24 ..][0..4], if (i == 0) 1 else 0, .big);
    }
    try equivalent(&dual, .ordered);
    try std.testing.expectEqual(@as(u32, 48), plans.prepare(false, &dual, null).offset);
}

test "prepared cmap cache performs one proof and warm scalars require no allocations or IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try largeTable(13);
    defer a.free(table);
    const path = try writeTable(&tmp, "warm.ttf", table);
    defer a.free(path);
    var failing = std.testing.FailingAllocator.init(a, .{});
    var cache = coverage.Cache.init(failing.allocator());
    defer cache.deinit();
    var cold: cmap.WorkStats = .{};
    try std.testing.expect(try cache.coversCodepointCounted(io, path, 0, 0x10000, 1, &cold));
    try std.testing.expectEqual(@as(u64, 32768), cold.preparation_visits);
    try std.testing.expectEqual(@as(u64, 1), cold.group_visits);
    try std.testing.expectEqual(plans.Order.ordered, cache.entries.items[0].scalar_plan.order);
    try std.testing.expectEqual(@as(usize, path.len + table.len), cache.resident_bytes);
    const allocations = failing.allocations;
    const reads = cache.reads;
    const pointer = cache.entries.items[0].table.?.ptr;
    failing.fail_index = failing.alloc_index;
    var warm: cmap.WorkStats = .{};
    for (0..256) |i| {
        const cp: u21 = 0x10000 + @as(u21, @intCast(i * 255));
        try std.testing.expectEqual(cmap.tableCovers(table, cp), try cache.coversCodepointCounted(io, path, 0, cp, 1, &warm));
    }
    try std.testing.expectEqual(@as(u64, 0), warm.preparation_visits);
    try std.testing.expectEqual(@as(u64, 256), warm.binary_queries);
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expectEqual(reads, cache.reads);
    try std.testing.expectEqual(pointer, cache.entries.items[0].table.?.ptr);
    try std.testing.expect(!failing.has_induced_failure);
}

test "prepared cmap LRU byte cap disabled oversized and allocation failures preserve coverage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try font.buildTestCmap(a, &.{.{ .start = 'A', .end = 'Z' }}, 12);
    defer a.free(table);
    const first = try writeTable(&tmp, "first.ttf", table);
    defer a.free(first);
    const second = try writeTable(&tmp, "second.ttf", table);
    defer a.free(second);
    for ([_]coverage.Limits{ .{ .entries = 0 }, .{ .bytes = first.len + table.len - 1 } }) |limits| {
        var cache = coverage.Cache.initWithLimits(a, limits);
        defer cache.deinit();
        var work: cmap.WorkStats = .{};
        for (0..2) |_| try std.testing.expect(try cache.coversCodepointCounted(io, first, 0, 'A', 1, &work));
        try std.testing.expectEqual(@as(u64, 0), work.preparation_visits);
        try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
        try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    }
    var lru = coverage.Cache.initWithLimits(a, .{ .entries = 1 });
    defer lru.deinit();
    for ([_][]const u8{ first, second, first }) |path| try std.testing.expect(try lru.coversCodepoint(io, path, 0, 'A', 1));
    try std.testing.expectEqual(@as(u64, 3), lru.reads.file_opens);
    try std.testing.expectEqual(@as(usize, 1), lru.entries.items.len);
    try std.testing.expectEqual(plans.Order.ordered, lru.entries.items[0].scalar_plan.order);
    for ([_]usize{ 1, 2 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var cache = coverage.Cache.init(failing.allocator());
        defer cache.deinit();
        var work: cmap.WorkStats = .{};
        try std.testing.expect(try cache.coversCodepointCounted(io, first, 0, 'A', 1, &work));
        try std.testing.expectEqual(@as(u64, 0), work.preparation_visits);
        try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(try cache.coversCodepoint(io, first, 0, 'A', 1));
        try std.testing.expectEqual(plans.Order.ordered, cache.entries.items[0].scalar_plan.order);
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var cache = coverage.Cache.init(failing.allocator());
    defer cache.deinit();
    try std.testing.expectError(error.OutOfMemory, cache.coversCodepoint(io, first, 0, 'A', 1));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try cache.coversCodepoint(io, first, 0, 'A', 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
}

test "prepared cmap cache epochs and original TTC indexes retain independent plans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first_table = try font.buildTestCmap(a, &.{.{ .start = 'A', .end = 'Z' }}, 12);
    defer a.free(first_table);
    const second_table = try font.buildTestCmap(a, &.{.{ .start = 'a', .end = 'z' }}, 13);
    defer a.free(second_table);
    const first = try font.buildTestFont(a, .{ .family = "Prepared First", .cmap = first_table });
    defer a.free(first);
    const second = try font.buildTestFont(a, .{ .family = "Prepared Second", .cmap = second_table });
    defer a.free(second);
    const bad = [_]u8{0} ** 12;
    const collection = try font.buildTestCollection(a, &.{ &bad, first, &bad, second });
    defer a.free(collection);
    try tmp.dir.writeFile(io, .{ .sub_path = "faces.ttc", .data = collection });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..len], "faces.ttc" });
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversCodepoint(io, path, 1, 'A', 1));
    try std.testing.expect(!try cache.coversCodepoint(io, path, 3, 'A', 1));
    try std.testing.expect(try cache.coversCodepoint(io, path, 3, 'a', 1));
    try std.testing.expectEqual(@as(u32, 1), cache.entries.items[0].face_index);
    try std.testing.expectEqual(@as(u32, 3), cache.entries.items[1].face_index);
    const replacement = try font.buildTestCollection(a, &.{ &bad, second, &bad, first });
    defer a.free(replacement);
    try tmp.dir.writeFile(io, .{ .sub_path = "faces.ttc", .data = replacement });
    try std.testing.expect(try cache.coversCodepoint(io, path, 1, 'A', 1));
    try std.testing.expect(!try cache.coversCodepoint(io, path, 1, 'A', 2));
    try std.testing.expect(try cache.coversCodepoint(io, path, 1, 'a', 2));
    try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    try std.testing.expectEqual(@as(u16, 13), cache.entries.items[0].scalar_plan.format);
}

test "prepared cmap UVS uses strict nominal path and lazy maxp independently of scalar plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try variation.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(table);
    const bytes = try font.buildTestFont(a, .{ .family = "Prepared UVS", .cmap = table, .num_glyphs = 128 });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "uvs.ttf", .data = bytes });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..len], "uvs.ttf" });
    defer a.free(path);
    var cache = coverage.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 1));
    try std.testing.expectEqual(plans.Order.unprepared, cache.entries.items[0].scalar_plan.order);
    const reads = cache.reads;
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 1));
    try std.testing.expectEqual(reads, cache.reads);
    try std.testing.expectEqual(plans.Order.ordered, cache.entries.items[0].scalar_plan.order);
    cache.clear();
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 1));
    try std.testing.expect(!cache.entries.items[0].glyph_count_loaded);
    try std.testing.expect(try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 1));
    try std.testing.expect(cache.entries.items[0].glyph_count_loaded);
    // Scalar preparation must continue ignoring the declared nominal length;
    // a default UVS must continue respecting that very same declaration.
    std.mem.writeInt(u32, table[24..28], 16, .big);
    const malformed = try font.buildTestFont(a, .{ .family = "Prepared UVS", .cmap = table, .num_glyphs = 128 });
    defer a.free(malformed);
    try tmp.dir.writeFile(io, .{ .sub_path = "uvs.ttf", .data = malformed });
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 2));
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x2764, 2));
    try std.testing.expect(!try cache.coversVariationSequence(io, path, 0, 0x2764, 0xfe0f, 2));
}
