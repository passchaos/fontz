const std = @import("std");
const cmap = @import("cmap.zig");
const numeric = @import("cmap_numeric.zig");
const plans = @import("cmap_plan.zig");
const fixture = @import("test_extended.zig");
const a = std.testing.allocator;

fn tableFor(format: u16) ![]u8 {
    const subtable = try fixture.sample(a, format);
    defer a.free(subtable);
    return fixture.wrap(a, subtable, 0, fixture.encoding(format));
}
fn missing(subtable: []const u8, format: u16) !void {
    const table = try fixture.wrap(a, subtable, 0, fixture.encoding(format));
    defer a.free(table);
    try std.testing.expect(!cmap.tableCovers(table, fixture.base(format)));
    try std.testing.expect(!cmap.tableCoversBounded(table, fixture.base(format), 8));
}

test "unicode cmap new formats require registered Unicode encoding identity" {
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try fixture.sample(a, format);
        defer a.free(subtable);
        for ([_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 0xffff }) |encoding| {
            const table = try fixture.wrap(a, subtable, 0, encoding);
            defer a.free(table);
            const accepted = encoding <= 2 or (encoding == 4 and format != 2);
            try std.testing.expectEqual(accepted, cmap.tableCovers(table, fixture.base(format)));
            try std.testing.expectEqual(accepted, cmap.tableCoversBounded(table, fixture.base(format), 8));
            const plan = plans.prepare(false, table, null);
            try std.testing.expectEqual(plans.Order.fallback, plan.order);
            try std.testing.expectEqual(accepted, plan.covers(false, table, fixture.base(format), null));
        }
        for ([_]u16{ 1, 2, 3, 4, 240 }) |platform| {
            const table = try fixture.wrap(a, subtable, platform, 2);
            defer a.free(table);
            try std.testing.expect(!cmap.tableCovers(table, fixture.base(format)));
        }
    }
}

test "unicode cmap format2 single byte high keys delta wrapping and zero glyph" {
    const subtable = try fixture.buildFormat2(a, &.{
        .{ .high = 0, .first = 'A', .glyphs = &.{ 1, 0, 0xffff }, .delta = 2 },
        .{ .high = 1, .first = 2, .glyphs = &.{ 5, 1 }, .delta = -2 },
    });
    defer a.free(subtable);
    const table = try fixture.wrap(a, subtable, 0, 2);
    defer a.free(table);
    try std.testing.expect(cmap.tableCovers(table, 'A'));
    try std.testing.expect(!cmap.tableCovers(table, 'B'));
    try std.testing.expect(cmap.tableCovers(table, 'C')); // ffff + 2 -> 1
    try std.testing.expect(cmap.tableCovers(table, 0x0102));
    try std.testing.expect(!cmap.tableCovers(table, 0x0241)); // absent high key
    try std.testing.expect(!cmap.tableCovers(table, 0x10000));
    // The unrelated wrapped mapping 1-2 -> ffff invalidates the bounded domain.
    try std.testing.expect(!cmap.tableCoversBounded(table, 'A', 8));
    const wrapped = try fixture.buildFormat2(a, &.{.{ .high = 1, .first = 2, .glyphs = &.{0xffff}, .delta = 2 }});
    defer a.free(wrapped);
    const wrapped_table = try fixture.wrap(a, wrapped, 0, 2);
    defer a.free(wrapped_table);
    try std.testing.expect(cmap.tableCoversBounded(wrapped_table, 0x0102, 8));
}

test "unicode cmap format2 validates every key subheader and glyph span" {
    const valid = try fixture.sample(a, 2);
    defer a.free(valid);
    const clone = try a.dupe(u8, valid);
    defer a.free(clone);
    for ([_]struct { offset: usize, value: u16 }{
        .{ .offset = 8, .value = 10 }, // key[1] not eight-byte aligned
        .{ .offset = 8, .value = 0xfff8 }, // missing referenced header
        .{ .offset = 532, .value = 0 }, // points into subheader metadata
        .{ .offset = 532, .value = 3 }, // unaligned glyph address
        .{ .offset = 528, .value = 2 }, // second glyph extends past length
        .{ .offset = 526, .value = 0x100 }, // low-byte domain overflow
        .{ .offset = 4, .value = 1 }, // Unicode language must be zero
    }) |case| {
        @memcpy(clone, valid);
        fixture.put16(clone, case.offset, case.value);
        try missing(clone, 2);
    }
    @memcpy(clone, valid);
    fixture.put16(clone, 6 + 0xd8 * 2, 8);
    try missing(clone, 2); // a different high key advertises a surrogate range
    for (0..valid.len) |length| try missing(valid[0..length], 2);
    // Empty subheaders do not have an addressable glyph range.
    const empty = try fixture.buildFormat2(a, &.{});
    defer a.free(empty);
    fixture.put16(empty, 518, 0xffff);
    fixture.put16(empty, 524, 3);
    try std.testing.expect(numeric.validate(empty, 2, 8));
}

