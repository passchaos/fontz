//! Minimal sfnt metadata parser for the bounded font index.
//!
//! Reads only the sfnt header, table directory, `name`, `OS/2` and `post`
//! tables. Raw table bytes come from a scratch allocator; decoded names are
//! allocated in the persistent index arena.

const std = @import("std");
const family_mod = @import("../family.zig");
const types = @import("../types.zig");
const test_font = @import("test_font.zig");

pub const LocalizedName = struct {
    name: []const u8,
    /// OpenType name-table language ID (platform-specific).
    language: u16 = 0,
};

pub const FaceMetadata = struct {
    family: []const u8,
    families: []const LocalizedName,
    subfamily: []const u8,
    full_name: []const u8,
    postscript_name: []const u8,
    weight: u16,
    stretch: u16,
    width_class: u16,
    italic: bool,
    style: types.Style,
    monospaced: bool,
    /// Named instances declared by the `fvar` table. Empty for static fonts.
    instances: []const InstanceMetadata = &.{},
    /// `opsz` axis range in design units, when the font declares one.
    opsz_min: ?f32 = null,
    opsz_default: ?f32 = null,
    opsz_max: ?f32 = null,
    bytes_read: usize,
};

/// One `fvar` named instance. `index` is the zero-based instance record index;
/// consumers that already store a 0-based instance identity can use it
/// directly, while the font index exposes it as `named_instance = index + 1`
/// so zero keeps meaning "the face's default instance".
pub const InstanceMetadata = struct {
    index: u16,
    subfamily: []const u8,
    postscript_name: []const u8,
    weight: u16,
    stretch: u16,
    style: types.Style,
};

const max_collection_faces = 64;

pub const FileMetadata = struct {
    faces: [max_collection_faces]FaceMetadata,
    count: usize,
    bytes_read: usize,
};

pub fn readFileMetadata(
    io: std.Io,
    file: std.Io.File,
    scratch: std.mem.Allocator,
    persist: std.mem.Allocator,
    max_name_table_bytes: usize,
    remaining_bytes: usize,
) !?FileMetadata {
    var result = FileMetadata{
        .faces = undefined,
        .count = 0,
        .bytes_read = 0,
    };
    var header: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return null;
    result.bytes_read += header.len;
    if (!std.mem.eql(u8, header[0..4], "ttcf")) {
        const meta = try readSfntMetadata(
            io,
            file,
            scratch,
            persist,
            0,
            max_name_table_bytes,
            remaining_bytes -| result.bytes_read,
        ) orelse return null;
        result.bytes_read += meta.bytes_read;
        result.faces[0] = meta;
        result.count = 1;
        return result;
    }
    const num_fonts = std.mem.readInt(u32, header[8..12], .big);
    if (num_fonts == 0 or num_fonts > max_collection_faces) return null;
    const offsets_len = @as(usize, num_fonts) * 4;
    if (offsets_len > remaining_bytes -| result.bytes_read) return null;
    var offsets_bytes: [max_collection_faces * 4]u8 = undefined;
    if (try file.readPositionalAll(io, offsets_bytes[0..offsets_len], 12) != offsets_len) return null;
    result.bytes_read += offsets_len;
    for (0..num_fonts) |face_index| {
        const offset = std.mem.readInt(u32, offsets_bytes[face_index * 4 ..][0..4], .big);
        const meta = try readSfntMetadata(
            io,
            file,
            scratch,
            persist,
            offset,
            max_name_table_bytes,
            remaining_bytes -| result.bytes_read,
        ) orelse continue;
        result.bytes_read += meta.bytes_read;
        result.faces[result.count] = meta;
        result.count += 1;
    }
    return if (result.count == 0) null else result;
}

