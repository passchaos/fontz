//! Minimal pure-Zig sfnt `cmap` coverage reader.
//!
//! Supports the common Unicode subtables: format 4 (BMP), format 12/13
//! (full repertoire), format 6 and format 0. Used by the pure-Zig discovery
//! provider to prove that a candidate actually covers a codepoint.

const std = @import("std");

const max_cmap_bytes = 16 * 1024 * 1024;

pub fn coversCodepoint(
    io: std.Io,
    path: []const u8,
    face_index: u32,
    codepoint: u21,
) !bool {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var header: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return false;
    var sfnt_offset: u64 = 0;
    if (std.mem.eql(u8, header[0..4], "ttcf")) {
        const num_fonts = std.mem.readInt(u32, header[8..12], .big);
        if (face_index >= num_fonts) return false;
        var offset_bytes: [4]u8 = undefined;
        if (try file.readPositionalAll(io, &offset_bytes, 12 + @as(u64, face_index) * 4) != 4) return false;
        sfnt_offset = std.mem.readInt(u32, &offset_bytes, .big);
    } else if (face_index != 0) {
        return false;
    }

    var sfnt_header: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &sfnt_header, sfnt_offset) != sfnt_header.len) return false;
    const num_tables = std.mem.readInt(u16, sfnt_header[4..6], .big);
    if (num_tables == 0 or num_tables > 512) return false;
    var directory: [512 * 16]u8 = undefined;
    const directory_len = @as(usize, num_tables) * 16;
    if (try file.readPositionalAll(io, directory[0..directory_len], sfnt_offset + 12) != directory_len) {
        return false;
    }
    var cmap_offset: u32 = 0;
    var cmap_length: u32 = 0;
    var index: usize = 0;
    while (index < num_tables) : (index += 1) {
        const record = directory[index * 16 ..][0..16];
        if (!std.mem.eql(u8, record[0..4], "cmap")) continue;
        cmap_offset = std.mem.readInt(u32, record[8..12], .big);
        cmap_length = std.mem.readInt(u32, record[12..16], .big);
        break;
    }
    if (cmap_offset == 0 or cmap_length < 4 or cmap_length > max_cmap_bytes) return false;
    const cmap_bytes = try std.heap.page_allocator.alloc(u8, cmap_length);
    defer std.heap.page_allocator.free(cmap_bytes);
    if (try file.readPositionalAll(io, cmap_bytes, cmap_offset) != cmap_length) return false;
    return subtableCovers(cmap_bytes, codepoint);
}

fn subtableCovers(cmap: []const u8, codepoint: u21) bool {
    if (cmap.len < 4) return false;
    const count = readU16(cmap, 2) orelse return false;
    if (count == 0 or count > 1024) return false;
    if (cmap.len < 4 + @as(usize, count) * 8) return false;

    var best_offset: ?u32 = null;
    var best_score: u8 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 4 + index * 8;
        const platform = readU16(cmap, record) orelse continue;
        const encoding = readU16(cmap, record + 2) orelse continue;
        const offset = readU32(cmap, record + 4) orelse continue;
        if (offset + 2 > cmap.len) continue;
        const format = readU16(cmap, offset) orelse continue;
        const score = subtableScore(platform, encoding, format);
        if (score > best_score) {
            best_score = score;
            best_offset = offset;
        }
    }
    const offset = best_offset orelse return false;
    const format = readU16(cmap, offset) orelse return false;
    const subtable = cmap[offset..];
    return switch (format) {
        0 => format0Covers(subtable, codepoint),
        4 => format4Covers(subtable, codepoint),
        6 => format6Covers(subtable, codepoint),
        12, 13 => format12Covers(subtable, codepoint, format == 13),
        else => false,
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
    if (subtable.len < 6 + 256) return false;
    if (codepoint > 255) return false;
    return subtable[6 + codepoint] != 0;
}

fn format4Covers(subtable: []const u8, codepoint: u21) bool {
    if (subtable.len < 14 or codepoint > 0xffff) return false;
    const seg_count_x2 = readU16(subtable, 6) orelse return false;
    if (seg_count_x2 == 0 or (seg_count_x2 & 1) != 0) return false;
    const seg_count = @as(usize, seg_count_x2) / 2;
    const end_codes = 14;
    const start_codes = end_codes + seg_count * 2 + 2;
    const id_deltas = start_codes + seg_count * 2;
    const id_range_offsets = id_deltas + seg_count * 2;
    if (id_range_offsets + seg_count * 2 > subtable.len) return false;
    const cp: u16 = @intCast(codepoint);
    var index: usize = 0;
    while (index < seg_count) : (index += 1) {
        const end = readU16(subtable, end_codes + index * 2) orelse return false;
        if (cp > end) continue;
        const start = readU16(subtable, start_codes + index * 2) orelse return false;
        if (cp < start) return false;
        const delta = readI16(subtable, id_deltas + index * 2) orelse return false;
        const range_offset = readU16(subtable, id_range_offsets + index * 2) orelse return false;
        if (range_offset == 0) {
            const glyph = (cp +% @as(u16, @bitCast(delta))) & 0xffff;
            return glyph != 0;
        }
        const address = id_range_offsets + index * 2 + @as(usize, range_offset) +
            @as(usize, cp - start) * 2;
        if (address + 2 > subtable.len) return false;
        var glyph = readU16(subtable, address) orelse return false;
        if (glyph == 0) return false;
        glyph = (glyph +% @as(u16, @bitCast(delta))) & 0xffff;
        return glyph != 0;
    }
    return false;
}

fn format6Covers(subtable: []const u8, codepoint: u21) bool {
    if (subtable.len < 10) return false;
    const first_code = readU16(subtable, 6) orelse return false;
    const entry_count = readU16(subtable, 8) orelse return false;
    if (codepoint < first_code or codepoint >= @as(u32, first_code) + entry_count) return false;
    const index: usize = @intCast(codepoint - first_code);
    if (10 + index * 2 + 2 > subtable.len) return false;
    const glyph = readU16(subtable, 10 + index * 2) orelse return false;
    return glyph != 0;
}

fn format12Covers(subtable: []const u8, codepoint: u21, many_to_one: bool) bool {
    if (subtable.len < 16) return false;
    const group_count = readU32(subtable, 12) orelse return false;
    if (group_count == 0 or group_count > 1_000_000) return false;
    if (16 + @as(usize, group_count) * 12 > subtable.len) return false;
    var index: usize = 0;
    while (index < group_count) : (index += 1) {
        const group = 16 + index * 12;
        const start = readU32(subtable, group) orelse return false;
        const end = readU32(subtable, group + 4) orelse return false;
        if (codepoint < start or codepoint > end) continue;
        const start_glyph = readU32(subtable, group + 8) orelse return false;
        const glyph = if (many_to_one) start_glyph else start_glyph + (@as(u32, codepoint) - start);
        return glyph != 0;
    }
    return false;
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
    try std.testing.expect(!subtableCovers(&cmap, 'A'));
}
