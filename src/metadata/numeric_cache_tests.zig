const std = @import("std");
const cmap = @import("cmap.zig");
const cache_mod = @import("coverage_cache.zig");
const font = @import("test_font.zig");
const fixture = @import("test_extended.zig");
const unit = @import("numeric_unit_tests.zig");
const a = std.testing.allocator;
const io = std.testing.io;

pub fn write(tmp: *std.testing.TmpDir, name: []const u8, table: []const u8, glyph_count: ?u16) ![]u8 {
    const bytes = try font.buildTestFont(a, .{ .family = "Unicode Cmap Cache", .cmap = table, .num_glyphs = glyph_count });
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(a, &.{ buffer[0..len], name });
}

test "unicode cmap file cache scalar and default UVS perform one qualification and warm no work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try fixture.sample(a, format);
        defer a.free(subtable);
        const table = try fixture.withVariation(a, subtable, fixture.encoding(format), fixture.base(format), false);
        defer a.free(table);
        const path = try write(&tmp, "new.ttf", table, 8);
        defer a.free(path);
        var failing = std.testing.FailingAllocator.init(a, .{});
        var cache = cache_mod.Cache.init(failing.allocator());
        defer cache.deinit();
        var cold: cmap.WorkStats = .{};
        try std.testing.expect(try cache.coversCodepointCounted(io, path, 0, fixture.base(format), 1, &cold));
        try std.testing.expectEqual(@as(u64, 1), cold.new_subtable_validations);
        try std.testing.expectEqual(@as(u64, 1), cache.reads.file_opens);
        try std.testing.expectEqual(@as(u64, 5), cache.reads.read_calls);
        try std.testing.expect(cache.entries.items[0].glyph_count_loaded);
        try std.testing.expect(try cmap.coversCodepoint(io, path, 0, fixture.base(format)));
        const reads = cache.reads;
        const allocations = failing.allocations;
        failing.fail_index = failing.alloc_index;
        var warm: cmap.WorkStats = .{};
        for (0..4) |_| {
            try std.testing.expect(try cache.coversCodepointCounted(io, path, 0, fixture.base(format), 1, &warm));
            try std.testing.expect(try cache.coversVariationSequenceCounted(io, path, 0, fixture.base(format), 0xfe0f, 1, &warm));
        }
        try std.testing.expectEqual(@as(u64, 0), warm.new_subtable_validations);
        try std.testing.expectEqual(reads, cache.reads);
        try std.testing.expectEqual(allocations, failing.allocations);
        cache.clear();
        failing.fail_index = std.math.maxInt(usize);
        var uv_first: cmap.WorkStats = .{};
        try std.testing.expect(try cache.coversVariationSequenceCounted(io, path, 0, fixture.base(format), 0xfe0f, 1, &uv_first));
        try std.testing.expectEqual(@as(u64, 1), uv_first.new_subtable_validations);
        var after_uv: cmap.WorkStats = .{};
        try std.testing.expect(try cache.coversCodepointCounted(io, path, 0, fixture.base(format), 1, &after_uv));
        try std.testing.expectEqual(@as(u64, 0), after_uv.new_subtable_validations);
    }
}

