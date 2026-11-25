//! Bounds and scalar/glyph contracts for the newly supported numeric formats.
const std = @import("std");
const unicode = @import("../../variation.zig");

pub fn u16At(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}
pub fn u32At(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
pub fn scalarRange(first: u32, last: u32) bool {
    return first <= last and last <= 0x10ffff and (last < 0xd800 or first > 0xdfff);
}
pub fn glyphValid(glyph: u32, count: ?u16) bool {
    if (glyph > std.math.maxInt(u16)) return false;
    return if (count) |limit| limit != 0 and glyph < limit else true;
}
pub fn declared(bytes: []const u8, format: u16) ?[]const u8 {
    if (bytes.len < 6 or u16At(bytes, 0) != format) return null;
    const length: usize = if (format == 2) u16At(bytes, 2) else blk: {
        if (bytes.len < 12 or u16At(bytes, 2) != 0 or u32At(bytes, 8) != 0) return null;
        break :blk u32At(bytes, 4);
    };
    if (length > bytes.len or length < (if (format == 2) @as(usize, 526) else if (format == 8) @as(usize, 8208) else @as(usize, 20))) return null;
    if (format == 2 and u16At(bytes, 4) != 0) return null;
    return bytes[0..length];
}
pub fn scalar(cp: u21) bool {
    return unicode.isScalar(cp);
}
