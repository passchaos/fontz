//! An inline retained-table plan; group bytes remain owned by coverage cache.
const std = @import("std");
const cmap = @import("cmap.zig");
const unicode = @import("../variation.zig");

pub const Order = enum { unprepared, fallback, ordered };
pub const Plan = struct {
    offset: u32 = 0,
    group_count: u32 = 0,
    format: u16 = 0,
    order: Order = .unprepared,

    pub fn covers(self: Plan, comptime counted: bool, bytes: []const u8, cp: u21, work: ?*cmap.WorkStats) bool {
        if (self.order != .ordered) return if (counted) cmap.tableCoversCounted(bytes, cp, work.?) else cmap.tableCovers(bytes, cp);
        if (!unicode.isScalar(cp)) return false;
        if (counted) work.?.binary_queries += 1;
        var lo: usize = 0;
        var hi: usize = self.group_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const row = @as(usize, self.offset) + 16 + mid * 12;
            if (counted) work.?.group_visits += 1;
            const start = u32At(bytes, row);
            const end = u32At(bytes, row + 4);
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                const first_glyph = u32At(bytes, row + 8);
                // Preserve legacy nominal glyph arithmetic, including max-u32
                // success at the first codepoint and overflow on the next.
                const glyph = if (self.format == 13) first_glyph else std.math.add(u32, first_glyph, @as(u32, cp) - start) catch return false;
                return glyph != 0;
            }
        }
        return false;
    }
};

pub fn prepare(comptime counted: bool, bytes: []const u8, work: ?*cmap.WorkStats) Plan {
    const selected = (if (counted) cmap.scalarSubtableCounted(bytes, work.?) else cmap.scalarSubtable(bytes)) orelse return .{ .order = .fallback };
    var plan = Plan{ .offset = selected.offset, .format = selected.format, .order = .fallback };
    if (selected.format != 12 and selected.format != 13) return plan;
    const table = bytes[selected.offset..];
    if (table.len < 16) return plan;
    const count = u32At(table, 12);
    plan.group_count = count;
    // Nominal lookup historically ignores the subtable's declared length.
    if (count == 0 or count > 1_000_000 or @as(u64, count) * 12 > table.len - 16) return plan;
    var previous_end: ?u32 = null;
    for (0..count) |i| {
        if (counted) work.?.preparation_visits += 1;
        const row = 16 + i * 12;
        const start = u32At(table, row);
        const end = u32At(table, row + 4);
        if (start > end) return plan;
        if (previous_end) |previous| if (start <= previous) return plan;
        previous_end = end;
    }
    plan.order = .ordered;
    return plan;
}

fn u32At(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
