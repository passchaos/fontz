const std = @import("std");
const cmap = @import("cmap.zig");
const fixture = @import("test_variation.zig");
const a = std.testing.allocator;

test "variation sequence cmap14 default nondefault and all selector ranges are authoritative" {
    const table = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{
        .{ .selector = 0xfe00, .mappings = &.{.{ .base = 0x4e2d }} },
        .{ .selector = 0xfe0d, .mappings = &.{.{ .base = 0x4e00 }} },
        .{ .selector = 0xfe0e, .defaults = &.{.{ .start = 0x2764 }} },
        .{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} },
        .{ .selector = 0xe0100, .mappings = &.{.{ .base = 0x4e2d }} },
        .{ .selector = 0xe01ef, .mappings = &.{.{ .base = 0x20000 }} },
    });
    defer a.free(table);
    for ([_]struct { base: u21, selector: u21 }{
        .{ .base = 0x4e2d, .selector = 0xfe00 },
        .{ .base = 0x4e00, .selector = 0xfe0d },
        .{ .base = 0x2764, .selector = 0xfe0e },
        .{ .base = 0x2764, .selector = 0xfe0f },
        .{ .base = 0x4e2d, .selector = 0xe0100 },
        .{ .base = 0x20000, .selector = 0xe01ef },
    }) |case| try std.testing.expect(cmap.tableCoversVariationSequence(table, case.base, case.selector, 128));
    try std.testing.expect(!cmap.tableCovers(table, 0x4e2d));
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x4e2d, 0xfe0d, 128));
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xe0101, 128));
    for ([_]u21{ 0xfe10, 0xdead, 0xe00ff, 0xe01f0, 0x110000 }) |selector|
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, selector, 128));
    for ([_]u21{ 0xd800, 0xdfff, 0x110000 }) |base|
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, base, 0xfe0f, 128));
}

test "variation sequence cmap14 default lacks nominal and invalid nominal glyph bounds fail closed" {
    const without_base = try fixture.buildCmap(a, &.{}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(without_base);
    try std.testing.expect(!cmap.tableCoversVariationSequence(without_base, 0x2764, 0xfe0f, 128));
    for ([_]u32{ 0, 128, 0x10000 }) |glyph| {
        const table = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764, .glyph = glyph }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
        defer a.free(table);
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    }
    const truncated_nominal = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(truncated_nominal);
    // An apparent glyph beyond format 12's declared body is not nominal proof.
    std.mem.writeInt(u32, truncated_nominal[24..28], 16, .big);
    try std.testing.expect(!cmap.tableCoversVariationSequence(truncated_nominal, 0x2764, 0xfe0f, 128));
    const nonunicode_nominal = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(nonunicode_nominal);
    std.mem.writeInt(u16, nonunicode_nominal[4..6], 1, .big);
    std.mem.writeInt(u16, nonunicode_nominal[6..8], 0, .big);
    // Keep legacy scalar preference, but a non-Unicode encoding cannot prove
    // the nominal mapping needed by a default Unicode variation sequence.
    try std.testing.expect(cmap.tableCovers(nonunicode_nominal, 0x2764));
    try std.testing.expect(!cmap.tableCoversVariationSequence(nonunicode_nominal, 0x2764, 0xfe0f, 128));
}

test "variation sequence cmap14 malformed default rows never prove eligibility" {
    for ([_][]const fixture.Range{
        &.{ .{ .start = 0x2764 }, .{ .start = 0x2764 } },
        &.{ .{ .start = 0x2764 }, .{ .start = 0x2000 } },
        &.{.{ .start = 0xd7ff, .additional = 2 }},
        &.{.{ .start = 0x10ffff, .additional = 1 }},
        &.{.{ .start = 0xd800 }},
    }) |ranges| {
        const table = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = ranges }});
        defer a.free(table);
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    }
    const table = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }} }});
    defer a.free(table);
    const offset = std.mem.readInt(u32, table[16..20], .big);
    // Count exceeds the declared subtable, even though the first row matches.
    std.mem.writeInt(u32, table[offset + 21 ..][0..4], 2, .big);
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    std.mem.writeInt(u32, table[offset + 13 ..][0..4], 10, .big);
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
}

test "variation sequence cmap14 malformed nondefault glyph rows fail closed" {
    for ([_][]const fixture.Mapping{
        &.{.{ .base = 0x2764, .glyph = 0 }},
        &.{.{ .base = 0x2764, .glyph = 128 }},
        &.{ .{ .base = 0x2764 }, .{ .base = 0x2764 } },
        &.{ .{ .base = 0x2764 }, .{ .base = 0x2000 } },
        &.{ .{ .base = 0x2764 }, .{ .base = 0xd800 } },
        &.{ .{ .base = 0x2764 }, .{ .base = 0x110000 } },
        &.{ .{ .base = 0x2764 }, .{ .base = 0x4e2d, .glyph = 128 } },
    }) |mappings| {
        const table = try fixture.buildCmap(a, &.{}, &.{.{ .selector = 0xfe0f, .mappings = mappings }});
        defer a.free(table);
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    }
    const table = try fixture.buildCmap(a, &.{}, &.{.{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} }});
    defer a.free(table);
    std.mem.writeInt(u32, table[12 + 21 ..][0..4], 2, .big);
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    std.mem.writeInt(u32, table[12 + 17 ..][0..4], std.math.maxInt(u32), .big);
    try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
}

test "variation sequence cmap14 rejects malformed lengths selector order and overlapping sets" {
    const overlap = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{.{ .start = 0x2764 }}, .mappings = &.{.{ .base = 0x2764 }} }});
    defer a.free(overlap);
    try std.testing.expect(!cmap.tableCoversVariationSequence(overlap, 0x2764, 0xfe0f, 128));
    const other_overlap = try fixture.buildCmap(a, &.{.{ .start = 0x2764, .end = 0x2764 }}, &.{.{ .selector = 0xfe0f, .defaults = &.{ .{ .start = 0x2764 }, .{ .start = 0x4e2d } }, .mappings = &.{.{ .base = 0x4e2d }} }});
    defer a.free(other_overlap);
    try std.testing.expect(!cmap.tableCoversVariationSequence(other_overlap, 0x2764, 0xfe0f, 128));
    for ([_][]const fixture.Selector{
        &.{ .{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} }, .{ .selector = 0xfe0f } },
        &.{ .{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} }, .{ .selector = 0xfe00 } },
        &.{ .{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} }, .{ .selector = 0xfe10 } },
    }) |selectors| {
        const table = try fixture.buildCmap(a, &.{}, selectors);
        defer a.free(table);
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    }
    const table = try fixture.buildCmap(a, &.{}, &.{.{ .selector = 0xfe0f, .mappings = &.{.{ .base = 0x2764 }} }});
    defer a.free(table);
    for ([_]u32{ 0, 9, 20, 1000, std.math.maxInt(u32) }) |length| {
        std.mem.writeInt(u32, table[14..18], length, .big);
        try std.testing.expect(!cmap.tableCoversVariationSequence(table, 0x2764, 0xfe0f, 128));
    }
}
