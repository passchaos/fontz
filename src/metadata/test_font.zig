//! Synthetic sfnt builders used by metadata parsing/index tests.

const std = @import("std");

pub const TestInstance = struct {
    subfamily: []const u8,
    postscript_name: []const u8,
    /// Design-coordinate value on the synthetic `wght` axis.
    weight: f32,
};

pub const TestAxis = struct {
    min: f32,
    default: f32,
    max: f32,
};

pub const TestFontOptions = struct {
    family: []const u8,
    localized_family: ?struct { name: []const u8, language: u16 = 0x0804 } = null,
    subfamily: []const u8 = "Regular",
    full_name: ?[]const u8 = null,
    postscript_name: []const u8 = "TestSans-Regular",
    weight: u16 = 400,
    width_class: u16 = 5,
    italic: bool = false,
    monospaced: bool = false,
    instances: []const TestInstance = &.{},
    /// Optional synthetic `opsz` axis range.
    opsz: ?TestAxis = null,
    /// Optional cmap bytes for coverage-cache workloads.
    cmap: ?[]const u8 = null,
    /// Optional maxp for glyph-bound eligibility tests.
    num_glyphs: ?u16 = null,
};

pub fn buildTestNameTable(allocator: std.mem.Allocator, options: TestFontOptions) ![]u8 {
    const record_count: usize = 4 +
        @as(usize, @intFromBool(options.localized_family != null)) +
        options.instances.len * 2;
    const strings_offset = 6 + record_count * 12;
    const full_name = options.full_name orelse options.family;
    var string_len: usize = (options.family.len + options.subfamily.len +
        full_name.len + options.postscript_name.len) * 2;
    if (options.localized_family) |localized| string_len += localized.name.len * 2;
    for (options.instances) |instance| {
        string_len += (instance.subfamily.len + instance.postscript_name.len) * 2;
    }
    const total = strings_offset + string_len;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u16, bytes[0..2], 0, .big);
    std.mem.writeInt(u16, bytes[2..4], @intCast(record_count), .big);
    std.mem.writeInt(u16, bytes[4..6], @intCast(strings_offset), .big);
    var record_index: usize = 0;
    var offset: usize = 0;
    offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, 1, strings_offset, offset, options.family);
    record_index += 1;
    if (options.localized_family) |localized| {
        offset = writeTestNameRecord(bytes, record_index, 3, 1, localized.language, 1, strings_offset, offset, localized.name);
        record_index += 1;
    }
    offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, 2, strings_offset, offset, options.subfamily);
    record_index += 1;
    offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, 4, strings_offset, offset, full_name);
    record_index += 1;
    offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, 6, strings_offset, offset, options.postscript_name);
    record_index += 1;
    for (options.instances, 0..) |instance, instance_index| {
        const subfamily_id: u16 = @intCast(256 + instance_index * 2);
        const postscript_id: u16 = subfamily_id + 1;
        offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, subfamily_id, strings_offset, offset, instance.subfamily);
        record_index += 1;
        offset = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, postscript_id, strings_offset, offset, instance.postscript_name);
        record_index += 1;
    }
    return bytes;
}

fn buildTestFvarTable(allocator: std.mem.Allocator, options: TestFontOptions) ![]u8 {
    const axis_count: usize = 1 + @as(usize, @intFromBool(options.opsz != null));
    const axis_size: usize = 20;
    const instance_size: usize = 4 + axis_count * 4 + 2;
    const header_len: usize = 16;
    const total = header_len + axis_size * axis_count + options.instances.len * instance_size;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u16, bytes[0..2], 1, .big);
    std.mem.writeInt(u16, bytes[2..4], 0, .big);
    std.mem.writeInt(u16, bytes[4..6], @intCast(header_len), .big);
    std.mem.writeInt(u16, bytes[8..10], @intCast(axis_count), .big);
    std.mem.writeInt(u16, bytes[10..12], @intCast(axis_size), .big);
    std.mem.writeInt(u16, bytes[12..14], @intCast(options.instances.len), .big);
    std.mem.writeInt(u16, bytes[14..16], @intCast(instance_size), .big);
    const axis = bytes[header_len..][0..axis_size];
    @memcpy(axis[0..4], "wght");
    writeFixed(axis[4..8], 100);
    writeFixed(axis[8..12], 400);
    writeFixed(axis[12..16], 900);
    std.mem.writeInt(u16, axis[16..18], 0, .big);
    std.mem.writeInt(u16, axis[18..20], 257, .big);
    if (options.opsz) |opsz| {
        const opsz_axis = bytes[header_len + axis_size ..][0..axis_size];
        @memcpy(opsz_axis[0..4], "opsz");
        writeFixed(opsz_axis[4..8], opsz.min);
        writeFixed(opsz_axis[8..12], opsz.default);
        writeFixed(opsz_axis[12..16], opsz.max);
        std.mem.writeInt(u16, opsz_axis[16..18], 0, .big);
        std.mem.writeInt(u16, opsz_axis[18..20], 258, .big);
    }
    var instance_offset = header_len + axis_size * axis_count;
    for (options.instances, 0..) |instance, instance_index| {
        const record = bytes[instance_offset..][0..instance_size];
        const subfamily_id: u16 = @intCast(256 + instance_index * 2);
        std.mem.writeInt(u16, record[0..2], subfamily_id, .big);
        std.mem.writeInt(u16, record[2..4], 0, .big);
        writeFixed(record[4..8], instance.weight);
        if (options.opsz) |opsz| writeFixed(record[8..12], opsz.default);
        const postscript_offset = 4 + axis_count * 4;
        std.mem.writeInt(u16, record[postscript_offset..][0..2], subfamily_id + 1, .big);
        instance_offset += instance_size;
    }
    return bytes;
}