pub fn readSfntMetadata(
    io: std.Io,
    file: std.Io.File,
    scratch: std.mem.Allocator,
    persist: std.mem.Allocator,
    sfnt_offset: u64,
    max_name_table_bytes: usize,
    remaining_bytes: usize,
) !?FaceMetadata {
    var header: [12]u8 = undefined;
    if (try file.readPositionalAll(io, &header, sfnt_offset) != header.len) return null;
    var bytes_read: usize = header.len;
    if (!isSfntVersion(header[0..4])) return null;
    const num_tables = std.mem.readInt(u16, header[4..6], .big);
    if (num_tables == 0 or num_tables > 512) return null;
    var directory: [512 * 16]u8 = undefined;
    const directory_len = @as(usize, num_tables) * 16;
    if (try file.readPositionalAll(io, directory[0..directory_len], sfnt_offset + 12) != directory_len) {
        return null;
    }
    bytes_read += directory_len;
    var name_record: ?TableRecord = null;
    var os2_record: ?TableRecord = null;
    var post_record: ?TableRecord = null;
    var fvar_record: ?TableRecord = null;
    var index: usize = 0;
    while (index < num_tables) : (index += 1) {
        const record = directory[index * 16 ..][0..16];
        const tag = record[0..4];
        const table = TableRecord{
            .offset = std.mem.readInt(u32, record[8..12], .big),
            .length = std.mem.readInt(u32, record[12..16], .big),
        };
        if (std.mem.eql(u8, tag, "name")) name_record = table;
        if (std.mem.eql(u8, tag, "OS/2")) os2_record = table;
        if (std.mem.eql(u8, tag, "post")) post_record = table;
        if (std.mem.eql(u8, tag, "fvar")) fvar_record = table;
    }
    const name_table = name_record orelse return null;
    if (name_table.length < 6 or name_table.length > max_name_table_bytes) return null;
    const name_len = @as(usize, name_table.length);
    if (name_len > remaining_bytes -| bytes_read) return null;
    const name_bytes = try scratch.alloc(u8, name_len);
    if (try file.readPositionalAll(io, name_bytes, name_table.offset) != name_len) return null;
    bytes_read += name_len;
    const names = (try parseNameTable(name_bytes, scratch, persist)) orelse return null;

    var weight: u16 = 0;
    var width_class: u16 = 5;
    var style: types.Style = if (names.subfamilyItalic) .italic else .normal;
    if (os2_record) |os2| {
        if (os2.length >= 64 and os2.length <= 4096) {
            const os2_len = @as(usize, os2.length);
            if (os2_len > remaining_bytes -| bytes_read) return null;
            const os2_bytes = try scratch.alloc(u8, os2_len);
            if (try file.readPositionalAll(io, os2_bytes, os2.offset) == os2_len) {
                bytes_read += os2_len;
                weight = std.mem.readInt(u16, os2_bytes[4..6], .big);
                width_class = std.mem.readInt(u16, os2_bytes[6..8], .big);
                const selection = std.mem.readInt(u16, os2_bytes[62..64], .big);
                if ((selection & 0x0001) != 0) style = .italic;
                if ((selection & 0x0200) != 0) style = .oblique;
            }
        }
    }
    if (weight == 0) weight = names.subfamilyWeight;
    if (width_class < 1 or width_class > 9) width_class = 5;

    var monospaced = false;
    if (post_record) |post| {
        if (post.length >= 16 and post.length <= 4096) {
            const post_len = @as(usize, post.length);
            if (post_len > remaining_bytes -| bytes_read) return null;
            const post_bytes = try scratch.alloc(u8, post_len);
            if (try file.readPositionalAll(io, post_bytes, post.offset) == post_len) {
                bytes_read += post_len;
                const italic_angle = std.mem.readInt(u32, post_bytes[4..8], .big);
                if (italic_angle != 0 and style == .normal) style = .italic;
                monospaced = std.mem.readInt(u32, post_bytes[12..16], .big) != 0;
            }
        }
    }
    var fvar_metadata = FvarMetadata{};
    if (fvar_record) |fvar| {
        if (fvar.length >= 16 and fvar.length <= 1024 * 1024) {
            const fvar_len = @as(usize, fvar.length);
            if (fvar_len <= remaining_bytes -| bytes_read) {
                const fvar_bytes = try scratch.alloc(u8, fvar_len);
                if (try file.readPositionalAll(io, fvar_bytes, fvar.offset) == fvar_len) {
                    bytes_read += fvar_len;
                    fvar_metadata = (try parseFvar(
                        fvar_bytes,
                        name_bytes,
                        persist,
                        names.postscript_name,
                        weight,
                        family_mod.widthClassToStretch(width_class),
                        style,
                    )) orelse .{};
                }
            }
        }
    }
    return .{
        .family = names.family,
        .families = names.families,
        .subfamily = names.subfamily,
        .full_name = names.full_name,
        .postscript_name = names.postscript_name,
        .weight = weight,
        .stretch = family_mod.widthClassToStretch(width_class),
        .width_class = width_class,
        .italic = style != .normal,
        .style = style,
        .monospaced = monospaced,
        .instances = fvar_metadata.instances,
        .opsz_min = fvar_metadata.opsz_min,
        .opsz_default = fvar_metadata.opsz_default,
        .opsz_max = fvar_metadata.opsz_max,
        .bytes_read = bytes_read,
    };
}

