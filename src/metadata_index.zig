//! Bounded system-font metadata discovery for concrete `font-family` names.
//!
//! The index reads only sfnt headers plus `name`/`OS/2` tables; it never
//! rasterizes and never installs a face until a document selects it. Discovery
//! is opt-in through `ResourcePolicy.allow_system_fonts` because ambient
//! filesystem access is a caller decision. The process-wide index is bounded by
//! file, face, per-table and total metadata budgets.

const std = @import("std");
const builtin = @import("builtin");
const family_mod = @import("family.zig");

pub const Face = struct {
    /// Absolute path as `root/entry.path` under the scanned font root.
    path: []const u8,
    /// Zero-based face inside a TrueType/OpenType collection, otherwise 0.
    face_index: u32 = 0,
    family: []const u8,
    subfamily: []const u8,
    weight: u16 = 400,
    stretch: u16 = 5,
    italic: bool = false,
};

pub const Options = struct {
    /// Override the platform roots (tests and embedders).
    roots: ?[]const []const u8 = null,
    max_files: usize = 4096,
    max_faces: usize = 4096,
    /// Per-file cap for the `name` table. Larger tables are skipped.
    max_name_table_bytes: usize = 128 * 1024,
    /// Total metadata bytes read across the scan.
    max_total_metadata_bytes: usize = 64 * 1024 * 1024,
};

const Index = struct {
    arena: std.heap.ArenaAllocator,
    faces: []const Face,
};

var index_mutex: std.Io.Mutex = .init;
var index_cache: ?Index = null;

/// Reset the process-wide index. Tests only; the production cache lives for the
/// process lifetime.
pub fn resetForTesting(io: std.Io) void {
    index_mutex.lockUncancelable(io);
    defer index_mutex.unlock(io);
    if (index_cache) |*cached| cached.arena.deinit();
    index_cache = null;
}

/// Find the best installed face for an authored CSS family list.
///
/// Items are considered in order; generic keywords are skipped. A face matches
/// when its normalized family equals the normalized authored item. The best
/// face then minimizes italic, weight and stretch distance. Returns a pointer
/// into the process-wide index.
pub fn findFamily(
    io: std.Io,
    families: []const u8,
    weight: u16,
    italic: bool,
    stretch: u16,
    options: Options,
) ?*const Face {
    const index = ensureIndex(io, options) orelse return null;
    var iterator = family_mod.FamilyIterator.init(families);
    while (iterator.next()) |family| {
        if (family.len == 0 or genericFamily(family)) continue;
        var best: ?*const Face = null;
        var best_score: u64 = std.math.maxInt(u64);
        for (index.faces) |*face| {
            if (!familyNamesEqual(face.family, family)) continue;
            const score = faceScore(face, weight, italic, stretch);
            if (score < best_score) {
                best = face;
                best_score = score;
            }
        }
        if (best) |face| return face;
    }
    return null;
}

fn ensureIndex(io: std.Io, options: Options) ?*const Index {
    index_mutex.lockUncancelable(io);
    defer index_mutex.unlock(io);
    if (index_cache == null) {
        index_cache = buildIndex(io, options);
    }
    return if (index_cache) |*cached| cached else null;
}

fn buildIndex(io: std.Io, options: Options) ?Index {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var faces: std.ArrayList(Face) = .empty;
    const roots = options.roots orelse platformRoots();
    var files_seen: usize = 0;
    var metadata_bytes: usize = 0;
    for (roots) |root| {
        if (files_seen >= options.max_files or
            faces.items.len >= options.max_faces or
            metadata_bytes >= options.max_total_metadata_bytes)
        {
            break;
        }
        var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);
        var walker = root_dir.walk(allocator) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !isFontFile(entry.basename)) continue;
            if (files_seen >= options.max_files or
                faces.items.len >= options.max_faces or
                metadata_bytes >= options.max_total_metadata_bytes)
            {
                break;
            }
            files_seen += 1;
            var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
            defer file.close(io);
            var collection = readFileMetadata(
                io,
                file,
                allocator,
                options.max_name_table_bytes,
                options.max_total_metadata_bytes - metadata_bytes,
            ) catch continue orelse continue;
            metadata_bytes += collection.bytes_read;
            const path = std.fs.path.join(allocator, &.{ root, entry.path }) catch continue;
            for (collection.faces[0..collection.count], 0..) |meta, face_index| {
                if (faces.items.len >= options.max_faces) break;
                faces.append(allocator, .{
                    .path = path,
                    .face_index = @intCast(face_index),
                    .family = meta.family,
                    .subfamily = meta.subfamily,
                    .weight = meta.weight,
                    .stretch = meta.stretch,
                    .italic = meta.italic,
                }) catch continue;
            }
        }
    }
    const owned = faces.toOwnedSlice(allocator) catch {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .faces = owned };
}