fn writeFixed(out: []u8, value: f32) void {
    const fixed: i32 = @intFromFloat(@round(value * 65536.0));
    std.mem.writeInt(i32, out[0..4], fixed, .big);
}

pub fn buildTestFont(allocator: std.mem.Allocator, options: TestFontOptions) ![]u8 {
    const name_table = try buildTestNameTable(allocator, options);
    defer allocator.free(name_table);
    const fvar_table = if (options.instances.len != 0 or options.opsz != null)
        try buildTestFvarTable(allocator, options)
    else
        null;
    defer if (fvar_table) |table| allocator.free(table);
    const os2_len = 96;
    const post_len = 32;
    const table_count: u16 = @as(u16, if (fvar_table != null) 4 else 3) + @as(u16, @intFromBool(options.cmap != null)) + @as(u16, @intFromBool(options.num_glyphs != null));
    const dir_len = @as(usize, table_count) * 16;
    const name_offset = 12 + dir_len;
    const os2_offset = align4(name_offset + name_table.len);
    const post_offset = align4(os2_offset + os2_len);
    const fvar_offset = align4(post_offset + post_len);
    const cmap_offset = align4(fvar_offset + (if (fvar_table) |table| table.len else 0));
    const maxp_offset = align4(cmap_offset + (if (options.cmap) |table| table.len else 0));
    const total = align4(maxp_offset + (if (options.num_glyphs != null) @as(usize, 6) else 0));
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], table_count, .big);
    std.mem.writeInt(u16, bytes[6..8], 16, .big);
    writeTestTableRecord(bytes, 0, "name", name_offset, name_table.len);
    writeTestTableRecord(bytes, 1, "OS/2", os2_offset, os2_len);
    writeTestTableRecord(bytes, 2, "post", post_offset, post_len);
    if (fvar_table) |table| {
        writeTestTableRecord(bytes, 3, "fvar", fvar_offset, table.len);
        @memcpy(bytes[fvar_offset..][0..table.len], table);
    }
    if (options.cmap) |table| {
        writeTestTableRecord(bytes, if (fvar_table != null) 4 else 3, "cmap", cmap_offset, table.len);
        @memcpy(bytes[cmap_offset..][0..table.len], table);
    }
    if (options.num_glyphs) |count| {
        const table_index = @as(usize, if (fvar_table != null) 4 else 3) + @intFromBool(options.cmap != null);
        writeTestTableRecord(bytes, table_index, "maxp", maxp_offset, 6);
        std.mem.writeInt(u32, bytes[maxp_offset..][0..4], 0x00005000, .big);
        std.mem.writeInt(u16, bytes[maxp_offset + 4 ..][0..2], count, .big);
    }
    @memcpy(bytes[name_offset..][0..name_table.len], name_table);
    const os2 = bytes[os2_offset..][0..os2_len];
    std.mem.writeInt(u16, os2[0..2], 4, .big);
    std.mem.writeInt(u16, os2[4..6], options.weight, .big);
    std.mem.writeInt(u16, os2[6..8], options.width_class, .big);
    var selection: u16 = 0;
    if (options.italic) selection |= 0x0001;
    std.mem.writeInt(u16, os2[62..64], selection, .big);
    const post = bytes[post_offset..][0..post_len];
    std.mem.writeInt(u32, post[0..4], 0x00020000, .big);
    if (options.italic) std.mem.writeInt(u32, post[4..8], 0xFFFF_0000, .big);
    if (options.monospaced) std.mem.writeInt(u32, post[12..16], 1, .big);
    return bytes;
}

