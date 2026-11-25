//! Unicode mixed-byte format2, including the single-byte SubHeader[0].
const common = @import("common.zig");
const keys = 6;
const subheaders = 518;

pub fn validate(table: []const u8, count: ?u16) bool {
    var max_index: usize = 0;
    for (0..256) |high| {
        const key = common.u16At(table, keys + high * 2);
        if ((key & 7) != 0) return false;
        max_index = @max(max_index, key / 8);
    }
    const glyph_start = subheaders + (max_index + 1) * 8;
    if (glyph_start > table.len) return false;
    for (0..max_index + 1) |index| {
        const row = subheaders + index * 8;
        const first = common.u16At(table, row);
        const entries = common.u16At(table, row + 2);
        if (entries == 0) continue;
        if (@as(u32, first) + entries - 1 > 0xff) return false;
        const range = common.u16At(table, row + 6);
        if ((range & 1) != 0) return false;
        const start = row + 6 + @as(usize, range);
        if (start < glyph_start or start > table.len or @as(usize, entries) * 2 > table.len - start) return false;
        for (0..256) |high| {
            if (common.u16At(table, keys + high * 2) / 8 != index) continue;
            if (index == 0 and high != 0) continue;
            const scalar_first: u32 = (@as(u32, @intCast(high)) << 8) | first;
            if (!common.scalarRange(scalar_first, scalar_first + entries - 1)) return false;
        }
        const delta = common.u16At(table, row + 4);
        // Validate every declared SubHeader's mappings, including unreferenced
        // gaps before the highest index, after applying signed wrapping delta.
        for (0..entries) |i| {
            const raw = common.u16At(table, start + i * 2);
            if (raw != 0 and !common.glyphValid(raw +% delta, count)) return false;
        }
    }
    return true;
}

pub fn glyph(table: []const u8, cp: u21) ?u32 {
    if (cp > 0xffff) return null;
    const high = cp >> 8;
    const index = common.u16At(table, keys + @as(usize, high) * 2) / 8;
    if (high != 0 and index == 0) return null;
    const row = subheaders + @as(usize, index) * 8;
    const first = common.u16At(table, row);
    const entries = common.u16At(table, row + 2);
    const low = cp & 0xff;
    if (low < first or low - first >= entries) return null;
    const address = row + 6 + @as(usize, common.u16At(table, row + 6)) + @as(usize, low - first) * 2;
    const raw = common.u16At(table, address);
    if (raw == 0) return null;
    const mapped = raw +% common.u16At(table, row + 4);
    return if (mapped != 0) mapped else null;
}
