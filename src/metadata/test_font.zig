//! Synthetic sfnt builders used by metadata parsing/index tests.

const std = @import("std");

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
};

pub fn buildTestNameTable(allocator: std.mem.Allocator, options: TestFontOptions) ![]u8 {
    const record_count: usize = 4 + @as(usize, @intFromBool(options.localized_family != null));
    const strings_offset = 6 + record_count * 12;
    const full_name = options.full_name orelse options.family;
    var string_len: usize = (options.family.len + options.subfamily.len +
        full_name.len + options.postscript_name.len) * 2;
    if (options.localized_family) |localized| string_len += localized.name.len * 2;
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
    _ = writeTestNameRecord(bytes, record_index, 3, 1, 0x0409, 6, strings_offset, offset, options.postscript_name);
    return bytes;
}

pub fn buildTestFont(allocator: std.mem.Allocator, options: TestFontOptions) ![]u8 {
    const name_table = try buildTestNameTable(allocator, options);
    defer allocator.free(name_table);
    const os2_len = 96;
    const post_len = 32;
    const dir_len = 3 * 16;
    const name_offset = 12 + dir_len;
    const os2_offset = align4(name_offset + name_table.len);
    const post_offset = align4(os2_offset + os2_len);
    const total = align4(post_offset + post_len);
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], 3, .big);
    std.mem.writeInt(u16, bytes[6..8], 16, .big);
    writeTestTableRecord(bytes, 0, "name", name_offset, name_table.len);
    writeTestTableRecord(bytes, 1, "OS/2", os2_offset, os2_len);
    writeTestTableRecord(bytes, 2, "post", post_offset, post_len);
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
