//! New numeric cmap formats have explicit Unicode and full-subtable contracts.
const common = @import("cmap_numeric/common.zig");
const format2 = @import("cmap_numeric/format2.zig");
const format8 = @import("cmap_numeric/format8.zig");
const format10 = @import("cmap_numeric/format10.zig");

const policy = @import("cmap_policy.zig");
pub const isFormat = policy.isExtended;
pub const unicodeRecord = policy.eligibleExtended;
pub fn validate(bytes: []const u8, format: u16, count: ?u16) bool {
    if (count) |limit| if (limit == 0) return false;
    const table = common.declared(bytes, format) orelse return false;
    return switch (format) {
        2 => format2.validate(table, count),
        8 => format8.validate(table, count),
        10 => format10.validate(table, count),
        else => false,
    };
}
pub fn glyph(bytes: []const u8, format: u16, cp: u21, count: ?u16) ?u32 {
    if (!common.scalar(cp) or !validate(bytes, format, count)) return null;
    return glyphValidated(bytes, format, cp);
}

/// The caller retains immutable bytes whose full grammar/glyph domain was proven.
pub fn glyphValidated(bytes: []const u8, format: u16, cp: u21) ?u32 {
    if (!common.scalar(cp)) return null;
    const table = common.declared(bytes, format) orelse return null;
    return switch (format) {
        2 => format2.glyph(table, cp),
        8 => format8.glyph(table, cp),
        10 => format10.glyph(table, cp),
        else => null,
    };
}

/// Qualify all standard eligible extended records, including unselected siblings.
/// Unknown encodings are skipped rather than tainting registered records.
pub fn validateContext(comptime counted: bool, bytes: []const u8, count: ?u16, work: anytype) bool {
    if (bytes.len < 4 or common.u16At(bytes, 0) != 0) return false;
    const records = common.u16At(bytes, 2);
    const header_end = 4 + @as(usize, records) * 8;
    if (records == 0 or records > 1024 or header_end > bytes.len) return false;
    for (0..records) |i| {
        const row = 4 + i * 8;
        const offset = common.u32At(bytes, row + 4);
        if (offset < header_end or @as(u64, offset) + 2 > bytes.len) continue;
        const format = common.u16At(bytes, offset);
        if (!unicodeRecord(common.u16At(bytes, row), common.u16At(bytes, row + 2), format)) continue;
        if (counted) work.?.new_subtable_validations += 1;
        if (!validate(bytes[offset..], format, count)) return false;
    }
    return true;
}
