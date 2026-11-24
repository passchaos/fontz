//! Deterministic URL/PostScript location and original TTC identity regressions.
const std = @import("std");
const api = @import("../metadata_index.zig");
const parse = @import("parse.zig");
const cache = @import("index_cache.zig");
const test_font = @import("test_font.zig");
const allocator = std.testing.allocator;

fn variableFont(prefix: []const u8) ![]u8 {
    const medium = try std.fmt.allocPrint(allocator, "{s}-Medium", .{prefix});
    defer allocator.free(medium);
    const regular = try std.fmt.allocPrint(allocator, "{s}-Regular", .{prefix});
    defer allocator.free(regular);
    const bold = try std.fmt.allocPrint(allocator, "{s}-Bold", .{prefix});
    defer allocator.free(bold);
    return test_font.buildTestFont(allocator, .{
        .family = prefix,
        .subfamily = "Medium",
        .postscript_name = medium,
        .weight = 500,
        .instances = &.{
            .{ .subfamily = "Regular", .postscript_name = regular, .weight = 400 },
            .{ .subfamily = "Bold", .postscript_name = bold, .weight = 700 },
            // The default face wins if an instance repeats its PostScript name.
            .{ .subfamily = "Medium", .postscript_name = medium, .weight = 500 },
        },
    });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    path: []const u8,
    cache_path: []const u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const sc = try variableFont("LocationSC");
        defer allocator.free(sc);
        const tc = try variableFont("LocationTC");
        defer allocator.free(tc);
        const hk = try variableFont("LocationHK");
        defer allocator.free(hk);
        const later = try test_font.buildTestFont(allocator, .{
            .family = "Later Sans",
            .postscript_name = "LaterSans-Regular",
        });
        defer allocator.free(later);
        const malformed = [_]u8{0} ** 12;
        // Valid metadata is packed into four entries, but its on-disk TTC
        // indexes are 1, 2, 4 and 5 because prefix/interior faces are invalid.
        const collection = try test_font.buildTestCollection(allocator, &.{ &malformed, sc, tc, &malformed, hk, later });
        defer allocator.free(collection);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "locations.ttc", .data = collection });
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &buffer);
        const root = try allocator.dupe(u8, buffer[0..root_len]);
        errdefer allocator.free(root);
        const path = try std.fs.path.join(allocator, &.{ root, "locations.ttc" });
        errdefer allocator.free(path);
        const cache_path = try std.fs.path.join(allocator, &.{ root, "metadata.bin" });
        return .{ .tmp = tmp, .root = root, .path = path, .cache_path = cache_path };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        allocator.free(self.root);
        allocator.free(self.path);
        allocator.free(self.cache_path);
    }
};

fn expectLocation(expected: api.FaceLocation, actual: ?api.FaceLocation) !void {
    const location = actual orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected.face_index, location.face_index);
    try std.testing.expectEqual(expected.named_instance, location.named_instance);
}

test "face location preserves original TTC indexes and named-instance identities" {
    const io = std.testing.io;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var file = try std.Io.Dir.openFileAbsolute(io, fixture.path, .{});
    defer file.close(io);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var persist = std.heap.ArenaAllocator.init(allocator);
    defer persist.deinit();
    const metadata = (try parse.readFileMetadata(io, file, scratch.allocator(), persist.allocator(), 128 * 1024, 64 * 1024 * 1024)).?;
    try std.testing.expectEqual(@as(usize, 4), metadata.count);
    for (metadata.faces[0..metadata.count], [_]u32{ 1, 2, 4, 5 }) |face, expected| {
        try std.testing.expectEqual(expected, face.face_index);
    }
    const roots = [_][]const u8{fixture.root};
    const options = api.Options{ .roots = &roots, .enable_cache = false };
    api.resetForTesting(io);
    defer api.resetForTesting(io);
    const cases = [_]struct { name: []const u8, location: api.FaceLocation }{
        .{ .name = "LocationSC-Medium", .location = .{ .face_index = 1 } },
        .{ .name = "LocationSC-Regular", .location = .{ .face_index = 1, .named_instance = 1 } },
        .{ .name = "LocationSC-Bold", .location = .{ .face_index = 1, .named_instance = 2 } },
        .{ .name = "locationtc-regular", .location = .{ .face_index = 2, .named_instance = 1 } },
        .{ .name = "LocationHK-Regular", .location = .{ .face_index = 4, .named_instance = 1 } },
        .{ .name = "LaterSans-Regular", .location = .{ .face_index = 5 } },
    };
    for (cases) |case| {
        try expectLocation(case.location, try api.findFaceLocationByPostScript(io, fixture.path, case.name));
        try std.testing.expectEqual(@as(?u32, case.location.face_index), try api.findFaceIndexByPostScript(io, fixture.path, case.name));
        const catalog = api.findByPostScript(io, case.name, options) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.location.face_index, catalog.face_index);
        try std.testing.expectEqual(case.location.named_instance, catalog.named_instance);
    }
    const selected = api.findFace(io, .{ .family = "LocationSC", .weight = 400 }, options).?;
    try std.testing.expectEqual(@as(u32, 1), selected.face_index);
    try std.testing.expectEqual(@as(u16, 1), selected.named_instance);
    try std.testing.expect((try api.findFaceLocationByPostScript(io, fixture.path, "Missing-Regular")) == null);
    try std.testing.expect((try api.findFaceIndexByPostScript(io, fixture.path, "Missing-Regular")) == null);
    // An empty identity is rejected without opening its path.
    try std.testing.expect((try api.findFaceLocationByPostScript(io, "/missing/fontz.ttf", "")) == null);
}

