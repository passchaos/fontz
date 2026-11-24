//! Minimal pure-Zig sfnt `cmap` coverage reader.
//!
//! Supports the common Unicode subtables: format 4 (BMP), format 12/13
//! (full repertoire), format 6, format 0 and variation sequences (format 14).
//! Used by the pure-Zig discovery
//! provider to prove that a candidate actually covers a codepoint.

const std = @import("std");

const file_reader = @import("cmap_io.zig");
const unicode = @import("../variation.zig");
const variation = @import("cmap_variation.zig");
pub const max_cmap_bytes = file_reader.max_cmap_bytes;
pub const ReadStats = file_reader.ReadStats;
pub const readTable = file_reader.readTable;
pub const readCoverageData = file_reader.readCoverageData;
pub const readGlyphCount = file_reader.readGlyphCount;

pub fn coversCodepoint(io: std.Io, path: []const u8, face_index: u32, codepoint: u21) !bool {
    if (!unicode.isScalar(codepoint)) return false;
    const table = (try readTable(io, std.heap.page_allocator, path, face_index, null)) orelse return false;
    defer std.heap.page_allocator.free(table);
    return tableCovers(table, codepoint);
}

pub fn coversVariationSequence(io: std.Io, path: []const u8, face_index: u32, base: u21, selector: u21) !bool {
    if (!unicode.validCoverage(base, selector)) return false;
    const data = try readCoverageData(io, std.heap.page_allocator, path, face_index, true, null);
    const table = data.table orelse return false;
    defer std.heap.page_allocator.free(table);
    return tableCoversVariationSequence(table, base, selector, data.num_glyphs orelse return false);
}

/// A nondefault mapping proves coverage independently of a nominal base glyph.
/// Default mappings also require an in-bounds glyph in the chosen Unicode cmap.
pub fn tableCoversVariationSequence(table: []const u8, base: u21, selector: u21, num_glyphs: u16) bool {
    return switch (variation.lookup(table, base, selector, num_glyphs)) {
        .unsupported => false,
        .nondefault => true,
        .default => if (tableGlyph(table, base, true)) |glyph| glyph < num_glyphs else false,
    };
}

comptime {
    _ = @import("variation_tests.zig");
}

/// Query retained table bytes with the same subtable preference and malformed
/// table handling as the uncached file reader.
pub fn tableCovers(cmap: []const u8, codepoint: u21) bool {
    return tableGlyph(cmap, codepoint, false) != null;
}

pub const WorkStats = struct {
    encoding_records: u64 = 0,
    group_visits: u64 = 0,
    preparation_visits: u64 = 0,
    binary_queries: u64 = 0,
    linear_queries: u64 = 0,
};

pub const Subtable = struct { offset: u32, format: u16 };

pub fn scalarSubtable(bytes: []const u8) ?Subtable {
    return selectSubtable(false, bytes, false, null);
}

pub fn scalarSubtableCounted(bytes: []const u8, work: *WorkStats) ?Subtable {
    return selectSubtable(true, bytes, false, work);
}

fn selectSubtable(comptime counted: bool, cmap: []const u8, strict_length: bool, work: ?*WorkStats) ?Subtable {
    if (cmap.len < 4) return null;
    if (strict_length and readU16(cmap, 0) != 0) return null;
    const count = readU16(cmap, 2) orelse return null;
    if (count == 0 or count > 1024) return null;
    if (cmap.len < 4 + @as(usize, count) * 8) return null;

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
        const score = subtableScore(platform, encoding, format);
        if (score > best_score) {
            best_score = score;
            best_offset = offset;
        }
    }
    const offset = best_offset orelse return null;
    const format = readU16(cmap, offset) orelse return null;
    return .{ .offset = offset, .format = format };
}

/// Opt-in test/workload counter. Production calls instantiate no counters.
pub fn tableCoversCounted(bytes: []const u8, codepoint: u21, work: *WorkStats) bool {
    return tableGlyphImpl(true, bytes, codepoint, false, work) != null;
}

fn tableGlyph(cmap: []const u8, codepoint: u21, strict_length: bool) ?u32 {
    return tableGlyphImpl(false, cmap, codepoint, strict_length, null);
}

fn tableGlyphImpl(comptime counted: bool, cmap: []const u8, codepoint: u21, strict_length: bool, work: ?*WorkStats) ?u32 {
    if (!unicode.isScalar(codepoint)) return null;
    const selected = selectSubtable(counted, cmap, strict_length, work) orelse return null;
    const offset = selected.offset;
    const format = selected.format;
    var subtable = cmap[offset..];
    if (strict_length) {
        // Nominal scalar queries retain their historical parser behavior.
        // A default UVS needs proof within the nominal subtable's own bounds.
        const length: usize = if (format == 12 or format == 13)
            readU32(subtable, 4) orelse return null
        else
            readU16(subtable, 2) orelse return null;
        if (length > subtable.len) return null;
        subtable = subtable[0..length];
    }
    return switch (format) {
        0 => format0Glyph(subtable, codepoint),
        4 => format4Glyph(subtable, codepoint),
        6 => format6Glyph(subtable, codepoint),
        12, 13 => format12GlyphImpl(counted, subtable, codepoint, format == 13, work),
        else => null,
    };
}