// SFNS.ttf currently declares 369 named instances. Keep enough headroom to
// cover optical-size/width combinations without letting hostile fonts allocate
// unbounded metadata.
const max_named_instances = 512;

const FvarAxis = struct {
    tag: [4]u8,
    default: f32,
};

const FvarMetadata = struct {
    instances: []const InstanceMetadata = &.{},
    opsz_min: ?f32 = null,
    opsz_default: ?f32 = null,
    opsz_max: ?f32 = null,
};

fn parseFvar(
    bytes: []const u8,
    name_bytes: []const u8,
    persist: std.mem.Allocator,
    base_postscript_name: []const u8,
    base_weight: u16,
    base_stretch: u16,
    base_style: types.Style,
) !?FvarMetadata {
    if (bytes.len < 16) return null;
    const axes_offset = std.mem.readInt(u16, bytes[4..6], .big);
    const axis_count = std.mem.readInt(u16, bytes[8..10], .big);
    const axis_size = std.mem.readInt(u16, bytes[10..12], .big);
    const instance_count = std.mem.readInt(u16, bytes[12..14], .big);
    const instance_size = std.mem.readInt(u16, bytes[14..16], .big);
    if (axis_count == 0 or axis_count > 64) return null;
    if (axis_size < 20 or instance_size < 4 + @as(usize, axis_count) * 4) return null;
    const axes_start = @as(usize, axes_offset);
    const axes_end = axes_start + @as(usize, axis_count) * axis_size;
    if (axes_end > bytes.len) return null;
    const instance_start = axes_end;
    if (instance_start + @as(usize, instance_count) * instance_size > bytes.len) return null;

    var axes: [64]FvarAxis = undefined;
    for (0..axis_count) |axis_index| {
        const axis = bytes[axes_start + axis_index * axis_size ..][0..axis_size];
        axes[axis_index] = .{
            .tag = axis[0..4].*,
            .default = fixedToFloat(std.mem.readInt(i32, axis[8..12], .big)),
        };
    }

    var result = FvarMetadata{};
    // The axis record layout is tag, min, default, max.
    var axis_cursor: usize = 0;
    while (axis_cursor < axis_count) : (axis_cursor += 1) {
        const axis = bytes[axes_start + axis_cursor * axis_size ..][0..axis_size];
        if (!std.mem.eql(u8, axis[0..4], "opsz")) continue;
        result.opsz_min = fixedToFloat(std.mem.readInt(i32, axis[4..8], .big));
        result.opsz_default = fixedToFloat(std.mem.readInt(i32, axis[8..12], .big));
        result.opsz_max = fixedToFloat(std.mem.readInt(i32, axis[12..16], .big));
        break;
    }

    const limit = @min(@as(usize, instance_count), max_named_instances);
    var instances: std.ArrayList(InstanceMetadata) = .empty;
    errdefer instances.deinit(persist);
    for (0..limit) |instance_index| {
        const record = bytes[instance_start + instance_index * instance_size ..][0..instance_size];
        const subfamily_id = std.mem.readInt(u16, record[0..2], .big);
        if (subfamily_id < 256) continue;
        const subfamily = (try resolveNameId(name_bytes, subfamily_id, persist)) orelse continue;
        const postscript_id: u16 = if (instance_size >= 4 + @as(usize, axis_count) * 4 + 2)
            std.mem.readInt(u16, record[4 + @as(usize, axis_count) * 4 ..][0..2], .big)
        else
            0;
        var postscript_name: ?[]const u8 = if (postscript_id >= 256)
            try resolveNameId(name_bytes, postscript_id, persist)
        else
            null;
        if (postscript_name == null) {
            postscript_name = try deriveInstancePostscriptName(
                name_bytes,
                persist,
                base_postscript_name,
                subfamily,
            );
        }

        var weight = base_weight;
        var stretch = base_stretch;
        var style = base_style;
        for (axes[0..axis_count], 0..) |axis, axis_index| {
            const value = fixedToFloat(std.mem.readInt(
                i32,
                record[4 + axis_index * 4 ..][0..4],
                .big,
            ));
            if (std.mem.eql(u8, &axis.tag, "wght")) {
                weight = clampRound(value, 1, 1000);
            } else if (std.mem.eql(u8, &axis.tag, "wdth")) {
                stretch = clampRound(value, 50, 200);
            } else if (std.mem.eql(u8, &axis.tag, "ital")) {
                style = if (value >= 0.5) .italic else .normal;
            } else if (std.mem.eql(u8, &axis.tag, "slnt")) {
                if (@abs(value - axis.default) > 0.01) style = .oblique;
            }
        }

        try instances.append(persist, .{
            .index = @intCast(instance_index),
            .subfamily = subfamily,
            .postscript_name = postscript_name.?,
            .weight = weight,
            .stretch = stretch,
            .style = style,
        });
    }
    result.instances = try instances.toOwnedSlice(persist);
    return result;
}

