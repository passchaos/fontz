const std = @import("std");
const types = @import("../types.zig");
const Discovery = @import("../pure_discovery.zig").Discovery;
const index = @import("../metadata_index.zig");
const font = @import("test_font.zig");
const fixture = @import("test_extended.zig");
const unit = @import("numeric_unit_tests.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = try a.dupe(u8, buffer[0..len]) };
    }
    fn deinit(self: *Fixture) void {
        index.reset(io);
        a.free(self.root);
        self.tmp.cleanup();
    }
    fn write(self: *Fixture, name: []const u8, options: font.TestFontOptions) !void {
        const bytes = try font.buildTestFont(a, options);
        defer a.free(bytes);
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
    fn discovery(self: *Fixture) !Discovery {
        index.reset(io);
        const roots = [_][]const u8{self.root};
        try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
        return Discovery.initWithRoots(a, &roots);
    }
};

test "unicode cmap cold discovery accepts new formats and default sequence from same real face" {
    for ([_]u16{ 2, 8, 10 }) |format| {
        var inventory = try Fixture.init();
        defer inventory.deinit();
        const subtable = try fixture.sample(a, format);
        defer a.free(subtable);
        const table = try fixture.withVariation(a, subtable, fixture.encoding(format), fixture.base(format), false);
        defer a.free(table);
        try inventory.write("font.ttf", .{ .family = "Unicode Discovery", .postscript_name = "UnicodeDiscovery-Regular", .cmap = table, .num_glyphs = 8 });
        var discovery = try inventory.discovery();
        defer discovery.deinit();
        var query = types.Query{ .family = "Unicode Discovery", .postscript_name = "UnicodeDiscovery-Regular", .required_codepoint = fixture.base(format), .max_candidates = 1 };
        var scalar = try discovery.resolve(a, query);
        defer scalar.deinit();
        try std.testing.expectEqual(@as(usize, 1), scalar.candidates.len);
        try std.testing.expectEqual(types.Provider.metadata_index, scalar.candidates[0].provider);
        try std.testing.expectEqual(@as(?u32, 0), scalar.candidates[0].face_index);
        try std.testing.expectEqual(@as(u64, 1), discovery.stats().coverage_file_opens);
        try std.testing.expectEqual(@as(u64, 5), discovery.stats().coverage_read_calls);
        query.required_variation_selector = 0xfe0f;
        var sequence = try discovery.resolve(a, query);
        defer sequence.deinit();
        try std.testing.expectEqual(@as(usize, 1), sequence.candidates.len);
        try std.testing.expectEqualStrings(scalar.candidates[0].path, sequence.candidates[0].path);
        try std.testing.expectEqual(@as(u64, 1), discovery.stats().coverage_file_opens);
    }
}

test "unicode cmap discovery rejects entire invalid domain missing maxp and codepage map" {
    var inventory = try Fixture.init();
    defer inventory.deinit();
    for ([_]u16{ 2, 8, 10 }) |format| {
        const subtable = try unit.badDomain(format);
        defer a.free(subtable);
        const table = try fixture.wrap(a, subtable, 0, fixture.encoding(format));
        defer a.free(table);
        const name = try std.fmt.allocPrint(a, "bad{d}.ttf", .{format});
        defer a.free(name);
        const ps = try std.fmt.allocPrint(a, "UnicodeBad-{d}", .{format});
        defer a.free(ps);
        try inventory.write(name, .{ .family = "Unicode Reject", .postscript_name = ps, .cmap = table, .num_glyphs = 8 });
    }
    const ten = try fixture.buildFormat10(a, 'A', &.{1});
    defer a.free(ten);
    const missing = try fixture.wrap(a, ten, 0, 4);
    defer a.free(missing);
    try inventory.write("missing.ttf", .{ .family = "Unicode Reject", .postscript_name = "UnicodeMissing", .cmap = missing });
    const two = try fixture.buildFormat2(a, &.{.{ .high = 0, .first = 'A', .glyphs = &.{1} }});
    defer a.free(two);
    const codepage = try fixture.wrap(a, two, 3, 2);
    defer a.free(codepage);
    try inventory.write("codepage.ttf", .{ .family = "Unicode Reject", .postscript_name = "UnicodeCodepage", .cmap = codepage, .num_glyphs = 8 });
    var discovery = try inventory.discovery();
    defer discovery.deinit();
    for ([_][]const u8{ "UnicodeBad-2", "UnicodeBad-8", "UnicodeBad-10", "UnicodeMissing", "UnicodeCodepage" }) |ps| {
        var result = try discovery.resolve(a, .{ .family = "Unicode Reject", .postscript_name = ps, .required_codepoint = 'A', .max_candidates = 1 });
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
    }
}

test "unicode cmap discovery retains original TTC face and named instance for format10" {
    var inventory = try Fixture.init();
    defer inventory.deinit();
    const subtable = try fixture.buildFormat10(a, 0x1f600, &.{ 1, 0 });
    defer a.free(subtable);
    const table = try fixture.withVariation(a, subtable, 4, 0x1f600, false);
    defer a.free(table);
    const bytes = try font.buildTestFont(a, .{ .family = "Unicode TTC", .postscript_name = "UnicodeTTC-Regular", .cmap = table, .num_glyphs = 2, .instances = &.{
        .{ .subfamily = "Medium", .postscript_name = "UnicodeTTC-Medium", .weight = 500 },
        .{ .subfamily = "Light", .postscript_name = "UnicodeTTC-Light", .weight = 300 },
    } });
    defer a.free(bytes);
    const bad = [_]u8{0} ** 12;
    const collection = try font.buildTestCollection(a, &.{ &bad, bytes });
    defer a.free(collection);
    try inventory.tmp.dir.writeFile(io, .{ .sub_path = "font.ttc", .data = collection });
    var discovery = try inventory.discovery();
    defer discovery.deinit();
    var result = try discovery.resolve(a, .{ .family = "Unicode TTC", .weight = 300, .required_codepoint = 0x1f600, .required_variation_selector = 0xfe0f, .max_candidates = 1 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
    try std.testing.expectEqual(@as(?u32, 1), result.candidates[0].face_index);
    try std.testing.expectEqual(@as(u16, 2), result.candidates[0].named_instance);
    try std.testing.expectEqualStrings("UnicodeTTC-Light", result.candidates[0].postscript_name.?);
}
