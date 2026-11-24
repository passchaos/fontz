//! Bounded sfnt cmap and lazy maxp reads; scalar cold IO stays unchanged.
const std = @import("std");

pub const max_cmap_bytes = 16 * 1024 * 1024;

/// Counts actual font-file work, including short reads. Used by the coverage
/// cache and its counted-IO workload; table queries do not touch these counts.
pub const ReadStats = struct {
    file_opens: u64 = 0,
    read_calls: u64 = 0,
    bytes_read: u64 = 0,
};

/// Read one face's bounded cmap table. The caller owns the returned bytes.
/// Structural failures and short reads return null; IO and allocation errors
/// remain errors so a cache can retry a transient failure on the next query.
pub fn readTable(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    face_index: u32,
    stats: ?*ReadStats,
) !?[]u8 {
    return (try readCoverageData(io, allocator, path, face_index, false, stats)).table;
}

pub const CoverageData = struct {
    table: ?[]u8 = null,
    num_glyphs: ?u16 = null,
};

pub fn readCoverageData(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    face_index: u32,
    with_glyph_count: bool,
    stats: ?*ReadStats,
) !CoverageData {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    if (stats) |counts| counts.file_opens += 1;

    var header: [12]u8 = undefined;
    if (try read(io, file, &header, 0, stats) != header.len) return .{};
    var sfnt_offset: u64 = 0;
    if (std.mem.eql(u8, header[0..4], "ttcf")) {
        const num_fonts = std.mem.readInt(u32, header[8..12], .big);
        if (face_index >= num_fonts) return .{};
        var offset_bytes: [4]u8 = undefined;
        if (try read(io, file, &offset_bytes, 12 + @as(u64, face_index) * 4, stats) != 4) return .{};
        sfnt_offset = std.mem.readInt(u32, &offset_bytes, .big);
    } else if (face_index != 0) {
        return .{};
    }

    var sfnt_header: [12]u8 = undefined;
    if (try read(io, file, &sfnt_header, sfnt_offset, stats) != sfnt_header.len) return .{};
    const num_tables = std.mem.readInt(u16, sfnt_header[4..6], .big);
    if (num_tables == 0 or num_tables > 512) return .{};
    var directory: [512 * 16]u8 = undefined;
    const directory_len = @as(usize, num_tables) * 16;
    if (try read(io, file, directory[0..directory_len], sfnt_offset + 12, stats) != directory_len) {
        return .{};
    }
    var maxp_offset: u32 = 0;
    var maxp_length: u32 = 0;
    var cmap_offset: u32 = 0;
    var cmap_length: u32 = 0;
    var found_cmap = false;
    var index: usize = 0;
    while (index < num_tables) : (index += 1) {
        const record = directory[index * 16 ..][0..16];
        if (std.mem.eql(u8, record[0..4], "maxp")) {
            maxp_offset = std.mem.readInt(u32, record[8..12], .big);
            maxp_length = std.mem.readInt(u32, record[12..16], .big);
        }
        if (!std.mem.eql(u8, record[0..4], "cmap")) continue;
        if (found_cmap) continue;
        found_cmap = true;
        cmap_offset = std.mem.readInt(u32, record[8..12], .big);
        cmap_length = std.mem.readInt(u32, record[12..16], .big);
    }
    if (cmap_offset == 0 or cmap_length < 4 or cmap_length > max_cmap_bytes) return .{};
    const cmap_bytes = try allocator.alloc(u8, cmap_length);
    errdefer allocator.free(cmap_bytes);
    if (try read(io, file, cmap_bytes, cmap_offset, stats) != cmap_length) {
        allocator.free(cmap_bytes);
        return .{};
    }
    const num_glyphs = if (with_glyph_count)
        try readMaxp(io, file, maxp_offset, maxp_length, stats)
    else
        null;
    return .{ .table = cmap_bytes, .num_glyphs = num_glyphs };
}

fn read(io: std.Io, file: std.Io.File, bytes: []u8, offset: u64, stats: ?*ReadStats) !usize {
    if (stats) |counts| counts.read_calls += 1;
    const len = try file.readPositionalAll(io, bytes, offset);
    if (stats) |counts| counts.bytes_read += len;
    return len;
}

pub fn readGlyphCount(
    io: std.Io,
    path: []const u8,
    face_index: u32,
    stats: ?*ReadStats,
) !?u16 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    if (stats) |counts| counts.file_opens += 1;

    var header: [12]u8 = undefined;
    if (try read(io, file, &header, 0, stats) != header.len) return null;
    var sfnt_offset: u64 = 0;
    if (std.mem.eql(u8, header[0..4], "ttcf")) {
        const num_fonts = std.mem.readInt(u32, header[8..12], .big);
        if (face_index >= num_fonts) return null;
        var offset_bytes: [4]u8 = undefined;
        if (try read(io, file, &offset_bytes, 12 + @as(u64, face_index) * 4, stats) != 4) return null;
        sfnt_offset = std.mem.readInt(u32, &offset_bytes, .big);
    } else if (face_index != 0) {
        return null;
    }

    var sfnt_header: [12]u8 = undefined;
    if (try read(io, file, &sfnt_header, sfnt_offset, stats) != sfnt_header.len) return null;
    const num_tables = std.mem.readInt(u16, sfnt_header[4..6], .big);
    if (num_tables == 0 or num_tables > 512) return null;
    var directory: [512 * 16]u8 = undefined;
    const directory_len = @as(usize, num_tables) * 16;
    if (try read(io, file, directory[0..directory_len], sfnt_offset + 12, stats) != directory_len) {
        return null;
    }
    var maxp_offset: u32 = 0;
    var maxp_length: u32 = 0;
    var index: usize = 0;
    while (index < num_tables) : (index += 1) {
        const record = directory[index * 16 ..][0..16];
        if (std.mem.eql(u8, record[0..4], "maxp")) {
            maxp_offset = std.mem.readInt(u32, record[8..12], .big);
            maxp_length = std.mem.readInt(u32, record[12..16], .big);
        }
    }
    return readMaxp(io, file, maxp_offset, maxp_length, stats);
}

fn readMaxp(io: std.Io, file: std.Io.File, offset: u32, length: u32, stats: ?*ReadStats) !?u16 {
    if (offset == 0 or length < 6) return null;
    var header: [6]u8 = undefined;
    if (try read(io, file, &header, offset, stats) != header.len) return null;
    const version = std.mem.readInt(u32, header[0..4], .big);
    if (version != 0x00005000 and version != 0x00010000) return null;
    if (version == 0x00010000 and length < 32) return null;
    const count = std.mem.readInt(u16, header[4..6], .big);
    return if (count != 0) count else null;
}