test "unicode cmap format8 uses scalar highword is32 with BMP and plane boundaries" {
    const subtable = try fixture.buildFormat8(a, &.{
        .{ .start = 'A', .end = 'A', .glyph = 1 },
        .{ .start = 0x1ffff, .end = 0x20000, .glyph = 2 },
    });
    defer a.free(subtable);
    const table = try fixture.wrap(a, subtable, 0, 4);
    defer a.free(table);
    try std.testing.expect(cmap.tableCoversBounded(table, 'A', 8));
    try std.testing.expect(cmap.tableCoversBounded(table, 0x1ffff, 8));
    try std.testing.expect(cmap.tableCoversBounded(table, 0x20000, 8));
    try std.testing.expect(!cmap.tableCovers(table, 0x20001));
    subtable[12 + 500 / 8] |= 0x80 >> (500 & 7); // unused bits are permitted
    try std.testing.expect(numeric.validate(subtable, 8, 8));
    const packed_utf16 = try fixture.buildFormat8(a, &.{.{ .start = 0xd801dc00, .end = 0xd801dc00 }});
    defer a.free(packed_utf16);
    try missing(packed_utf16, 8);
}

test "unicode cmap format8 rejects malformed groups widths language reserved and arithmetic" {
    const valid = try fixture.sample(a, 8);
    defer a.free(valid);
    const clone = try a.dupe(u8, valid);
    defer a.free(clone);
    @memcpy(clone, valid);
    clone[12] &= ~@as(u8, 0x40);
    try missing(clone, 8); // supplementary highword one must be marked
    @memcpy(clone, valid);
    clone[12 + 'A' / 8] |= @as(u8, 0x80) >> ('A' & 7);
    try missing(clone, 8); // a mapped BMP scalar must be standalone
    for ([_]struct { offset: usize, value: u32 }{
        .{ .offset = 8, .value = 1 },
        .{ .offset = 8204, .value = 3 },
        .{ .offset = 8208 + 12, .value = 'A' }, // overlap
        .{ .offset = 8208 + 16, .value = 0x103ff }, // reversed
        .{ .offset = 8208 + 12, .value = 0xd800 },
        .{ .offset = 8208 + 20, .value = 0xffffffff },
    }) |case| {
        @memcpy(clone, valid);
        fixture.put32(clone, case.offset, case.value);
        try missing(clone, 8);
    }
    @memcpy(clone, valid);
    fixture.put16(clone, 2, 1);
    try missing(clone, 8);
    @memcpy(clone, valid);
    fixture.put32(clone, 4, @intCast(valid.len - 1));
    try missing(clone, 8);
    const crossing = try fixture.buildFormat8(a, &.{.{ .start = 0xd7ff, .end = 0xe000 }});
    defer a.free(crossing);
    try missing(crossing, 8);
}

test "unicode cmap format10 validates complete trimmed range body zero and overflow" {
    const table = try tableFor(10);
    defer a.free(table);
    try std.testing.expect(cmap.tableCoversBounded(table, 0x1f600, 8));
    try std.testing.expect(!cmap.tableCovers(table, 0x1f601));
    try std.testing.expect(cmap.tableCoversBounded(table, 0x1f602, 8));
    try std.testing.expect(!cmap.tableCovers(table, 0x1f603));
    const edge = try fixture.buildFormat10(a, 0x10ffff, &.{7});
    defer a.free(edge);
    const edge_table = try fixture.wrap(a, edge, 0, 4);
    defer a.free(edge_table);
    try std.testing.expect(cmap.tableCoversBounded(edge_table, 0x10ffff, 8));
    for ([_]u32{ 0xd7ff, 0x10ffff, 0xffffffff }) |first| {
        const bad = try fixture.buildFormat10(a, first, &.{ 1, 2 });
        defer a.free(bad);
        try missing(bad, 10);
    }
    const valid = try fixture.sample(a, 10);
    defer a.free(valid);
    const clone = try a.dupe(u8, valid);
    defer a.free(clone);
    for ([_]struct { offset: usize, value: u32 }{ .{ .offset = 4, .value = 24 }, .{ .offset = 8, .value = 1 }, .{ .offset = 16, .value = 0xffffffff } }) |case| {
        @memcpy(clone, valid);
        fixture.put32(clone, case.offset, case.value);
        try missing(clone, 10);
    }
    @memcpy(clone, valid);
    fixture.put16(clone, 2, 1);
    try missing(clone, 10);
    for (0..valid.len) |length| try missing(valid[0..length], 10);
    const empty = try fixture.buildFormat10(a, 'A', &.{});
    defer a.free(empty);
    try std.testing.expect(numeric.validate(empty, 10, 8));
}