fn subtableScore(platform: u16, encoding: u16, format: u16) u8 {
    if (format == 12 or format == 13) {
        if (platform == 3 and encoding == 10) return 100;
        if (platform == 0 and (encoding == 4 or encoding == 6)) return 95;
        return 60;
    }
    if (format == 4) {
        if (platform == 3 and encoding == 1) return 80;
        if (platform == 0 and (encoding == 3 or encoding == 4)) return 75;
        return 40;
    }
    if (format == 6) return 30;
    if (format == 0) return 10;
    return 0;
}

fn format0Covers(subtable: []const u8, codepoint: u21) bool {
    return format0Glyph(subtable, codepoint) != null;
}

fn format0Glyph(subtable: []const u8, codepoint: u21) ?u32 {
    if (subtable.len < 6 + 256) return null;
    if (codepoint > 255) return null;
    return if (subtable[6 + codepoint] != 0) subtable[6 + codepoint] else null;
}

fn format4Covers(subtable: []const u8, codepoint: u21) bool {
    return format4Glyph(subtable, codepoint) != null;
}

fn format4Glyph(subtable: []const u8, codepoint: u21) ?u32 {
    if (subtable.len < 14 or codepoint > 0xffff) return null;
    const seg_count_x2 = readU16(subtable, 6) orelse return null;
    if (seg_count_x2 == 0 or (seg_count_x2 & 1) != 0) return null;
    const seg_count = @as(usize, seg_count_x2) / 2;
    const end_codes = 14;
    const start_codes = end_codes + seg_count * 2 + 2;
    const id_deltas = start_codes + seg_count * 2;
    const id_range_offsets = id_deltas + seg_count * 2;
    if (id_range_offsets + seg_count * 2 > subtable.len) return null;
    const cp: u16 = @intCast(codepoint);
    var index: usize = 0;
    while (index < seg_count) : (index += 1) {
        const end = readU16(subtable, end_codes + index * 2) orelse return null;
        if (cp > end) continue;
        const start = readU16(subtable, start_codes + index * 2) orelse return null;
        if (cp < start) return null;
        const delta = readI16(subtable, id_deltas + index * 2) orelse return null;
        const range_offset = readU16(subtable, id_range_offsets + index * 2) orelse return null;
        if (range_offset == 0) {
            const glyph = (cp +% @as(u16, @bitCast(delta))) & 0xffff;
            return if (glyph != 0) glyph else null;
        }
        const address = id_range_offsets + index * 2 + @as(usize, range_offset) +
            @as(usize, cp - start) * 2;
        if (address + 2 > subtable.len) return null;
        var glyph = readU16(subtable, address) orelse return null;
        if (glyph == 0) return null;
        glyph = (glyph +% @as(u16, @bitCast(delta))) & 0xffff;
        return if (glyph != 0) glyph else null;
    }
    return null;
}

fn format6Covers(subtable: []const u8, codepoint: u21) bool {
    return format6Glyph(subtable, codepoint) != null;
}

fn format6Glyph(subtable: []const u8, codepoint: u21) ?u32 {
    if (subtable.len < 10) return null;
    const first_code = readU16(subtable, 6) orelse return null;
    const entry_count = readU16(subtable, 8) orelse return null;
    if (codepoint < first_code or codepoint >= @as(u32, first_code) + entry_count) return null;
    const index: usize = @intCast(codepoint - first_code);
    if (10 + index * 2 + 2 > subtable.len) return null;
    const glyph = readU16(subtable, 10 + index * 2) orelse return null;
    return if (glyph != 0) glyph else null;
}

fn format12Covers(subtable: []const u8, codepoint: u21, many_to_one: bool) bool {
    return format12Glyph(subtable, codepoint, many_to_one) != null;
}

fn format12Glyph(subtable: []const u8, codepoint: u21, many_to_one: bool) ?u32 {
    return format12GlyphImpl(false, subtable, codepoint, many_to_one, null);
}

