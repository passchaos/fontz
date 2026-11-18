//! Versioned on-disk cache for the bounded system-font metadata index.
//!
//! The cache stores only parsed metadata (never font bytes) and is validated
//! against the current root list plus every font file's path, size, and mtime.
//! A mismatch or any malformed cache byte falls back to a fresh scan. Writes
//! are atomic: a sibling `.tmp` file is renamed over the target.

const std = @import("std");
const builtin = @import("builtin");

pub const magic = "FNTZIDX1";
pub const version: u32 = 2;
pub const max_cache_bytes = 64 * 1024 * 1024;

pub const FileStamp = struct {
    path: []const u8,
    mtime_ns: i96,
    size: u64,
};

/// Serialize `faces` with the stamps and root list that produced them.
///
/// Best effort: callers ignore write failures and keep the freshly built
/// in-memory index.
pub fn store(
    comptime Face: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    roots: []const []const u8,
    stamps: []const FileStamp,
    faces: []const Face,
    limits_hash: u64,
) void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    writeCache(Face, &buffer, allocator, roots, stamps, faces, limits_hash) catch return;

    const dir_path = std.fs.path.dirname(cache_path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch return;
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path}) catch return;
    defer allocator.free(tmp_path);

    var file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, buffer.items) catch return;
    file.sync(io) catch {};
    std.Io.Dir.renameAbsolute(tmp_path, cache_path, io) catch return;
}

/// Load a validated cache. Returns null for missing, stale, or malformed
/// entries; faces and their strings are allocated in `allocator`.
pub fn load(
    comptime Face: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_path: []const u8,
    roots: []const []const u8,
    stamps: []const FileStamp,
    limits_hash: u64,
) !?[]const Face {
    var file = std.Io.Dir.openFileAbsolute(io, cache_path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > max_cache_bytes) return null;
    const data = try allocator.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, data, 0) != data.len) return null;
    return readCache(Face, data, allocator, roots, stamps, limits_hash) catch null;
}

fn writeCache(
    comptime Face: type,
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    stamps: []const FileStamp,
    faces: []const Face,
    limits_hash: u64,
) !void {
    try buffer.appendSlice(allocator, magic);
    try appendInt(u32, buffer, allocator, version);
    try appendInt(u64, buffer, allocator, limits_hash);
    try appendInt(u32, buffer, allocator, @intCast(roots.len));
    for (roots) |root| try appendString(buffer, allocator, root);
    try appendInt(u32, buffer, allocator, @intCast(stamps.len));
    for (stamps) |stamp| {
        try appendString(buffer, allocator, stamp.path);
        try appendInt(i64, buffer, allocator, std.math.cast(i64, stamp.mtime_ns) orelse 0);
        try appendInt(u64, buffer, allocator, stamp.size);
    }
    try appendInt(u32, buffer, allocator, @intCast(faces.len));
    for (faces) |face| {
        try appendInt(u32, buffer, allocator, stampIndex(stamps, face.path));
        try appendInt(u32, buffer, allocator, face.face_index);
        try appendInt(u16, buffer, allocator, face.named_instance);
        try appendInt(u16, buffer, allocator, face.weight);
        try appendInt(u16, buffer, allocator, face.stretch);
        try appendInt(u16, buffer, allocator, face.width_class);
        try buffer.append(allocator, @intFromEnum(face.style));
        try buffer.append(allocator, @intFromBool(face.italic) | (@as(u8, @intFromBool(face.monospaced)) << 1));
        try appendOptionalF32(buffer, allocator, face.opsz_min);
        try appendOptionalF32(buffer, allocator, face.opsz_default);
        try appendOptionalF32(buffer, allocator, face.opsz_max);
        try appendString(buffer, allocator, face.family);
        try appendString(buffer, allocator, face.subfamily);
        try appendString(buffer, allocator, face.full_name);
        try appendString(buffer, allocator, face.postscript_name);
        try appendInt(u32, buffer, allocator, @intCast(face.families.len));
        for (face.families) |localized| {
            try appendInt(u16, buffer, allocator, localized.language);
            try appendString(buffer, allocator, localized.name);
        }
    }
}

fn stampIndex(stamps: []const FileStamp, path: []const u8) u32 {
    for (stamps, 0..) |stamp, index| {
        if (std.mem.eql(u8, stamp.path, path)) return @intCast(index);
    }
    return 0;
}

