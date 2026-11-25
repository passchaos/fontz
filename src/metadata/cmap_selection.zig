//! Shared nominal selection; new formats require explicit Unicode identity.
const std = @import("std");
const policy = @import("cmap_policy.zig");

pub const WorkStats = struct {
    encoding_records: u64 = 0,
    group_visits: u64 = 0,
    preparation_visits: u64 = 0,
    binary_queries: u64 = 0,
    linear_queries: u64 = 0,
    new_subtable_validations: u64 = 0,
};

pub const Subtable = struct { offset: u32, format: u16 };

pub fn scalarSubtable(bytes: []const u8) ?Subtable {
    return selectSubtable(false, bytes, false, null);
}

pub fn scalarSubtableCounted(bytes: []const u8, work: *WorkStats) ?Subtable {
    return selectSubtable(true, bytes, false, work);
}

pub fn selectSubtable(comptime counted: bool, cmap: []const u8, strict_length: bool, work: ?*WorkStats) ?Subtable {
    if (cmap.len < 4) return null;
    if (strict_length and readU16(cmap, 0) != 0) return null;
    const count = readU16(cmap, 2) orelse return null;
    if (count == 0 or count > 1024) return null;
    if (cmap.len < 4 + @as(usize, count) * 8) return null;

    const mixed = hasExtendedContext(cmap);
    var best_offset: ?u32 = null;
    var best_score: u8 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (counted) work.?.encoding_records += 1;
        const record = 4 + index * 8;
        const platform = readU16(cmap, record) orelse continue;
        const encoding = readU16(cmap, record + 2) orelse continue;
        if (strict_length and !(platform == 0 and encoding <= 6 and encoding != 5) and
            !(platform == 3 and (encoding == 1 or encoding == 10))) continue;
        const offset = readU32(cmap, record + 4) orelse continue;
        if (strict_length and offset < 4 + @as(usize, count) * 8) return null;
        if (@as(u64, offset) + 2 > cmap.len) continue;
        const format = readU16(cmap, offset) orelse continue;
        if (policy.isExtended(format)) {
            if (readU16(cmap, 0) != 0 or offset < 4 + @as(usize, count) * 8) continue;
        }
        if (policy.isExtended(format) and !policy.eligibleExtended(platform, encoding, format)) continue;
        const score = if (mixed)
            policy.mixedScore(platform, encoding, format) orelse continue
        else
            policy.legacyScore(platform, encoding, format);
        if ((mixed and best_offset == null) or score > best_score) {
            best_score = score;
            best_offset = offset;
        }
    }
    const offset = best_offset orelse return null;
    const format = readU16(cmap, offset) orelse return null;
    return .{ .offset = offset, .format = format };
}

/// The switch depends on standard record identity, not a query or glyph hit.
/// Malformed bodies still trigger the mixed context and must fail qualification.
pub fn hasExtendedContext(cmap: []const u8) bool {
    if (cmap.len < 4 or readU16(cmap, 0) != 0) return false;
    const count = readU16(cmap, 2) orelse return false;
    if (count == 0 or count > 1024 or 4 + @as(usize, count) * 8 > cmap.len) return false;
    for (0..count) |i| {
        const row = 4 + i * 8;
        const offset = readU32(cmap, row + 4) orelse continue;
        if (offset < 4 + @as(usize, count) * 8 or @as(u64, offset) + 2 > cmap.len) continue;
        const format = readU16(cmap, offset) orelse continue;
        if (policy.eligibleExtended(readU16(cmap, row).?, readU16(cmap, row + 2).?, format)) return true;
    }
    return false;
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}
fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
