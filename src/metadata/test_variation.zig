//! Shared synthetic cmap 14 fixtures, with optional nominal format 12.
const std = @import("std");
const font = @import("test_font.zig");

pub const Range = struct { start: u21, additional: u8 = 0 };
pub const Mapping = struct { base: u21, glyph: u16 = 2 };
pub const Selector = struct {
    selector: u21,
    defaults: []const Range = &.{},
    mappings: []const Mapping = &.{},
};

pub fn buildFont(allocator: std.mem.Allocator, options: font.TestFontOptions, nominal: []const font.TestCoverageGroup, selectors: []const Selector) ![]u8 {
    const table = try buildCmap(allocator, nominal, selectors);
    defer allocator.free(table);
    var opts = options;
    opts.cmap = table;
    opts.num_glyphs = options.num_glyphs orelse 128;
    return font.buildTestFont(allocator, opts);
}

pub fn buildCmap(allocator: std.mem.Allocator, nominal: []const font.TestCoverageGroup, selectors: []const Selector) ![]u8 {
    const base = if (nominal.len != 0) try font.buildTestCmap(allocator, nominal, 12) else null;
    defer if (base) |bytes| allocator.free(bytes);
    const count: usize = if (base != null) 2 else 1;
    const nominal_len: usize = if (base) |bytes| bytes.len - 12 else 0;
    const variation_offset = 4 + count * 8 + nominal_len;
    var variation_len: usize = 10 + selectors.len * 11;
    for (selectors) |selector| {
        if (selector.defaults.len != 0) variation_len += 4 + selector.defaults.len * 4;
        if (selector.mappings.len != 0) variation_len += 4 + selector.mappings.len * 5;
    }
    const bytes = try allocator.alloc(u8, variation_offset + variation_len);
    @memset(bytes, 0);
    std.mem.writeInt(u16, bytes[2..4], @intCast(count), .big);
    var record: usize = 4;
    if (base) |table| {
        std.mem.writeInt(u16, bytes[record..][0..2], 3, .big);
        std.mem.writeInt(u16, bytes[record + 2 ..][0..2], 10, .big);
        std.mem.writeInt(u32, bytes[record + 4 ..][0..4], @intCast(4 + count * 8), .big);
        @memcpy(bytes[4 + count * 8 ..][0..nominal_len], table[12..]);
        record += 8;
    }
    std.mem.writeInt(u16, bytes[record..][0..2], 0, .big);
    std.mem.writeInt(u16, bytes[record + 2 ..][0..2], 5, .big);
    std.mem.writeInt(u32, bytes[record + 4 ..][0..4], @intCast(variation_offset), .big);
    const table = bytes[variation_offset..];
    std.mem.writeInt(u16, table[0..2], 14, .big);
    std.mem.writeInt(u32, table[2..6], @intCast(variation_len), .big);
    std.mem.writeInt(u32, table[6..10], @intCast(selectors.len), .big);
    var offset: usize = 10 + selectors.len * 11;
    for (selectors, 0..) |selector, i| {
        const row = table[10 + i * 11 ..][0..11];
        writeU24(row[0..3], selector.selector);
        if (selector.defaults.len != 0) {
            std.mem.writeInt(u32, row[3..7], @intCast(offset), .big);
            std.mem.writeInt(u32, table[offset..][0..4], @intCast(selector.defaults.len), .big);
            offset += 4;
            for (selector.defaults) |range| {
                writeU24(table[offset..][0..3], range.start);
                table[offset + 3] = range.additional;
                offset += 4;
            }
        }
        if (selector.mappings.len != 0) {
            std.mem.writeInt(u32, row[7..11], @intCast(offset), .big);
            std.mem.writeInt(u32, table[offset..][0..4], @intCast(selector.mappings.len), .big);
            offset += 4;
            for (selector.mappings) |mapping| {
                writeU24(table[offset..][0..3], mapping.base);
                std.mem.writeInt(u16, table[offset + 3 ..][0..2], mapping.glyph, .big);
                offset += 5;
            }
        }
    }
    return bytes;
}

pub fn writeU24(bytes: []u8, value: u21) void {
    bytes[0] = @intCast(value >> 16);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value);
}