fn readCache(
    comptime Face: type,
    data: []const u8,
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    stamps: []const FileStamp,
    limits_hash: u64,
) !?[]const Face {
    const LocalizedName = std.meta.Elem(@FieldType(Face, "families"));
    var reader = Reader{ .data = data };
    if (!std.mem.eql(u8, reader.bytes(magic.len) orelse return null, magic)) return null;
    if ((reader.readU32() orelse return null) != version) return null;
    if ((reader.readU64() orelse return null) != limits_hash) return null;

    const root_count = reader.readU32() orelse return null;
    if (root_count != roots.len) return null;
    for (roots) |root| {
        const cached = reader.string(allocator) orelse return null;
        if (!std.mem.eql(u8, cached, root)) return null;
    }

    const stamp_count = reader.readU32() orelse return null;
    if (stamp_count != stamps.len) return null;
    for (stamps) |stamp| {
        const cached_path = reader.string(allocator) orelse return null;
        if (!std.mem.eql(u8, cached_path, stamp.path)) return null;
        if ((reader.readI64() orelse return null) != (std.math.cast(i64, stamp.mtime_ns) orelse 0)) return null;
        if ((reader.readU64() orelse return null) != stamp.size) return null;
    }

    const face_count = reader.readU32() orelse return null;
    if (face_count > std.math.maxInt(u16)) return null;
    const faces = try allocator.alloc(Face, face_count);
    for (faces) |*face| {
        const file_index = reader.readU32() orelse return null;
        if (file_index >= stamps.len) return null;
        const face_index = reader.readU32() orelse return null;
        const named_instance = reader.readU16() orelse return null;
        const weight = reader.readU16() orelse return null;
        const stretch = reader.readU16() orelse return null;
        const width_class = reader.readU16() orelse return null;
        const style_byte = reader.readU8() orelse return null;
        const flags = reader.readU8() orelse return null;
        const opsz_min = readOptionalF32(&reader) orelse return null;
        const opsz_default = readOptionalF32(&reader) orelse return null;
        const opsz_max = readOptionalF32(&reader) orelse return null;
        const family = reader.string(allocator) orelse return null;
        const subfamily = reader.string(allocator) orelse return null;
        const full_name = reader.string(allocator) orelse return null;
        const postscript_name = reader.string(allocator) orelse return null;
        const family_count = reader.readU32() orelse return null;
        if (family_count > 4096) return null;
        const families = try allocator.alloc(LocalizedName, family_count);
        for (families) |*localized| {
            localized.* = .{
                .language = reader.readU16() orelse return null,
                .name = reader.string(allocator) orelse return null,
            };
        }
        face.* = .{
            .path = stamps[file_index].path,
            .face_index = face_index,
            .named_instance = named_instance,
            .family = family,
            .families = families,
            .subfamily = subfamily,
            .full_name = full_name,
            .postscript_name = postscript_name,
            .weight = weight,
            .stretch = stretch,
            .width_class = width_class,
            .italic = (flags & 1) != 0,
            .style = std.enums.fromInt(@FieldType(Face, "style"), style_byte) orelse return null,
            .monospaced = (flags & 2) != 0,
            .opsz_min = opsz_min.value,
            .opsz_default = opsz_default.value,
            .opsz_max = opsz_max.value,
        };
    }
    if (reader.pos != data.len) return null;
    return faces;
}

fn appendInt(comptime T: type, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try buffer.appendSlice(allocator, &bytes);
}

fn appendOptionalF32(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: ?f32) !void {
    try buffer.append(allocator, @intFromBool(value != null));
    if (value) |number| try appendInt(u32, buffer, allocator, @bitCast(number));
}

const OptionalF32 = struct { value: ?f32 };

fn readOptionalF32(reader: *Reader) ?OptionalF32 {
    const present = reader.readU8() orelse return null;
    if (present == 0) return .{ .value = null };
    const bits = reader.readU32() orelse return null;
    return .{ .value = @bitCast(bits) };
}

fn appendString(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendInt(u32, buffer, allocator, @intCast(value.len));
    try buffer.appendSlice(allocator, value);
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn bytes(self: *Reader, len: usize) ?[]const u8 {
        if (len > self.data.len -| self.pos) return null;
        const value = self.data[self.pos..][0..len];
        self.pos += len;
        return value;
    }

    fn readU8(self: *Reader) ?u8 {
        const value = self.bytes(1) orelse return null;
        return value[0];
    }

    fn readU16(self: *Reader) ?u16 {
        const value = self.bytes(2) orelse return null;
        return std.mem.readInt(u16, value[0..2], .little);
    }

    fn readU32(self: *Reader) ?u32 {
        const value = self.bytes(4) orelse return null;
        return std.mem.readInt(u32, value[0..4], .little);
    }

    fn readU64(self: *Reader) ?u64 {
        const value = self.bytes(8) orelse return null;
        return std.mem.readInt(u64, value[0..8], .little);
    }

    fn readI64(self: *Reader) ?i64 {
        const value = self.bytes(8) orelse return null;
        return std.mem.readInt(i64, value[0..8], .little);
    }

    fn string(self: *Reader, allocator: std.mem.Allocator) ?[]const u8 {
        const len = self.readU32() orelse return null;
        if (len > 1024 * 1024) return null;
        const value = self.bytes(len) orelse return null;
        return allocator.dupe(u8, value) catch null;
    }
};
