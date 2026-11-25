//! Descriptor-level CSS matching through real sfnt/TTC discovery.
const std = @import("std");
const types = @import("types.zig");
const Discovery = @import("pure_discovery.zig").Discovery;
const index = @import("metadata_index.zig");
const font = @import("metadata/test_font.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const Traits = struct {
    weight: u16 = 400,
    width: u16 = 5,
    italic: bool = false,
    oblique: bool = false,
};

const Case = struct {
    query: types.Query,
    faces: []const Traits,
    expected: usize,
};

fn expectCollection(case: Case, reverse: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer index.reset(io);
    const cmap = try font.buildTestCmap(a, &.{.{ .start = 'B', .end = 'B' }}, 12);
    defer a.free(cmap);
    var bytes: [4][]const u8 = undefined;
    var count: usize = 0;
    defer for (bytes[0..count]) |value| a.free(value);
    for (0..case.faces.len) |position| {
        const original = if (reverse) case.faces.len - 1 - position else position;
        const traits = case.faces[original];
        const postscript = try std.fmt.allocPrint(a, "CSS-Face-{d}", .{original});
        defer a.free(postscript);
        bytes[position] = try font.buildTestFont(a, .{
            .family = "CSS Fixture",
            .postscript_name = postscript,
            .weight = traits.weight,
            .width_class = traits.width,
            .italic = traits.italic,
            .oblique = traits.oblique,
            .cmap = cmap,
        });
        count += 1;
    }
    const collection = try font.buildTestCollection(a, bytes[0..count]);
    defer a.free(collection);
    try tmp.dir.writeFile(io, .{ .sub_path = "css.ttc", .data = collection });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const roots = [_][]const u8{root_buffer[0..root_len]};
    index.reset(io);
    try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
    var discovery = try Discovery.initWithRoots(a, &roots);
    defer discovery.deinit();
    const expected_ps = try std.fmt.allocPrint(a, "CSS-Face-{d}", .{case.expected});
    defer a.free(expected_ps);
    const expected_index: u32 = @intCast(if (reverse) count - 1 - case.expected else case.expected);
    for ([_]?u21{ null, 'B' }) |coverage| {
        var query = case.query;
        query.family = "CSS Fixture";
        query.required_codepoint = coverage;
        query.max_candidates = 1;
        var result = try discovery.resolve(a, query);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
        const selected = result.candidates[0];
        try std.testing.expectEqualStrings(expected_ps, selected.postscript_name.?);
        const raw_weight = case.faces[case.expected].weight;
        try std.testing.expectEqual(if (raw_weight == 0) @as(u16, 400) else raw_weight, selected.weight);
        try std.testing.expectEqual(@as(?u32, expected_index), selected.face_index);
        try std.testing.expectEqual(expected_index, selected.provider_index);
        try std.testing.expectEqual(@as(u16, 0), selected.named_instance);
        try std.testing.expect(std.mem.endsWith(u8, selected.path, "/css.ttc"));
    }
}