pub const TestCoverageGroup = struct {
    start: u32,
    end: u32,
    glyph: u32 = 1,
};

pub fn buildTestCmap(allocator: std.mem.Allocator, groups: []const TestCoverageGroup, format: u16) ![]u8 {
    std.debug.assert(format == 12 or format == 13);
    const bytes = try allocator.alloc(u8, 12 + 16 + groups.len * 12);
    @memset(bytes, 0);
    std.mem.writeInt(u16, bytes[2..4], 1, .big);
    std.mem.writeInt(u16, bytes[4..6], 3, .big);
    std.mem.writeInt(u16, bytes[6..8], 10, .big);
    std.mem.writeInt(u32, bytes[8..12], 12, .big);
    const table = bytes[12..];
    std.mem.writeInt(u16, table[0..2], format, .big);
    std.mem.writeInt(u32, table[4..8], @intCast(table.len), .big);
    std.mem.writeInt(u32, table[12..16], @intCast(groups.len), .big);
    for (groups, 0..) |group, index| {
        const out = table[16 + index * 12 ..][0..12];
        std.mem.writeInt(u32, out[0..4], group.start, .big);
        std.mem.writeInt(u32, out[4..8], group.end, .big);
        std.mem.writeInt(u32, out[8..12], group.glyph, .big);
    }
    return bytes;
}

pub fn buildTestCollection(allocator: std.mem.Allocator, fonts: []const []const u8) ![]u8 {
    const header_len = 12 + fonts.len * 4;
    var total: usize = header_len;
    for (fonts) |font| total += align4(font.len);
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "ttcf");
    std.mem.writeInt(u32, bytes[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, bytes[8..12], @intCast(fonts.len), .big);
    var offset: usize = header_len;
    for (fonts, 0..) |font, index| {
        std.mem.writeInt(u32, bytes[12 + index * 4 ..][0..4], @intCast(offset), .big);
        @memcpy(bytes[offset..][0..font.len], font);
        const num_tables = std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .big);
        var table_index: usize = 0;
        while (table_index < num_tables) : (table_index += 1) {
            const record = bytes[offset + 12 + table_index * 16 ..][0..16];
            const table_offset = std.mem.readInt(u32, record[8..12], .big);
            std.mem.writeInt(u32, record[8..12], table_offset + @as(u32, @intCast(offset)), .big);
        }
        offset += align4(font.len);
    }
    return bytes;
}

fn writeTestNameRecord(
    name: []u8,
    index: usize,
    platform: u16,
    encoding: u16,
    language: u16,
    name_id: u16,
    strings_offset: usize,
    string_offset: usize,
    text: []const u8,
) usize {
    const record = name[6 + index * 12 ..][0..12];
    std.mem.writeInt(u16, record[0..2], platform, .big);
    std.mem.writeInt(u16, record[2..4], encoding, .big);
    std.mem.writeInt(u16, record[4..6], language, .big);
    std.mem.writeInt(u16, record[6..8], name_id, .big);
    const units = utf16Length(text);
    std.mem.writeInt(u16, record[8..10], @intCast(units * 2), .big);
    std.mem.writeInt(u16, record[10..12], @intCast(string_offset), .big);
    var unit_index: usize = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            std.mem.writeInt(u16, name[strings_offset + string_offset + unit_index * 2 ..][0..2], @intCast(codepoint), .big);
            unit_index += 1;
        } else {
            const value = codepoint - 0x10000;
            const high: u16 = @intCast(0xd800 + (value >> 10));
            const low: u16 = @intCast(0xdc00 + (value & 0x3ff));
            std.mem.writeInt(u16, name[strings_offset + string_offset + unit_index * 2 ..][0..2], high, .big);
            std.mem.writeInt(u16, name[strings_offset + string_offset + (unit_index + 1) * 2 ..][0..2], low, .big);
            unit_index += 2;
        }
    }
    return string_offset + units * 2;
}

fn utf16Length(text: []const u8) usize {
    var length: usize = 0;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        length += if (codepoint <= 0xffff) 1 else 2;
    }
    return length;
}

fn writeTestTableRecord(bytes: []u8, index: usize, tag: []const u8, offset: usize, length: usize) void {
    const record = bytes[12 + index * 16 ..][0..16];
    @memcpy(record[0..4], tag);
    std.mem.writeInt(u32, record[8..12], @intCast(offset), .big);
    std.mem.writeInt(u32, record[12..16], @intCast(length), .big);
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}
