//! Full-repertoire trimmed array with complete range and glyph-domain proof.
const common = @import("common.zig");

pub fn validate(table: []const u8, count: ?u16) bool {
    const first = common.u32At(table, 12);
    const entries = common.u32At(table, 16);
    if (!common.scalarRange(first, first)) return false;
    if (@as(u64, entries) * 2 != table.len - 20) return false;
    if (entries == 0) return true;
    const last = @as(u64, first) + entries - 1;
    if (last > 0xffffffff or !common.scalarRange(first, @intCast(last))) return false;
    for (0..entries) |i| if (!common.glyphValid(common.u16At(table, 20 + i * 2), count)) return false;
    return true;
}
pub fn glyph(table: []const u8, cp: u21) ?u32 {
    const first = common.u32At(table, 12);
    const entries = common.u32At(table, 16);
    if (cp < first or cp - first >= entries) return null;
    const mapped = common.u16At(table, 20 + @as(usize, cp - first) * 2);
    return if (mapped != 0) mapped else null;
}
