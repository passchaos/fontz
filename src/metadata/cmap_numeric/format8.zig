//! Cangjie-compatible format8: groups contain Unicode scalars, not packed UTF16.
const common = @import("common.zig");
pub const groups_offset = 8208;

fn is32(table: []const u8, word: u16) bool {
    return (table[12 + @as(usize, word) / 8] & (@as(u8, 0x80) >> @intCast(word & 7))) != 0;
}
pub fn validate(table: []const u8, count: ?u16) bool {
    const groups = common.u32At(table, 8204);
    if (@as(u64, groups) * 12 != table.len - groups_offset) return false;
    var previous: ?u32 = null;
    for (0..groups) |i| {
        const row = groups_offset + i * 12;
        const first = common.u32At(table, row);
        const last = common.u32At(table, row + 4);
        if (!common.scalarRange(first, last)) return false;
        if (previous) |end| if (first <= end) return false;
        previous = last;
        if (first <= 0xffff) {
            var word = first;
            while (word <= @min(last, 0xffff)) : (word += 1) if (is32(table, @intCast(word))) return false;
        }
        if (last > 0xffff) {
            var word = @max(first, 0x10000) >> 16;
            while (word <= last >> 16) : (word += 1) if (!is32(table, @intCast(word))) return false;
        }
        const start_glyph = common.u32At(table, row + 8);
        const span = last - first;
        if (start_glyph > 0xffffffff - span or !common.glyphValid(start_glyph + span, count)) return false;
    }
    return true;
}
pub fn glyph(table: []const u8, cp: u21) ?u32 {
    var lo: usize = 0;
    var hi: usize = common.u32At(table, 8204);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const row = groups_offset + mid * 12;
        const first = common.u32At(table, row);
        const last = common.u32At(table, row + 4);
        if (cp < first) hi = mid else if (cp > last) lo = mid + 1 else {
            const mapped = common.u32At(table, row + 8) + @as(u32, cp) - first;
            return if (mapped != 0) mapped else null;
        }
    }
    return null;
}