test "unicode cmap real font qualification rejects missing invalid maxp and unrelated invalid glyph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try fixture.sample(a, format);
        defer a.free(subtable);
        const table = try fixture.wrap(a, subtable, 0, fixture.encoding(format));
        defer a.free(table);
        for ([_]?u16{ null, 0, 3 }) |count| {
            const path = try write(&tmp, "maxp.ttf", table, count);
            defer a.free(path);
            var cache = cache_mod.Cache.init(a);
            defer cache.deinit();
            try std.testing.expect(cmap.tableCovers(table, fixture.base(format)));
            try std.testing.expect(!try cache.coversCodepoint(io, path, 0, fixture.base(format), 1));
            try std.testing.expect(!try cmap.coversCodepoint(io, path, 0, fixture.base(format)));
            const reads = cache.reads;
            try std.testing.expect(!try cache.coversCodepoint(io, path, 0, fixture.base(format), 1));
            try std.testing.expectEqual(reads, cache.reads);
        }
        const invalid_font = try font.buildTestFont(a, .{ .family = "Unicode Cmap", .cmap = table, .num_glyphs = 8 });
        defer a.free(invalid_font);
        const record = 12 + 4 * 16;
        const maxp = std.mem.readInt(u32, invalid_font[record + 8 ..][0..4], .big);
        fixture.put32(invalid_font, maxp, 0x00020000);
        try tmp.dir.writeFile(io, .{ .sub_path = "version.ttf", .data = invalid_font });
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        const invalid_path = try std.fs.path.join(a, &.{ buffer[0..len], "version.ttf" });
        defer a.free(invalid_path);
        try std.testing.expect(!try cmap.coversCodepoint(io, invalid_path, 0, fixture.base(format)));
        const bad_subtable = try unit.badDomain(format);
        defer a.free(bad_subtable);
        const bad_table = try fixture.withVariation(a, bad_subtable, fixture.encoding(format), 'A', true);
        defer a.free(bad_table);
        const bad_path = try write(&tmp, "domain.ttf", bad_table, 8);
        defer a.free(bad_path);
        var cache = cache_mod.Cache.init(a);
        defer cache.deinit();
        try std.testing.expect(!try cache.coversCodepoint(io, bad_path, 0, 'A', 1));
        try std.testing.expect(!try cache.coversVariationSequence(io, bad_path, 0, 'A', 0xfe0f, 1));
        const reads = cache.reads;
        var warm: cmap.WorkStats = .{};
        try std.testing.expect(!try cache.coversCodepointCounted(io, bad_path, 0, 'A', 1, &warm));
        try std.testing.expectEqual(@as(u64, 0), warm.new_subtable_validations);
        try std.testing.expectEqual(reads, cache.reads);
    }
}

test "unicode cmap IO allocation failure retry epoch and cache limits preserve qualification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const subtable = try fixture.sample(a, 10);
    defer a.free(subtable);
    const table = try fixture.wrap(a, subtable, 0, 4);
    defer a.free(table);
    const path = try write(&tmp, "retry.ttf", table, 8);
    defer a.free(path);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var cache = cache_mod.Cache.init(failing.allocator());
    defer cache.deinit();
    try std.testing.expectError(error.OutOfMemory, cache.coversCodepoint(io, path, 0, 0x1f600, 1));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 0x1f600, 1));
    try std.testing.expectEqual(@as(u64, 2), cache.reads.file_opens);
    for ([_]usize{ 1, 2 }) |fail_index| {
        var install_fail = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var uncached = cache_mod.Cache.init(install_fail.allocator());
        defer uncached.deinit();
        try std.testing.expect(try uncached.coversCodepoint(io, path, 0, 0x1f600, 1));
        try std.testing.expectEqual(@as(usize, 0), uncached.entries.items.len);
    }
    var missing = cache_mod.Cache.init(a);
    defer missing.deinit();
    try tmp.dir.deleteFile(io, "retry.ttf");
    try std.testing.expectError(error.FileNotFound, missing.coversCodepoint(io, path, 0, 0x1f600, 1));
    const same = try write(&tmp, "retry.ttf", table, null);
    defer a.free(same);
    try std.testing.expect(!try missing.coversCodepoint(io, path, 0, 0x1f600, 1));
    const restored = try write(&tmp, "retry.ttf", table, 8);
    defer a.free(restored);
    try std.testing.expect(!try missing.coversCodepoint(io, path, 0, 0x1f600, 1));
    try std.testing.expect(try missing.coversCodepoint(io, path, 0, 0x1f600, 2));
    for ([_]cache_mod.Limits{ .{ .entries = 0 }, .{ .bytes = path.len + table.len - 1 } }) |limits| {
        var limited = cache_mod.Cache.initWithLimits(a, limits);
        defer limited.deinit();
        try std.testing.expect(try limited.coversCodepoint(io, path, 0, 0x1f600, 1));
        try std.testing.expectEqual(@as(usize, 0), limited.entries.items.len);
    }
}