pub fn badDomain(format: u16) ![]u8 {
    return switch (format) {
        2 => fixture.buildFormat2(a, &.{ .{ .high = 0, .first = 'A', .glyphs = &.{1} }, .{ .high = 1, .first = 2, .glyphs = &.{0xffff} } }),
        8 => fixture.buildFormat8(a, &.{ .{ .start = 'A', .end = 'A', .glyph = 1 }, .{ .start = 0x10400, .end = 0x10400, .glyph = 0xffff } }),
        10 => fixture.buildFormat10(a, 'A', &.{ 1, 0xffff }),
        else => unreachable,
    };
}

test "unicode cmap raw mapping differs from full maxp qualification and qualifies nondefault UVS new context" {
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try badDomain(format);
        defer a.free(subtable);
        const table = try fixture.wrap(a, subtable, 0, fixture.encoding(format));
        defer a.free(table);
        try std.testing.expect(cmap.tableCovers(table, 'A'));
        try std.testing.expect(!cmap.tableCoversBounded(table, 'A', 8));
        const defaults = try fixture.withVariation(a, subtable, fixture.encoding(format), 'A', false);
        defer a.free(defaults);
        try std.testing.expect(!cmap.tableCoversVariationSequence(defaults, 'A', 0xfe0f, 8));
        const nondefault = try fixture.withVariation(a, subtable, fixture.encoding(format), 'A', true);
        defer a.free(nondefault);
        try std.testing.expect(!cmap.tableCoversVariationSequence(nondefault, 'A', 0xfe0f, 8));
    }
}

test "unicode cmap default UVS uses complete new nominal grammar and u32 extended lengths" {
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try fixture.sample(a, format);
        defer a.free(subtable);
        const table = try fixture.withVariation(a, subtable, fixture.encoding(format), fixture.base(format), false);
        defer a.free(table);
        try std.testing.expect(cmap.tableCoversVariationSequence(table, fixture.base(format), 0xfe0f, 8));
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, fixture.base(format), 0xfe0e, 8));
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, fixture.base(format), 0xfe0f, 3));
        try std.testing.expect(!cmap.tableCoversBounded(table, fixture.base(format), 0));
    }
}

test "unicode cmap conflicting siblings preserve rank ties and selected failure" {
    const two = try fixture.buildFormat2(a, &.{.{ .high = 0, .first = 'A', .glyphs = &.{3} }});
    defer a.free(two);
    var six = [_]u8{0} ** 12;
    fixture.put16(&six, 0, 6);
    fixture.put16(&six, 2, 12);
    fixture.put16(&six, 6, 'A');
    fixture.put16(&six, 8, 1);
    const old_selected = try fixture.join(a, &.{ .{ .encoding = 2, .table = two }, .{ .encoding = 3, .table = &six } });
    defer a.free(old_selected);
    try std.testing.expectEqual(@as(u16, 2), cmap.scalarSubtable(old_selected).?.format);
    try std.testing.expect(cmap.tableCovers(old_selected, 'A')); // new2/old6 share first-record rank
    const same_rank = try fixture.buildFormat2(a, &.{.{ .high = 0, .first = 'A', .glyphs = &.{0} }});
    defer a.free(same_rank);
    const tied = try fixture.join(a, &.{ .{ .encoding = 2, .table = same_rank }, .{ .encoding = 2, .table = two } });
    defer a.free(tied);
    try std.testing.expect(!cmap.tableCovers(tied, 'A')); // first same-score record stays authoritative
    for ([_]u16{ 8, 10 }) |format| {
        const full = if (format == 8) try fixture.buildFormat8(a, &.{.{ .start = 'A', .end = 'A', .glyph = 0 }}) else try fixture.buildFormat10(a, 'A', &.{0});
        defer a.free(full);
        const selected = try fixture.join(a, &.{ .{ .encoding = 3, .table = &six }, .{ .encoding = 4, .table = full } });
        defer a.free(selected);
        try std.testing.expectEqual(format, cmap.scalarSubtable(selected).?.format);
        try std.testing.expect(!cmap.tableCovers(selected, 'A'));
        fixture.put16(&six, 10, 1);
        const lower_nonzero = try fixture.join(a, &.{ .{ .encoding = 3, .table = &six }, .{ .encoding = 4, .table = full } });
        defer a.free(lower_nonzero);
        try std.testing.expect(!cmap.tableCovers(lower_nonzero, 'A')); // no union of coverage
        fixture.put32(full, 4, 12); // malformed selected full table still does not fall through
        const malformed = try fixture.join(a, &.{ .{ .encoding = 3, .table = &six }, .{ .encoding = 4, .table = full } });
        defer a.free(malformed);
        try std.testing.expect(!cmap.tableCovers(malformed, 'A'));
    }
    const twelve = try @import("test_font.zig").buildTestCmap(a, &.{.{ .start = 'A', .end = 'A', .glyph = 0 }}, 12);
    defer a.free(twelve);
    const ten = try fixture.buildFormat10(a, 'A', &.{3});
    defer a.free(ten);
    const preferred = try fixture.join(a, &.{ .{ .encoding = 4, .table = ten }, .{ .platform = 3, .encoding = 10, .table = twelve[12..] } });
    defer a.free(preferred);
    try std.testing.expectEqual(@as(u16, 12), cmap.scalarSubtable(preferred).?.format);
    try std.testing.expect(!cmap.tableCovers(preferred, 'A'));
    const key_zero = try fixture.sample(a, 2);
    defer a.free(key_zero);
    fixture.put16(key_zero, 6, 8);
    const key_table = try fixture.wrap(a, key_zero, 0, 2);
    defer a.free(key_table);
    try std.testing.expect(cmap.tableCoversBounded(key_table, 2, 8)); // key[0] need not be zero
    const unreferenced = try fixture.buildFormat2(a, &.{ .{ .high = 1, .first = 2, .glyphs = &.{0xffff} }, .{ .high = 2, .first = 2, .glyphs = &.{1} } });
    defer a.free(unreferenced);
    fixture.put16(unreferenced, 8, 16); // header1 is now unreferenced but remains part of maxIndex domain
    const unreferenced_table = try fixture.wrap(a, unreferenced, 0, 2);
    defer a.free(unreferenced_table);
    try std.testing.expect(cmap.tableCovers(unreferenced_table, 0x0102));
    try std.testing.expect(!cmap.tableCoversBounded(unreferenced_table, 0x0102, 8));
}