const FaceMetadata = struct {
    family: []const u8,
    subfamily: []const u8,
    weight: u16,
    stretch: u16,
    italic: bool,
    bytes_read: usize,
};

const max_collection_faces = 64;

const FileMetadata = struct {
    faces: [max_collection_faces]FaceMetadata,
    count: usize,
    bytes_read: usize,
};

fn readFileMetadata(
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
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
            allocator,
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
    const offsets_bytes = try allocator.alloc(u8, offsets_len);
    if (try file.readPositionalAll(io, offsets_bytes, 12) != offsets_len) return null;
    result.bytes_read += offsets_len;
    for (0..num_fonts) |face_index| {
        const offset = std.mem.readInt(u32, offsets_bytes[face_index * 4 ..][0..4], .big);
        const meta = try readSfntMetadata(
            io,
            file,
            allocator,
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

fn readSfntMetadata(
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
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
    }
    const name_table = name_record orelse return null;
    if (name_table.length < 6 or name_table.length > max_name_table_bytes) return null;
    const name_len = @as(usize, name_table.length);
    if (name_len > remaining_bytes -| bytes_read) return null;
    const name_bytes = try allocator.alloc(u8, name_len);
    if (try file.readPositionalAll(io, name_bytes, name_table.offset) != name_len) return null;
    bytes_read += name_len;
    const names = parseNameTable(name_bytes, allocator) orelse return null;
    var weight: u16 = 0;
    var stretch: u16 = 5;
    var italic = names.subfamilyItalic;
    if (os2_record) |os2| {
        if (os2.length >= 64 and os2.length <= 4096) {
            const os2_len = @as(usize, os2.length);
            if (os2_len > remaining_bytes -| bytes_read) return null;
            const os2_bytes = try allocator.alloc(u8, os2_len);
            if (try file.readPositionalAll(io, os2_bytes, os2.offset) == os2_len) {
                bytes_read += os2_len;
                weight = std.mem.readInt(u16, os2_bytes[4..6], .big);
                stretch = std.mem.readInt(u16, os2_bytes[6..8], .big);
                if (os2_len >= 64) {
                    const selection = std.mem.readInt(u16, os2_bytes[62..64], .big);
                    italic = (selection & 0x0001) != 0 or (selection & 0x0200) != 0;
                }
            }
        }
    }
    if (weight == 0) weight = names.subfamilyWeight;
    return .{
        .family = names.family,
        .subfamily = names.subfamily,
        .weight = weight,
        .stretch = stretch,
        .italic = italic,
        .bytes_read = bytes_read,
    };
}

const TableRecord = struct {
    offset: u32,
    length: u32,
};

const Names = struct {
    family: []const u8,
    subfamily: []const u8,
    subfamilyWeight: u16,
    subfamilyItalic: bool,
};

fn parseNameTable(bytes: []const u8, allocator: std.mem.Allocator) ?Names {
    if (bytes.len < 6) return null;
    const count = std.mem.readInt(u16, bytes[2..4], .big);
    const string_offset = std.mem.readInt(u16, bytes[4..6], .big);
    if (count == 0 or count > 4096) return null;
    if (bytes.len < 6 + @as(usize, count) * 12) return null;
    var family: ?[]const u8 = null;
    var typographic_family: ?[]const u8 = null;
    var subfamily: ?[]const u8 = null;
    var typographic_subfamily: ?[]const u8 = null;
    var family_score: u8 = 0;
    var typographic_family_score: u8 = 0;
    var subfamily_score: u8 = 0;
    var typographic_subfamily_score: u8 = 0;
    var record_index: usize = 0;
    while (record_index < count) : (record_index += 1) {
        const record = bytes[6 + record_index * 12 ..][0..12];
        const platform = std.mem.readInt(u16, record[0..2], .big);
        const encoding = std.mem.readInt(u16, record[2..4], .big);
        const language = std.mem.readInt(u16, record[4..6], .big);
        const name_id = std.mem.readInt(u16, record[6..8], .big);
        const length = std.mem.readInt(u16, record[8..10], .big);
        const offset = std.mem.readInt(u16, record[10..12], .big);
        if (name_id != 1 and name_id != 2 and name_id != 16 and name_id != 17) continue;
        const start = @as(usize, string_offset) + offset;
        if (start > bytes.len or length > bytes.len - start) continue;
        const raw = bytes[start..][0..length];
        const score = nameScore(platform, encoding, language);
        if (score == 0) continue;
        const decoded = decodeName(allocator, platform, raw) orelse continue;
        switch (name_id) {
            16 => if (score > typographic_family_score) {
                typographic_family = decoded;
                typographic_family_score = score;
            },
            1 => if (score > family_score) {
                family = decoded;
                family_score = score;
            },
            17 => if (score > typographic_subfamily_score) {
                typographic_subfamily = decoded;
                typographic_subfamily_score = score;
            },
            2 => if (score > subfamily_score) {
                subfamily = decoded;
                subfamily_score = score;
            },
            else => {},
        }
    }
    const resolved_family = typographic_family orelse family orelse return null;
    const resolved_subfamily = typographic_subfamily orelse subfamily orelse "Regular";
    return .{
        .family = resolved_family,
        .subfamily = resolved_subfamily,
        .subfamilyWeight = weightFromSubfamily(resolved_subfamily),
        .subfamilyItalic = italicFromSubfamily(resolved_subfamily),
    };
}

fn nameScore(platform: u16, encoding: u16, language: u16) u8 {
    return switch (platform) {
        3 => switch (encoding) {
            1, 10 => if (language == 0x0409) 6 else if (language == 0) 5 else 4,
            else => 0,
        },
        0 => 5,
        1 => if (encoding == 0 and language == 0) 3 else 0,
        else => 0,
    };
}

fn decodeName(allocator: std.mem.Allocator, platform: u16, raw: []const u8) ?[]const u8 {
    if (platform == 1) {
        const out = allocator.alloc(u8, raw.len) catch return null;
        for (raw, out) |c, *dest| dest.* = if (c < 0x80) c else '?';
        return trimNul(out);
    }
    if (raw.len % 2 != 0) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
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
        out.appendSlice(allocator, buffer[0..encoded_len]) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn trimNul(bytes: []u8) []const u8 {
    var end = bytes.len;
    while (end != 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
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

fn faceScore(face: *const Face, weight: u16, italic: bool, stretch: u16) u64 {
    const weight_distance: u64 = if (face.weight >= weight)
        face.weight - weight
    else
        weight - face.weight;
    const stretch_distance: u64 = if (face.stretch >= stretch)
        face.stretch - stretch
    else
        stretch - face.stretch;
    const italic_penalty: u64 = if (face.italic == italic) 0 else 1000;
    return italic_penalty + weight_distance * 4 + stretch_distance;
}

/// Compare family names case-insensitively ignoring spaces, punctuation and
/// separators. `M PLUS 1p` therefore matches an authored `Mplus 1p`.
pub fn familyNamesEqual(a: []const u8, b: []const u8) bool {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (true) {
        while (a_index < a.len and !std.ascii.isAlphanumeric(a[a_index])) a_index += 1;
        while (b_index < b.len and !std.ascii.isAlphanumeric(b[b_index])) b_index += 1;
        if (a_index == a.len or b_index == b.len) {
            return a_index == a.len and b_index == b.len;
        }
        if (std.ascii.toLower(a[a_index]) != std.ascii.toLower(b[b_index])) return false;
        a_index += 1;
        b_index += 1;
    }
}

fn genericFamily(family: []const u8) bool {
    inline for (.{
        "serif",        "sans-serif", "monospace", "cursive",
        "fantasy",      "system-ui",  "ui-serif",  "ui-sans-serif",
        "ui-monospace", "ui-rounded", "math",      "emoji",
        "fangsong",
    }) |generic| {
        if (std.ascii.eqlIgnoreCase(family, generic)) return true;
    }
    return false;
}

fn isFontFile(basename: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(basename, ".ttf") or
        std.ascii.endsWithIgnoreCase(basename, ".otf") or
        std.ascii.endsWithIgnoreCase(basename, ".ttc") or
        std.ascii.endsWithIgnoreCase(basename, ".otc");
}

fn isSfntVersion(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    return std.mem.eql(u8, bytes, "true") or
        std.mem.eql(u8, bytes, "typ1") or
        std.mem.eql(u8, bytes, "OTTO") or
        std.mem.readInt(u32, bytes[0..4], .big) == 0x00010000;
}

fn platformRoots() []const []const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => &.{
            "/usr/share/fonts",
            "/usr/local/share/fonts",
        },
        .macos, .ios, .tvos, .watchos, .visionos => &.{
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
            "/Library/Fonts",
        },
        .windows => &.{
            "C:\\Windows\\Fonts",
        },
        else => &.{},
    };
}

test "sfnt name parsing matches family and style metadata" {
    const allocator = std.testing.allocator;
    const font = try buildTestFont(allocator);
    defer allocator.free(font);
    const names = parseNameTable(font[28..], allocator).?;
    defer {
        allocator.free(names.family);
        allocator.free(names.subfamily);
    }
    try std.testing.expectEqualStrings("Test Sans", names.family);
    try std.testing.expectEqualStrings("Bold Italic", names.subfamily);
    try std.testing.expectEqual(@as(u16, 700), names.subfamilyWeight);
    try std.testing.expect(names.subfamilyItalic);
}

test "family comparison ignores separators and case" {
    try std.testing.expect(familyNamesEqual("Noto Sans", "noto sans"));
    try std.testing.expect(familyNamesEqual("M PLUS 1p", "Mplus 1p"));
    try std.testing.expect(!familyNamesEqual("Noto Sans", "Noto Serif"));
}

test "index resolves a family from configured roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try buildTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "TestSans-BoldItalic.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findFamily(
        io,
        "\"Test Sans\", sans-serif",
        700,
        true,
        5,
        .{ .roots = &roots },
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Test Sans", face.family);
    try std.testing.expectEqual(@as(u16, 700), face.weight);
    try std.testing.expect(face.italic);
}

/// Minimal sfnt with one `name` table (family "Test Sans", subfamily
/// "Bold Italic"). The metadata reader only needs the table directory and the
/// name records, so no glyph tables are required.
fn buildTestFont(allocator: std.mem.Allocator) ![]u8 {
    const family = "Test Sans";
    const subfamily = "Bold Italic";
    const record_count = 2;
    const strings_offset = 6 + record_count * 12;
    const name_len = strings_offset + (family.len + subfamily.len) * 2;
    const total = 12 + 16 + name_len;
    const bytes = try allocator.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], 1, .big);
    @memcpy(bytes[12..16], "name");
    std.mem.writeInt(u32, bytes[20..24], 28, .big);
    std.mem.writeInt(u32, bytes[24..28], @intCast(name_len), .big);
    const name = bytes[28..];
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], record_count, .big);
    std.mem.writeInt(u16, name[4..6], @intCast(strings_offset), .big);
    writeNameRecord(name, 0, 1, 0, family);
    writeNameRecord(name, 1, 2, family.len * 2, subfamily);
    return bytes;
}

fn writeNameRecord(name: []u8, index: usize, name_id: u16, string_offset: usize, text: []const u8) void {
    const record = name[6 + index * 12 ..][0..12];
    std.mem.writeInt(u16, record[0..2], 3, .big);
    std.mem.writeInt(u16, record[2..4], 1, .big);
    std.mem.writeInt(u16, record[4..6], 0x0409, .big);
    std.mem.writeInt(u16, record[6..8], name_id, .big);
    std.mem.writeInt(u16, record[8..10], @intCast(text.len * 2), .big);
    std.mem.writeInt(u16, record[10..12], @intCast(string_offset), .big);
    const strings = 6 + 2 * 12;
    for (text, 0..) |c, i| {
        const position = strings + string_offset + i * 2;
        std.mem.writeInt(u16, name[position..][0..2], c, .big);
    }
}