test "unicode cmap legacy scalar cold controls still ignore maxp and retain prepared arithmetic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const table = try font.buildTestCmap(a, &.{.{ .start = 'A', .end = 'Z' }}, 12);
    defer a.free(table);
    const path = try write(&tmp, "legacy.ttf", table, null);
    defer a.free(path);
    var cache = cache_mod.Cache.init(a);
    defer cache.deinit();
    try std.testing.expect(try cache.coversCodepoint(io, path, 0, 'A', 1));
    try std.testing.expectEqual(@as(u64, 1), cache.reads.file_opens);
    try std.testing.expectEqual(@as(u64, 4), cache.reads.read_calls);
    try std.testing.expectEqual(@as(u64, 128), cache.reads.bytes_read);
    const overflow = try font.buildTestCmap(a, &.{.{ .start = 'A', .end = 'Z', .glyph = 0xffffffff }}, 12);
    defer a.free(overflow);
    const overflow_path = try write(&tmp, "overflow.ttf", overflow, 1);
    defer a.free(overflow_path);
    try std.testing.expect(try cache.coversCodepoint(io, overflow_path, 0, 'A', 1));
    try std.testing.expect(!try cache.coversCodepoint(io, overflow_path, 0, 'B', 1));
    try std.testing.expect(!cache.entries.items[1].glyph_count_loaded);
}

test "unicode cmap whole context rejects unselected bad new table for scalar and nondefault UVS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bmp = try fixture.buildBmp4(a, 'A', 1);
    defer a.free(bmp);
    const ten = try fixture.buildFormat10(a, 0x1f600, &.{ 1, 0xffff });
    defer a.free(ten);
    const variation = try fixture.withVariation(a, ten, 4, 'A', true);
    defer a.free(variation);
    const variation_offset = std.mem.readInt(u32, variation[16..20], .big);
    const table = try fixture.join(a, &.{
        .{ .platform = 3, .encoding = 1, .table = bmp },
        .{ .encoding = 4, .table = ten },
        .{ .encoding = 5, .table = variation[variation_offset..] },
    });
    defer a.free(table);
    try std.testing.expectEqual(@as(u16, 4), cmap.scalarSubtable(table).?.format);
    try std.testing.expect(cmap.tableCovers(table, 'A')); // raw has no maxp
    try std.testing.expect(!cmap.tableCoversBounded(table, 'A', 8));
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 'A', 0xfe0f, 8));
    const only14 = try fixture.wrap(a, variation[variation_offset..], 0, 5);
    defer a.free(only14);
    try std.testing.expect(cmap.tableCoversVariationSequence(only14, 'A', 0xfe0f, 8));
    const path = try write(&tmp, "context.ttf", table, 8);
    defer a.free(path);
    try std.testing.expect(!try cmap.coversCodepoint(io, path, 0, 'A'));
    try std.testing.expect(!try cmap.coversVariationSequence(io, path, 0, 'A', 0xfe0f));
    var cache = cache_mod.Cache.init(a);
    defer cache.deinit();
    var cold: cmap.WorkStats = .{};
    try std.testing.expect(!try cache.coversCodepointCounted(io, path, 0, 'A', 1, &cold));
    try std.testing.expectEqual(@as(u64, 1), cold.new_subtable_validations);
    try std.testing.expectEqual(@as(u64, 5), cache.reads.read_calls);
    const reads = cache.reads;
    var warm: cmap.WorkStats = .{};
    try std.testing.expect(!try cache.coversVariationSequenceCounted(io, path, 0, 'A', 0xfe0f, 1, &warm));
    try std.testing.expect(!try cache.coversCodepointCounted(io, path, 0, 'A', 1, &warm));
    try std.testing.expectEqual(@as(u64, 0), warm.new_subtable_validations);
    try std.testing.expectEqual(reads, cache.reads);
    for ([_]cache_mod.Limits{ .{ .entries = 0 }, .{ .bytes = path.len + table.len - 1 } }) |limits| {
        var unretained = cache_mod.Cache.initWithLimits(a, limits);
        defer unretained.deinit();
        try std.testing.expect(!try unretained.coversCodepoint(io, path, 0, 'A', 1));
        try std.testing.expect(!try unretained.coversVariationSequence(io, path, 0, 'A', 0xfe0f, 1));
        try std.testing.expectEqual(@as(usize, 0), unretained.entries.items.len);
    }
}