test "unicode cmap mixed default priority matches BMP full deprecated and old no context control" {
    const bmp = try fixture.buildBmp4(a, 'A', 1);
    defer a.free(bmp);
    const ten = try fixture.buildFormat10(a, 0x1f600, &.{3});
    defer a.free(ten);
    for (0..2) |order| {
        const records = if (order == 0)
            &[_]fixture.Record{ .{ .platform = 3, .encoding = 1, .table = bmp }, .{ .encoding = 4, .table = ten } }
        else
            &[_]fixture.Record{ .{ .encoding = 4, .table = ten }, .{ .platform = 3, .encoding = 1, .table = bmp } };
        const table = try fixture.join(a, records);
        defer a.free(table);
        try std.testing.expectEqual(@as(u16, 4), cmap.scalarSubtable(table).?.format);
        try std.testing.expect(cmap.tableCovers(table, 'A'));
        try std.testing.expect(!cmap.tableCovers(table, 0x1f600));
    }
    const eight = try fixture.sample(a, 8);
    defer a.free(eight);
    const deprecated = try fixture.join(a, &.{ .{ .encoding = 2, .table = eight }, .{ .encoding = 3, .table = bmp } });
    defer a.free(deprecated);
    try std.testing.expectEqual(@as(u16, 4), cmap.scalarSubtable(deprecated).?.format);
    try std.testing.expect(!cmap.tableCovers(deprecated, 0x10400));
    const standard = try fixture.join(a, &.{ .{ .encoding = 4, .table = eight }, .{ .encoding = 3, .table = bmp } });
    defer a.free(standard);
    try std.testing.expectEqual(@as(u16, 8), cmap.scalarSubtable(standard).?.format);
    try std.testing.expect(cmap.tableCovers(standard, 0x10400));
    const thirteen = try @import("test_font.zig").buildTestCmap(a, &.{.{ .start = 'A', .end = 'A', .glyph = 0 }}, 13);
    defer a.free(thirteen);
    const legacy = try fixture.join(a, &.{ .{ .encoding = 6, .table = thirteen[12..] }, .{ .encoding = 3, .table = bmp } });
    defer a.free(legacy);
    try std.testing.expectEqual(@as(u16, 13), cmap.scalarSubtable(legacy).?.format);
    const unknown = try fixture.join(a, &.{ .{ .encoding = 6, .table = thirteen[12..] }, .{ .encoding = 3, .table = bmp }, .{ .encoding = 7, .table = ten } });
    defer a.free(unknown);
    try std.testing.expectEqual(@as(u16, 13), cmap.scalarSubtable(unknown).?.format); // rejected encoding does not trigger switch
    const mixed = try fixture.join(a, &.{ .{ .encoding = 6, .table = thirteen[12..] }, .{ .encoding = 3, .table = bmp }, .{ .encoding = 4, .table = ten } });
    defer a.free(mixed);
    try std.testing.expectEqual(@as(u16, 4), cmap.scalarSubtable(mixed).?.format);
    try std.testing.expect(cmap.tableCovers(mixed, 'A'));
}