fn fixedToFloat(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 65536.0;
}

fn clampRound(value: f32, min: u16, max: u16) u16 {
    const rounded: i64 = @intFromFloat(@round(value));
    if (rounded < min) return min;
    if (rounded > max) return max;
    return @intCast(rounded);
}

fn deriveInstancePostscriptName(
    name_bytes: []const u8,
    allocator: std.mem.Allocator,
    base_postscript_name: []const u8,
    subfamily: []const u8,
) ![]const u8 {
    if (try resolveNameId(name_bytes, 25, allocator)) |prefix| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, prefix);
        for (subfamily) |byte| {
            if (byte == ' ') continue;
            try out.append(allocator, byte);
        }
        return try out.toOwnedSlice(allocator);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (base_postscript_name.len != 0) {
        try out.appendSlice(allocator, base_postscript_name);
        try out.append(allocator, '-');
    }
    for (subfamily) |byte| {
        if (byte == ' ') continue;
        try out.append(allocator, byte);
    }
    return try out.toOwnedSlice(allocator);
}

/// Resolve one `name` table ID using the same platform/language scoring as
/// `parseNameTable`. Returns an owned UTF-8 string.
fn resolveNameId(
    bytes: []const u8,
    name_id: u16,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    if (bytes.len < 6) return null;
    const count = std.mem.readInt(u16, bytes[2..4], .big);
    const string_offset = std.mem.readInt(u16, bytes[4..6], .big);
    if (bytes.len < 6 + @as(usize, count) * 12) return null;
    var best: ?[]const u8 = null;
    var best_score: u16 = 0;
    var record_index: usize = 0;
    while (record_index < count) : (record_index += 1) {
        const record = bytes[6 + record_index * 12 ..][0..12];
        if (std.mem.readInt(u16, record[6..8], .big) != name_id) continue;
        const platform = std.mem.readInt(u16, record[0..2], .big);
        const encoding = std.mem.readInt(u16, record[2..4], .big);
        const language = std.mem.readInt(u16, record[4..6], .big);
        const length = std.mem.readInt(u16, record[8..10], .big);
        const offset = std.mem.readInt(u16, record[10..12], .big);
        const start = @as(usize, string_offset) + offset;
        if (start > bytes.len or length > bytes.len - start) continue;
        const score = nameScore(platform, encoding, language);
        if (score == 0 or score <= best_score) continue;
        const decoded = (try decodeName(allocator, platform, bytes[start..][0..length])) orelse continue;
        best = decoded;
        best_score = score;
    }
    return best;
}

const TableRecord = struct {
    offset: u32,
    length: u32,
};

const Names = struct {
    family: []const u8,
    families: []const LocalizedName,
    subfamily: []const u8,
    full_name: []const u8,
    postscript_name: []const u8,
    subfamilyWeight: u16,
    subfamilyItalic: bool,
};