test "coverage matching CSS descriptor phases keep distinct weights and widths order independent" {
    const cases = [_]Case{
        .{ .query = .{ .family = "", .weight = 450 }, .faces = &.{ .{ .weight = 400 }, .{ .weight = 500 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 400 }, .faces = &.{ .{ .weight = 500 }, .{ .weight = 450 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 470 }, .faces = &.{ .{ .weight = 400 }, .{ .weight = 500 }, .{ .weight = 480 } }, .expected = 2 },
        .{ .query = .{ .family = "", .weight = 490 }, .faces = &.{ .{ .weight = 600 }, .{ .weight = 400 }, .{ .weight = 480 } }, .expected = 2 },
        .{ .query = .{ .family = "", .weight = 500 }, .faces = &.{ .{ .weight = 501 }, .{ .weight = 480 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 500 }, .faces = &.{ .{ .weight = 700 }, .{ .weight = 501 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 399 }, .faces = &.{ .{ .weight = 400 }, .{ .weight = 300 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 100 }, .faces = &.{ .{ .weight = 900 }, .{ .weight = 300 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 300 }, .faces = &.{ .{ .weight = 100 }, .{ .weight = 200 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 501 }, .faces = &.{ .{ .weight = 500 }, .{ .weight = 700 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 700 }, .faces = &.{ .{ .weight = 300 }, .{ .weight = 500 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 600 }, .faces = &.{ .{ .weight = 800 }, .{ .weight = 700 } }, .expected = 1 },
        .{ .query = .{ .family = "", .weight = 1000 }, .faces = &.{ .{ .weight = 300 }, .{ .weight = 900 } }, .expected = 1 },
        .{ .query = .{ .family = "", .stretch = 150 }, .faces = &.{ .{ .width = 5 }, .{ .width = 7 } }, .expected = 1 },
        .{ .query = .{ .family = "", .stretch = 50 }, .faces = &.{ .{ .width = 9 }, .{ .width = 3 } }, .expected = 1 },
        .{ .query = .{ .family = "", .stretch = 100 }, .faces = &.{ .{ .width = 6 }, .{ .width = 3 } }, .expected = 1 },
        .{ .query = .{ .family = "", .stretch = 101 }, .faces = &.{ .{ .width = 5 }, .{ .width = 9 } }, .expected = 1 },
        // Width precedes style even when the style/weight match is exact.
        .{ .query = .{ .family = "", .style = .italic }, .faces = &.{ .{ .width = 3, .italic = true }, .{ .weight = 900 } }, .expected = 1 },
        // Style precedes weight even when its complete distance is large.
        .{ .query = .{ .family = "" }, .faces = &.{ .{ .italic = true }, .{ .weight = 900 } }, .expected = 1 },
        .{ .query = .{ .family = "" }, .faces = &.{ .{ .italic = true }, .{ .weight = 900, .oblique = true } }, .expected = 1 },
        .{ .query = .{ .family = "", .style = .italic }, .faces = &.{ .{}, .{ .weight = 900, .oblique = true } }, .expected = 1 },
        .{ .query = .{ .family = "", .style = .oblique }, .faces = &.{ .{}, .{ .weight = 900, .italic = true } }, .expected = 1 },
        .{ .query = .{ .family = "" }, .faces = &.{ .{ .weight = 500 }, .{ .weight = 0, .width = 0 } }, .expected = 1 },
    };
    for (cases) |case| {
        try expectCollection(case, false);
        try expectCollection(case, true);
    }
}

test "coverage matching CSS genuine trait ties retain catalog order" {
    try expectCollection(.{ .query = .{ .family = "", .weight = 450 }, .faces = &.{ .{ .weight = 500 }, .{ .weight = 500 } }, .expected = 0 }, false);
    try expectCollection(.{ .query = .{ .family = "", .weight = 450 }, .faces = &.{ .{ .weight = 500 }, .{ .weight = 500 } }, .expected = 1 }, true);
}

test "coverage matching CSS complete middle range retains named instance and TTC identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer index.reset(io);
    const cmap = try font.buildTestCmap(a, &.{.{ .start = 'B', .end = 'B' }}, 12);
    defer a.free(cmap);
    const unrelated = try font.buildTestFont(a, .{ .family = "Other Family", .cmap = cmap });
    defer a.free(unrelated);
    const named = try font.buildTestFont(a, .{
        .family = "CSS Named",
        .postscript_name = "CSSNamed-Regular",
        .cmap = cmap,
        .instances = &.{.{ .subfamily = "Medium", .postscript_name = "CSSNamed-Medium", .weight = 500 }},
    });
    defer a.free(named);
    const collection = try font.buildTestCollection(a, &.{ unrelated, named });
    defer a.free(collection);
    try tmp.dir.writeFile(io, .{ .sub_path = "named.ttc", .data = collection });
    const intermediate = try font.buildTestFont(a, .{
        .family = "CSS Intermediate",
        .postscript_name = "CSSIntermediate-Regular",
        .cmap = cmap,
        .instances = &.{
            .{ .subfamily = "Book", .postscript_name = "CSSIntermediate-Book", .weight = 450 },
            .{ .subfamily = "Intermediate", .postscript_name = "CSSIntermediate-480", .weight = 480 },
            .{ .subfamily = "Medium", .postscript_name = "CSSIntermediate-Medium", .weight = 500 },
        },
    });
    defer a.free(intermediate);
    try tmp.dir.writeFile(io, .{ .sub_path = "intermediate.ttf", .data = intermediate });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const roots = [_][]const u8{root_buffer[0..root_len]};
    index.reset(io);
    try std.testing.expect(index.prewarm(io, .{ .roots = &roots, .enable_cache = false }));
    var discovery = try Discovery.initWithRoots(a, &roots);
    defer discovery.deinit();
    for (400..501) |requested| {
        for ([_]?u21{ null, 'B' }) |coverage| {
            var result = try discovery.resolveUncached(a, .{ .family = "CSS Named", .weight = @intCast(requested), .required_codepoint = coverage, .max_candidates = 1 });
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
            const selected = result.candidates[0];
            const regular = requested == 400;
            try std.testing.expectEqualStrings(if (regular) "CSSNamed-Regular" else "CSSNamed-Medium", selected.postscript_name.?);
            try std.testing.expectEqual(@as(u16, if (regular) 400 else 500), selected.weight);
            try std.testing.expectEqual(@as(?u32, 1), selected.face_index);
            try std.testing.expectEqual(@as(u32, 1), selected.provider_index);
            try std.testing.expectEqual(@as(u16, if (regular) 0 else 1), selected.named_instance);
            try std.testing.expect(std.mem.endsWith(u8, selected.path, "/named.ttc"));
        }
    }
    var exact = try discovery.resolve(a, .{ .family = "CSS Named", .postscript_name = "CSSNamed-Regular", .weight = 450, .max_candidates = 1 });
    defer exact.deinit();
    try std.testing.expectEqualStrings("CSSNamed-Regular", exact.candidates[0].postscript_name.?);
    try std.testing.expectEqual(@as(u16, 0), exact.candidates[0].named_instance);
    const intermediate_cases = [_]struct { requested: u16, selected: u16, instance: u16, postscript: []const u8 }{
        .{ .requested = 400, .selected = 400, .instance = 0, .postscript = "CSSIntermediate-Regular" },
        .{ .requested = 420, .selected = 450, .instance = 1, .postscript = "CSSIntermediate-Book" },
        .{ .requested = 450, .selected = 450, .instance = 1, .postscript = "CSSIntermediate-Book" },
        .{ .requested = 470, .selected = 480, .instance = 2, .postscript = "CSSIntermediate-480" },
        .{ .requested = 480, .selected = 480, .instance = 2, .postscript = "CSSIntermediate-480" },
        .{ .requested = 490, .selected = 500, .instance = 3, .postscript = "CSSIntermediate-Medium" },
        .{ .requested = 500, .selected = 500, .instance = 3, .postscript = "CSSIntermediate-Medium" },
    };
    for (intermediate_cases) |case| {
        var result = try discovery.resolve(a, .{ .family = "CSS Intermediate", .weight = case.requested, .required_codepoint = 'B', .max_candidates = 1 });
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
        const selected = result.candidates[0];
        try std.testing.expectEqualStrings(case.postscript, selected.postscript_name.?);
        try std.testing.expectEqual(case.selected, selected.weight);
        try std.testing.expectEqual(case.instance, selected.named_instance);
        try std.testing.expectEqual(@as(?u32, 0), selected.face_index);
        try std.testing.expectEqual(@as(u32, 0), selected.provider_index);
        try std.testing.expect(std.mem.endsWith(u8, selected.path, "/intermediate.ttf"));
    }
}