fn format12GlyphImpl(comptime counted: bool, subtable: []const u8, codepoint: u21, many_to_one: bool, work: ?*WorkStats) ?u32 {
    if (subtable.len < 16) return null;
    const group_count = readU32(subtable, 12) orelse return null;
    if (group_count == 0 or group_count > 1_000_000) return null;
    if (16 + @as(usize, group_count) * 12 > subtable.len) return null;
    if (counted) work.?.linear_queries += 1;
    var index: usize = 0;
    while (index < group_count) : (index += 1) {
        if (counted) work.?.group_visits += 1;
        const group = 16 + index * 12;
        const start = readU32(subtable, group) orelse return null;
        const end = readU32(subtable, group + 4) orelse return null;
        if (codepoint < start or codepoint > end) continue;
        const start_glyph = readU32(subtable, group + 8) orelse return null;
        const glyph = if (many_to_one) start_glyph else std.math.add(u32, start_glyph, @as(u32, codepoint) - start) catch return null;
        return if (glyph != 0) glyph else null;
    }
    return null;
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readI16(bytes: []const u8, offset: usize) ?i16 {
    if (offset + 2 > bytes.len) return null;
    return std.mem.readInt(i16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

test "format 4 cmap checks BMP segments" {
    var table = [_]u8{0} ** 24;
    std.mem.writeInt(u16, table[0..2], 4, .big);
    std.mem.writeInt(u16, table[2..4], 24, .big);
    std.mem.writeInt(u16, table[6..8], 2, .big);
    std.mem.writeInt(u16, table[14..16], 0x5a, .big);
    std.mem.writeInt(u16, table[18..20], 0x41, .big);
    std.mem.writeInt(u16, table[20..22], 0, .big);
    std.mem.writeInt(u16, table[22..24], 0, .big);
    try std.testing.expect(format4Covers(&table, 'A'));
    try std.testing.expect(format4Covers(&table, 'Z'));
    try std.testing.expect(!format4Covers(&table, 'a'));
}

test "format 12 cmap checks full-repertoire groups" {
    var table = [_]u8{0} ** 28;
    std.mem.writeInt(u16, table[0..2], 12, .big);
    std.mem.writeInt(u32, table[4..8], 28, .big);
    std.mem.writeInt(u32, table[12..16], 1, .big);
    std.mem.writeInt(u32, table[16..20], 0x1f600, .big);
    std.mem.writeInt(u32, table[20..24], 0x1f64f, .big);
    std.mem.writeInt(u32, table[24..28], 1, .big);
    try std.testing.expect(format12Covers(&table, 0x1f600, false));
    try std.testing.expect(format12Covers(&table, 0x1f64f, false));
    try std.testing.expect(!format12Covers(&table, 0x1f650, false));
}

test "subtable selection prefers format 12 over format 4" {
    var cmap = [_]u8{0} ** 40;
    std.mem.writeInt(u16, cmap[2..4], 2, .big);
    std.mem.writeInt(u16, cmap[4..6], 3, .big);
    std.mem.writeInt(u16, cmap[6..8], 1, .big);
    std.mem.writeInt(u32, cmap[8..12], 20, .big);
    std.mem.writeInt(u16, cmap[20..22], 4, .big);
    std.mem.writeInt(u16, cmap[22..24], 4, .big);
    std.mem.writeInt(u16, cmap[24..26], 0, .big);
    std.mem.writeInt(u16, cmap[26..28], 0, .big);
    std.mem.writeInt(u16, cmap[28..30], 0, .big);
    std.mem.writeInt(u16, cmap[30..32], 0, .big);
    std.mem.writeInt(u16, cmap[32..34], 0, .big);
    std.mem.writeInt(u16, cmap[34..36], 0, .big);
    std.mem.writeInt(u16, cmap[36..38], 0, .big);
    std.mem.writeInt(u16, cmap[38..40], 0, .big);
    try std.testing.expect(!tableCovers(&cmap, 'A'));
}

test "coverage cmap malformed offsets and overflowing glyph groups return false" {
    var table = [_]u8{0} ** 40;
    std.mem.writeInt(u16, table[2..4], 1, .big);
    std.mem.writeInt(u16, table[4..6], 3, .big);
    std.mem.writeInt(u16, table[6..8], 10, .big);
    std.mem.writeInt(u32, table[8..12], std.math.maxInt(u32), .big);
    try std.testing.expect(!tableCovers(&table, 'A'));
    std.mem.writeInt(u32, table[8..12], 12, .big);
    std.mem.writeInt(u16, table[12..14], 12, .big);
    std.mem.writeInt(u32, table[24..28], 1, .big);
    std.mem.writeInt(u32, table[28..32], 'A', .big);
    std.mem.writeInt(u32, table[32..36], 'Z', .big);
    std.mem.writeInt(u32, table[36..40], std.math.maxInt(u32), .big);
    try std.testing.expect(tableCovers(&table, 'A'));
    try std.testing.expect(!tableCovers(&table, 'B'));
    // Format 13 uses a constant glyph and cannot overflow from the codepoint.
    std.mem.writeInt(u16, table[12..14], 13, .big);
    try std.testing.expect(tableCovers(&table, 'B'));
}