fn parseNameTable(
    bytes: []const u8,
    scratch: std.mem.Allocator,
    persist: std.mem.Allocator,
) !?Names {
    _ = scratch;
    if (bytes.len < 6) return null;
    const count = std.mem.readInt(u16, bytes[2..4], .big);
    const string_offset = std.mem.readInt(u16, bytes[4..6], .big);
    if (count == 0 or count > 4096) return null;
    if (bytes.len < 6 + @as(usize, count) * 12) return null;

    var families: std.ArrayList(LocalizedName) = .empty;
    errdefer families.deinit(persist);
    var family: ?[]const u8 = null;
    var family_score: u16 = 0;
    var subfamily: ?[]const u8 = null;
    var subfamily_score: u16 = 0;
    var full_name: ?[]const u8 = null;
    var full_name_score: u16 = 0;
    var postscript_name: ?[]const u8 = null;
    var postscript_score: u16 = 0;

    var record_index: usize = 0;
    while (record_index < count) : (record_index += 1) {
        const record = bytes[6 + record_index * 12 ..][0..12];
        const platform = std.mem.readInt(u16, record[0..2], .big);
        const encoding = std.mem.readInt(u16, record[2..4], .big);
        const language = std.mem.readInt(u16, record[4..6], .big);
        const name_id = std.mem.readInt(u16, record[6..8], .big);
        const length = std.mem.readInt(u16, record[8..10], .big);
        const offset = std.mem.readInt(u16, record[10..12], .big);
        if (name_id != 1 and name_id != 2 and name_id != 4 and
            name_id != 6 and name_id != 16 and name_id != 17) continue;
        const start = @as(usize, string_offset) + offset;
        if (start > bytes.len or length > bytes.len - start) continue;
        const raw = bytes[start..][0..length];
        const score = nameScore(platform, encoding, language);
        if (score == 0) continue;
        const decoded = (try decodeName(persist, platform, raw)) orelse continue;
        switch (name_id) {
            1, 16 => {
                const typographic_bonus: u16 = if (name_id == 16) 8 else 0;
                const combined = score + typographic_bonus;
                try addLocalizedName(persist, &families, decoded, language);
                if (combined > family_score) {
                    family = decoded;
                    family_score = combined;
                }
            },
            2, 17 => {
                const typographic_bonus: u16 = if (name_id == 17) 8 else 0;
                const combined = score + typographic_bonus;
                if (combined > subfamily_score) {
                    subfamily = decoded;
                    subfamily_score = combined;
                }
            },
            4 => if (score > full_name_score) {
                full_name = decoded;
                full_name_score = score;
            },
            6 => if (score > postscript_score) {
                postscript_name = decoded;
                postscript_score = score;
            },
            else => {},
        }
    }

    if (families.items.len == 0) return null;
    const owned_families = try families.toOwnedSlice(persist);
    const resolved_family = family orelse owned_families[0].name;
    const resolved_subfamily = subfamily orelse "Regular";
    return .{
        .family = resolved_family,
        .families = owned_families,
        .subfamily = resolved_subfamily,
        .full_name = full_name orelse resolved_family,
        .postscript_name = postscript_name orelse "",
        .subfamilyWeight = weightFromSubfamily(resolved_subfamily),
        .subfamilyItalic = italicFromSubfamily(resolved_subfamily),
    };
}

fn addLocalizedName(
    allocator: std.mem.Allocator,
    families: *std.ArrayList(LocalizedName),
    name: []const u8,
    language: u16,
) !void {
    for (families.items) |existing| {
        if (existing.language == language and std.mem.eql(u8, existing.name, name)) return;
    }
    try families.append(allocator, .{ .name = name, .language = language });
}

fn nameScore(platform: u16, encoding: u16, language: u16) u16 {
    return switch (platform) {
        3 => switch (encoding) {
            1, 10 => if (language == 0x0409) 6 else if (language == 0) 5 else 4,
            else => 0,
        },
        0 => 5,
        1 => if (encoding == 0) 3 else 0,
        else => 0,
    };
}