test "face location keeps standalone fvar record indexes after invalid instances" {
    const io = std.testing.io;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const font = try variableFont("Standalone");
    defer allocator.free(font);
    // A non-font extension keeps this direct-path fixture out of catalog scans.
    const path = try std.fs.path.join(allocator, &.{ fixture.root, "standalone.bin" });
    defer allocator.free(path);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "standalone.bin", .data = font });
    try expectLocation(.{ .face_index = 0, .named_instance = 1 }, try api.findFaceLocationByPostScript(io, path, "Standalone-Regular"));
    try expectLocation(.{ .face_index = 0 }, try api.findFaceLocationByPostScript(io, path, "Standalone-Medium"));

    const table_count = std.mem.readInt(u16, font[4..6], .big);
    var fvar_offset: ?usize = null;
    for (0..table_count) |table_index| {
        const record = font[12 + table_index * 16 ..][0..16];
        if (std.mem.eql(u8, record[0..4], "fvar")) fvar_offset = std.mem.readInt(u32, record[8..12], .big);
    }
    const offset = fvar_offset.?;
    const axes_start = std.mem.readInt(u16, font[offset + 4 ..][0..2], .big);
    const axis_count = std.mem.readInt(u16, font[offset + 8 ..][0..2], .big);
    const axis_size = std.mem.readInt(u16, font[offset + 10 ..][0..2], .big);
    const first_instance = offset + axes_start + @as(usize, axis_count) * axis_size;
    std.mem.writeInt(u16, font[first_instance..][0..2], 0, .big);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "standalone.bin", .data = font });
    try std.testing.expect((try api.findFaceLocationByPostScript(io, path, "Standalone-Regular")) == null);
    // The remaining Bold instance is still fvar record 1 => named_instance 2.
    try expectLocation(.{ .face_index = 0, .named_instance = 2 }, try api.findFaceLocationByPostScript(io, path, "Standalone-Bold"));
    try std.testing.expectEqual(@as(?u32, 0), try api.findFaceIndexByPostScript(io, path, "Standalone-Bold"));
}

test "face location cache preserves TTC identity and rejects version 2" {
    const io = std.testing.io;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const roots = [_][]const u8{fixture.root};
    const options = api.Options{ .roots = &roots, .cache_path = fixture.cache_path };
    api.resetForTesting(io);
    defer api.resetForTesting(io);
    const fresh = api.findByPostScript(io, "LocationHK-Regular", options).?;
    try std.testing.expectEqual(@as(u32, 4), fresh.face_index);
    try std.testing.expectEqual(@as(u16, 1), fresh.named_instance);
    try std.testing.expect(!api.lastBuildUsedCache());
    api.resetForTesting(io);
    const loaded = api.findByPostScript(io, "LocationHK-Regular", options).?;
    try std.testing.expectEqual(@as(u32, 4), loaded.face_index);
    try std.testing.expectEqual(@as(u16, 1), loaded.named_instance);
    try std.testing.expect(api.lastBuildUsedCache());

    const bytes = try fixture.tmp.dir.readFileAlloc(io, "metadata.bin", allocator, .limited(cache.max_cache_bytes));
    defer allocator.free(bytes);
    std.mem.writeInt(u32, bytes[cache.magic.len..][0..4], 2, .little);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "metadata.bin", .data = bytes });
    api.resetForTesting(io);
    const rebuilt = api.findByPostScript(io, "LocationHK-Regular", options).?;
    try std.testing.expectEqual(@as(u32, 4), rebuilt.face_index);
    try std.testing.expectEqual(@as(u16, 1), rebuilt.named_instance);
    try std.testing.expect(!api.lastBuildUsedCache());
    try expectLocation(.{ .face_index = 4, .named_instance = 1 }, try api.findFaceLocationByPostScript(io, fixture.path, "LocationHK-Regular"));
}
