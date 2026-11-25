//! Independent byte fixtures for Unicode format2/8/10 and default UVS tests.
const std = @import("std");
const font = @import("test_font.zig");
const variations = @import("test_variation.zig");

pub const Subheader = struct { high: u8, first: u8, glyphs: []const u16, delta: i16 = 0 };

pub fn buildFormat2(a: std.mem.Allocator, headers: []const Subheader) ![]u8 {
    var extra: usize = 0;
    var has_single = false;
    for (headers) |header| {
        extra += header.glyphs.len * 2;
        has_single = has_single or header.high == 0;
    }
    const count = headers.len + @as(usize, @intFromBool(!has_single));
    const data = try a.alloc(u8, 518 + count * 8 + extra);
    @memset(data, 0);
    put16(data, 0, 2);
    put16(data, 2, @intCast(data.len));
    var next: usize = 1;
    var glyph_offset = 518 + count * 8;
    for (headers) |header| {
        const index = if (header.high == 0) 0 else blk: {
            const i = next;
            next += 1;
            break :blk i;
        };
        put16(data, 6 + @as(usize, header.high) * 2, @intCast(index * 8));
        const row = 518 + index * 8;
        put16(data, row, header.first);
        put16(data, row + 2, @intCast(header.glyphs.len));
        put16(data, row + 4, @bitCast(header.delta));
        put16(data, row + 6, @intCast(glyph_offset - (row + 6)));
        for (header.glyphs) |glyph| {
            put16(data, glyph_offset, glyph);
            glyph_offset += 2;
        }
    }
    return data;
}

pub fn buildFormat8(a: std.mem.Allocator, groups: []const font.TestCoverageGroup) ![]u8 {
    const data = try a.alloc(u8, 8208 + groups.len * 12);
    @memset(data, 0);
    put16(data, 0, 8);
    put32(data, 4, @intCast(data.len));
    put32(data, 8204, @intCast(groups.len));
    for (groups, 0..) |group, i| {
        const row = 8208 + i * 12;
        put32(data, row, group.start);
        put32(data, row + 4, group.end);
        put32(data, row + 8, group.glyph);
        if (group.end > 0xffff) {
            var word = @max(group.start, 0x10000) >> 16;
            while (word <= (group.end >> 16)) : (word += 1) data[12 + word / 8] |= @as(u8, 0x80) >> @intCast(word & 7);
        }
    }
    return data;
}

pub fn buildFormat10(a: std.mem.Allocator, first: u32, glyphs: []const u16) ![]u8 {
    const data = try a.alloc(u8, 20 + glyphs.len * 2);
    @memset(data, 0);
    put16(data, 0, 10);
    put32(data, 4, @intCast(data.len));
    put32(data, 12, first);
    put32(data, 16, @intCast(glyphs.len));
    for (glyphs, 0..) |glyph, i| put16(data, 20 + i * 2, glyph);
    return data;
}

pub fn wrap(a: std.mem.Allocator, subtable: []const u8, platform: u16, record_encoding: u16) ![]u8 {
    const data = try a.alloc(u8, 12 + subtable.len);
    @memset(data, 0);
    put16(data, 2, 1);
    put16(data, 4, platform);
    put16(data, 6, record_encoding);
    put32(data, 8, 12);
    @memcpy(data[12..], subtable);
    return data;
}

pub fn withVariation(a: std.mem.Allocator, subtable: []const u8, record_encoding: u16, base_scalar: u21, nondefault: bool) ![]u8 {
    const selectors = [_]variations.Selector{.{
        .selector = 0xfe0f,
        .defaults = if (nondefault) &.{} else &.{.{ .start = base_scalar }},
        .mappings = if (nondefault) &.{.{ .base = base_scalar, .glyph = 2 }} else &.{},
    }};
    const variation = try variations.buildCmap(a, &.{}, &selectors);
    defer a.free(variation);
    const data = try a.alloc(u8, 20 + subtable.len + variation.len - 12);
    @memset(data, 0);
    put16(data, 2, 2);
    put16(data, 6, record_encoding);
    put32(data, 8, 20);
    put16(data, 14, 5);
    put32(data, 16, @intCast(20 + subtable.len));
    @memcpy(data[20..][0..subtable.len], subtable);
    @memcpy(data[20 + subtable.len ..], variation[12..]);
    return data;
}

pub fn sample(a: std.mem.Allocator, format: u16) ![]u8 {
    return switch (format) {
        2 => buildFormat2(a, &.{.{ .high = 1, .first = 2, .glyphs = &.{3} }}),
        8 => buildFormat8(a, &.{ .{ .start = 'A', .end = 'A', .glyph = 1 }, .{ .start = 0x10400, .end = 0x10400, .glyph = 3 } }),
        10 => buildFormat10(a, 0x1f600, &.{ 1, 0, 3 }),
        else => unreachable,
    };
}
pub fn base(format: u16) u21 {
    return switch (format) {
        2 => 0x0102,
        8 => 0x10400,
        10 => 0x1f600,
        else => unreachable,
    };
}
pub fn encoding(format: u16) u16 {
    return if (format == 2) 2 else 4;
}
pub fn put16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .big);
}
pub fn put32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .big);
}

pub const Record = struct { platform: u16 = 0, encoding: u16, table: []const u8 };
pub fn join(a: std.mem.Allocator, records: []const Record) ![]u8 {
    var length: usize = 4 + records.len * 8;
    for (records) |record| length += record.table.len;
    const data = try a.alloc(u8, length);
    @memset(data, 0);
    put16(data, 2, @intCast(records.len));
    var offset = 4 + records.len * 8;
    for (records, 0..) |record, i| {
        const row = 4 + i * 8;
        put16(data, row, record.platform);
        put16(data, row + 2, record.encoding);
        put32(data, row + 4, @intCast(offset));
        @memcpy(data[offset..][0..record.table.len], record.table);
        offset += record.table.len;
    }
    return data;
}

pub fn buildBmp4(a: std.mem.Allocator, scalar: u16, glyph: u16) ![]u8 {
    const data = try a.alloc(u8, 32);
    @memset(data, 0);
    put16(data, 0, 4);
    put16(data, 2, 32);
    put16(data, 6, 4);
    put16(data, 8, 4);
    put16(data, 10, 1);
    put16(data, 14, scalar);
    put16(data, 16, 0xffff);
    put16(data, 20, scalar);
    put16(data, 22, 0xffff);
    put16(data, 24, glyph -% scalar);
    put16(data, 26, 1);
    return data;
}