fn decodeName(allocator: std.mem.Allocator, platform: u16, raw: []const u8) !?[]const u8 {
    if (platform == 1) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (raw) |byte| {
            const codepoint = mac_roman[byte];
            if (codepoint == 0) continue;
            var buffer: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &buffer) catch continue;
            try out.appendSlice(allocator, buffer[0..encoded_len]);
        }
        return try out.toOwnedSlice(allocator);
    }
    if (raw.len % 2 != 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) : (index += 2) {
        const unit = std.mem.readInt(u16, raw[index..][0..2], .big);
        if (unit == 0) continue;
        var codepoint: u21 = unit;
        if (unit >= 0xd800 and unit <= 0xdbff and index + 4 <= raw.len) {
            const low = std.mem.readInt(u16, raw[index + 2 ..][0..2], .big);
            if (low >= 0xdc00 and low <= 0xdfff) {
                codepoint = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
                index += 2;
            }
        }
        var buffer: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(codepoint, &buffer) catch continue;
        try out.appendSlice(allocator, buffer[0..encoded_len]);
    }
    return try out.toOwnedSlice(allocator);
}

fn weightFromSubfamily(subfamily: []const u8) u16 {
    inline for (.{
        .{ "thin", 100 },     .{ "extralight", 200 }, .{ "ultralight", 200 },
        .{ "light", 300 },    .{ "medium", 500 },     .{ "semibold", 600 },
        .{ "demibold", 600 }, .{ "extrabold", 800 },  .{ "ultrabold", 800 },
        .{ "black", 900 },    .{ "heavy", 900 },      .{ "bold", 700 },
    }) |entry| {
        if (containsIgnoreCase(subfamily, entry[0])) return entry[1];
    }
    return 400;
}

fn italicFromSubfamily(subfamily: []const u8) bool {
    return containsIgnoreCase(subfamily, "italic") or
        containsIgnoreCase(subfamily, "oblique");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn isSfntVersion(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    return std.mem.eql(u8, bytes, "true") or
        std.mem.eql(u8, bytes, "typ1") or
        std.mem.eql(u8, bytes, "OTTO") or
        std.mem.readInt(u32, bytes[0..4], .big) == 0x00010000;
}

const mac_roman = [256]u16{
    0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
    0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F,
    0x0010, 0x2318, 0x21E7, 0x2325, 0x2303, 0x0015, 0x0016, 0x0017,
    0x0018, 0x0019, 0x001A, 0x001B, 0x001C, 0x001D, 0x001E, 0x001F,
    0x0020, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027,
    0x0028, 0x0029, 0x002A, 0x002B, 0x002C, 0x002D, 0x002E, 0x002F,
    0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
    0x0038, 0x0039, 0x003A, 0x003B, 0x003C, 0x003D, 0x003E, 0x003F,
    0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
    0x0048, 0x0049, 0x004A, 0x004B, 0x004C, 0x004D, 0x004E, 0x004F,
    0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
    0x0058, 0x0059, 0x005A, 0x005B, 0x005C, 0x005D, 0x005E, 0x005F,
    0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
    0x0068, 0x0069, 0x006A, 0x006B, 0x006C, 0x006D, 0x006E, 0x006F,
    0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
    0x0078, 0x0079, 0x007A, 0x007B, 0x007C, 0x007D, 0x007E, 0x007F,
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
};

test "sfnt name parsing matches family and style metadata" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var persist = std.heap.ArenaAllocator.init(allocator);
    defer persist.deinit();
    const name_table = try test_font.buildTestNameTable(allocator, .{
        .family = "Test Sans",
        .localized_family = .{ .name = "测试字体", .language = 0x0804 },
        .subfamily = "Bold Italic",
        .full_name = "Test Sans Bold Italic",
        .postscript_name = "TestSans-BoldItalic",
    });
    defer allocator.free(name_table);
    const names = (try parseNameTable(name_table, scratch.allocator(), persist.allocator())).?;
    try std.testing.expectEqualStrings("Test Sans", names.family);
    try std.testing.expectEqualStrings("Bold Italic", names.subfamily);
    try std.testing.expectEqualStrings("TestSans-BoldItalic", names.postscript_name);
    try std.testing.expectEqual(@as(u16, 700), names.subfamilyWeight);
    try std.testing.expect(names.subfamilyItalic);
    var saw_localized = false;
    for (names.families) |localized| {
        if (std.mem.eql(u8, localized.name, "测试字体")) saw_localized = true;
    }
    try std.testing.expect(saw_localized);
}
