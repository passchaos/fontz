//! Authoritative OpenType cmap 14 eligibility, independent of nominal cmap.
const std = @import("std");
const unicode = @import("../variation.zig");

pub const Mapping = union(enum) { unsupported, default, nondefault: u16 };

/// A malformed selector row never falls through to nominal coverage. Validate
/// both lists before accepting a matching base, including rows after it.
pub fn lookup(cmap: []const u8, base: u21, selector: u21, num_glyphs: u16) Mapping {
    if (!unicode.validCoverage(base, selector) or num_glyphs == 0 or cmap.len < 4 or u16At(cmap, 0) != 0) return .unsupported;
    const count = u16At(cmap, 2) orelse return .unsupported;
    if (count == 0 or count > 1024 or 4 + @as(usize, count) * 8 > cmap.len) return .unsupported;
    var found: ?[]const u8 = null;
    for (0..count) |i| {
        const record = 4 + i * 8;
        // Format 14 is defined exclusively for Unicode platform encoding 5.
        if (u16At(cmap, record) != 0 or u16At(cmap, record + 2) != 5) continue;
        const offset = u32At(cmap, record + 4) orelse return .unsupported;
        if (offset < 4 + @as(usize, count) * 8 or offset > cmap.len or cmap.len - offset < 10) return .unsupported;
        const table = cmap[offset..];
        if (u16At(table, 0) != 14) continue;
        if (found != null) return .unsupported;
        found = table;
    }
    const bytes = found orelse return .unsupported;
    const length = u32At(bytes, 2) orelse return .unsupported;
    if (length < 10 or length > bytes.len) return .unsupported;
    const table = bytes[0..length];
    const rows = u32At(table, 6) orelse return .unsupported;
    if (@as(u64, rows) * 11 > table.len - 10) return .unsupported;
    const records_end: usize = 10 + @as(usize, rows) * 11;
    var previous: ?u32 = null;
    var selected: ?usize = null;
    for (0..rows) |i| {
        const row = 10 + i * 11;
        const value = u24At(table, row) orelse return .unsupported;
        if (value > 0x10ffff or !unicode.isSelector(@intCast(value))) return .unsupported;
        if (previous) |prev| if (value <= prev) return .unsupported;
        previous = value;
        if (value == selector) selected = row;
    }
    const row = selected orelse return .unsupported;
    const defaults = u32At(table, row + 3) orelse return .unsupported;
    const nondefaults = u32At(table, row + 7) orelse return .unsupported;
    const default_match = defaultContains(table, defaults, records_end, base) orelse return .unsupported;
    const nondefault_match = nondefaultGlyph(table, nondefaults, records_end, base, num_glyphs) orelse return .unsupported;
    if (!disjointLists(table, defaults, nondefaults)) return .unsupported;
    // The two sets must be disjoint for this sequence.
    if (nondefault_match != 0) {
        if (default_match) return .unsupported;
        return .{ .nondefault = nondefault_match };
    }
    return if (default_match) .default else .unsupported;
}

/// The format requires separate storage and disjoint Unicode sets, including
/// mappings other than the requested sequence. Called after list validation.
fn disjointLists(table: []const u8, defaults: u32, nondefaults: u32) bool {
    if (defaults == 0 or nondefaults == 0) return true;
    const range_count = u32At(table, defaults).?;
    const mapping_count = u32At(table, nondefaults).?;
    const range_end = @as(usize, defaults) + 4 + @as(usize, range_count) * 4;
    const mapping_end = @as(usize, nondefaults) + 4 + @as(usize, mapping_count) * 5;
    if (defaults < mapping_end and nondefaults < range_end) return false;
    var range: usize = 0;
    for (0..mapping_count) |i| {
        const value = u24At(table, @as(usize, nondefaults) + 4 + i * 5).?;
        while (range < range_count) : (range += 1) {
            const row = @as(usize, defaults) + 4 + range * 4;
            const first = u24At(table, row).?;
            const last = first + table[row + 3];
            if (value > last) continue;
            if (value >= first) return false;
            break;
        }
    }
    return true;
}

fn defaultContains(table: []const u8, offset: u32, records_end: usize, base: u21) ?bool {
    if (offset == 0) return false;
    if (offset < records_end) return null;
    const count = u32At(table, offset) orelse return null;
    const start = @as(usize, offset) + 4;
    if (@as(u64, count) * 4 > table.len - start) return null;
    var previous_end: ?u32 = null;
    var matches = false;
    for (0..count) |i| {
        const row = start + i * 4;
        const first = u24At(table, row) orelse return null;
        const last = first + table[row + 3];
        if (!scalarRange(first, last)) return null;
        if (previous_end) |previous| if (first <= previous) return null;
        previous_end = last;
        if (base >= first and base <= last) matches = true;
    }
    return matches;
}

/// Zero means absent; null means malformed. Even an unrelated invalid glyph
/// cannot be used as proof that this selector's mapping table is trustworthy.
fn nondefaultGlyph(table: []const u8, offset: u32, records_end: usize, base: u21, num_glyphs: u16) ?u16 {
    if (offset == 0) return 0;
    if (offset < records_end) return null;
    const count = u32At(table, offset) orelse return null;
    const start = @as(usize, offset) + 4;
    if (@as(u64, count) * 5 > table.len - start) return null;
    var previous: ?u32 = null;
    var glyph: u16 = 0;
    for (0..count) |i| {
        const row = start + i * 5;
        const value = u24At(table, row) orelse return null;
        if (!scalarRange(value, value)) return null;
        if (previous) |prev| if (value <= prev) return null;
        previous = value;
        const mapped = u16At(table, row + 3) orelse return null;
        if (mapped == 0 or mapped >= num_glyphs) return null;
        if (value == base) glyph = mapped;
    }
    return glyph;
}

fn scalarRange(first: u32, last: u32) bool {
    return first <= last and last <= 0x10ffff and (last < 0xd800 or first > 0xdfff);
}

fn u16At(bytes: []const u8, offset: usize) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn u24At(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 3) return null;
    return @as(u32, bytes[offset]) << 16 | @as(u32, bytes[offset + 1]) << 8 | bytes[offset + 2];
}

fn u32At(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
