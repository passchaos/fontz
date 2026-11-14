//! Unified system-font discovery for Project-Z.
//!
//! `fontz` owns platform font enumeration and descriptor resolution. It does
//! not parse outlines, shape text, or rasterize glyphs; consumers feed the
//! returned paths/face indices/PostScript identities into Cangjie or another
//! font engine.
//!
//! Discovery is pure Zig: a bounded sfnt metadata index, a fontconfig
//! configuration reader (Linux), a minimal `cmap` coverage reader, and
//! deterministic fallback paths. No fontconfig/CoreText/DirectWrite library is
//! linked.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const Role = types.Role;
pub const Provider = types.Provider;
pub const Style = types.Style;
pub const Query = types.Query;
pub const Candidate = types.Candidate;
pub const Resolution = types.Resolution;
pub const DiscoveryStats = types.DiscoveryStats;
pub const MissingGlyph = types.MissingGlyph;
pub const FallbackFontClass = types.FallbackFontClass;
pub const MissingGlyphSink = types.MissingGlyphSink;
pub const Service = types.Service;
pub const freeFamilyNames = types.freeFamilyNames;

pub const fallback_paths = @import("fallback_paths.zig");
pub const family = @import("family.zig");
pub const metadata_index = @import("metadata_index.zig");

const PlatformDiscovery = @import("pure_discovery.zig").Discovery;

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    platform: PlatformDiscovery,
    missing_glyph_sink: ?*MissingGlyphSink = null,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        return .{
            .allocator = allocator,
            .platform = PlatformDiscovery.init(allocator),
        };
    }

    pub fn deinit(self: *Discovery) void {
        self.platform.deinit();
        self.* = undefined;
    }

    pub fn available(self: *const Discovery) bool {
        return self.platform.available();
    }

    pub fn resolveRole(
        self: *Discovery,
        allocator: std.mem.Allocator,
        role: Role,
        language: ?[]const u8,
    ) !Resolution {
        const query = queryForRole(role, language);
        var resolution = try self.platform.resolve(allocator, query);
        if (resolution.candidates.len == 0) {
            resolution.deinit();
            return try fallbackResolution(allocator, role, query);
        }
        return resolution;
    }

    pub fn resolveQuery(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: Query,
    ) !Resolution {
        var platform_query = query;
        if (query.family.len == 0) {
            if (query.required_codepoint) |codepoint| {
                if (fallback_paths.roleForCodepoint(codepoint)) |role| {
                    platform_query.family = switch (role) {
                        .emoji => "emoji",
                        .monospace => "monospace",
                        .cjk, .symbol, .ui => "sans-serif",
                    };
                }
            }
        }
        var resolution = try self.platform.resolve(allocator, platform_query);
        if (resolution.candidates.len == 0) {
            resolution.deinit();
            return try fallbackResolutionForQuery(allocator, query);
        }
        return resolution;
    }

    pub fn refresh(self: *Discovery) !bool {
        return try self.platform.refresh();
    }

    pub fn stats(self: *Discovery) DiscoveryStats {
        return self.platform.stats();
    }

    /// Enumerate installed family names. Native providers return their own
    /// catalog; when unavailable, the bounded metadata index is used. Callers
    /// release the result with `freeFamilyNames`.
    pub fn allFamilyNames(
        self: *Discovery,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        const names = try self.platform.allFamilyNames(allocator);
        if (names.len != 0) return names;
        freeFamilyNames(allocator, names);
        return try metadata_index.familyNames(std.Options.debug_io, allocator, .{});
    }

    pub fn setMissingGlyphSink(
        self: *Discovery,
        sink: ?*MissingGlyphSink,
    ) void {
        self.missing_glyph_sink = sink;
    }

    pub fn reportMissingGlyph(
        self: *Discovery,
        missing: MissingGlyph,
    ) void {
        if (self.missing_glyph_sink) |sink| {
            var report = missing;
            if (report.generation == 0) report.generation = self.stats().generation;
            sink.report(sink.context, report);
        }
    }

    /// Borrow this discovery as the runtime-injectable service contract.
    pub fn service(self: *Discovery) Service {
        return .{ .context = self, .vtable = &service_vtable };
    }
};

const service_vtable = Service.VTable{
    .resolve = serviceResolve,
    .all_family_names = serviceAllFamilyNames,
    .prewarm = servicePrewarm,
    .set_missing_glyph_sink = serviceSetMissingGlyphSink,
    .generation = serviceGeneration,
};

fn serviceResolve(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    query: Query,
) anyerror!Resolution {
    const self: *Discovery = @ptrCast(@alignCast(context));
    return try self.resolveQuery(allocator, query);
}

fn serviceAllFamilyNames(
    context: *anyopaque,
    allocator: std.mem.Allocator,
) anyerror![]const []const u8 {
    const self: *Discovery = @ptrCast(@alignCast(context));
    return try self.allFamilyNames(allocator);
}

fn servicePrewarm(context: *anyopaque, queries: []const Query) void {
    const self: *Discovery = @ptrCast(@alignCast(context));
    for (queries) |query| {
        var resolution = self.resolveQuery(self.allocator, query) catch continue;
        resolution.deinit();
    }
}

fn serviceSetMissingGlyphSink(
    context: *anyopaque,
    sink: ?*MissingGlyphSink,
) void {
    const self: *Discovery = @ptrCast(@alignCast(context));
    self.setMissingGlyphSink(sink);
}

fn serviceGeneration(context: *anyopaque) u64 {
    const self: *Discovery = @ptrCast(@alignCast(context));
    return self.stats().generation;
}

pub fn queryForRole(role: Role, language: ?[]const u8) Query {
    return switch (role) {
        .ui => .{ .family = "sans-serif", .language = language },
        .monospace => .{ .family = "monospace", .language = language },
        .cjk => .{
            .family = "sans-serif",
            .language = language,
            .required_codepoint = 0x4e2d,
        },
        .emoji => .{
            .family = "emoji",
            .required_codepoint = 0x1f600,
        },
        .symbol => .{
            .family = "sans-serif",
            .required_codepoint = 0x2191,
        },
    };
}

fn fallbackResolution(
    allocator: std.mem.Allocator,
    role: Role,
    query: Query,
) !Resolution {
    const candidates = fallback_paths.forRoleCandidates(
        role,
        query.language,
        query.weight,
        query.style,
    );
    return buildFallbackResolution(allocator, candidates, role == .monospace, query);
}

fn fallbackResolutionForQuery(
    allocator: std.mem.Allocator,
    query: Query,
) !Resolution {
    const candidates = fallback_paths.forQuery(query);
    return buildFallbackResolution(allocator, candidates, false, query);
}

fn buildFallbackResolution(
    allocator: std.mem.Allocator,
    candidates: []const fallback_paths.CandidatePath,
    monospaced: bool,
    query: Query,
) !Resolution {
    var output: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (output.items) |*candidate| candidate.deinit();
        output.deinit(allocator);
    }
    const family_hint = firstFamily(query.family);
    for (candidates) |candidate| {
        if (!pathExists(candidate.path)) continue;
        var resolved = try Candidate.init(
            allocator,
            candidate.path,
            family_hint,
            null,
            candidate.face_index,
            candidate.face_index,
            0,
            .fallback_paths,
        );
        resolved.setMetadata(
            if (query.weight >= 600) 700 else 400,
            query.stretch,
            query.style,
            monospaced,
        );
        try output.append(allocator, resolved);
    }
    return .{
        .allocator = allocator,
        .candidates = try output.toOwnedSlice(allocator),
        .provider = .fallback_paths,
    };
}

fn firstFamily(families: []const u8) ?[]const u8 {
    var iterator = family.FamilyIterator.init(families);
    while (iterator.next()) |raw_family| {
        const family_name = std.mem.trim(u8, raw_family, " \t\r\n");
        if (family_name.len != 0) return family_name;
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    if (builtin.os.tag == .freestanding) return true;
    if (!std.fs.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

test "system font role queries carry coverage and language intent" {
    const cjk_query = queryForRole(.cjk, "ja-JP");
    try std.testing.expectEqualStrings("sans-serif", cjk_query.family);
    try std.testing.expectEqualStrings("ja-JP", cjk_query.language.?);
    try std.testing.expectEqual(@as(?u21, 0x4e2d), cjk_query.required_codepoint);
    try std.testing.expectEqual(@as(?u21, 0x1f600), queryForRole(.emoji, null).required_codepoint);
    try std.testing.expect(queryForRole(.ui, null).required_codepoint == null);
}

test "service contract forwards resolution and missing glyph sink" {
    var discovery = Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    var service = discovery.service();
    var resolution = try service.resolve(std.testing.allocator, queryForRole(.ui, null));
    defer resolution.deinit();
    try std.testing.expect(resolution.candidates.len <= queryForRole(.ui, null).max_candidates);

    var reported: usize = 0;
    const sink_context = struct {
        fn report(context: *anyopaque, _: MissingGlyph) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    var sink = MissingGlyphSink{
        .context = &reported,
        .report = sink_context.report,
    };
    service.setMissingGlyphSink(&sink);
    discovery.reportMissingGlyph(.{ .cluster = "x" });
    try std.testing.expectEqual(@as(usize, 1), reported);
}

test "fallback resolution returns existing deterministic paths" {
    var resolution = try fallbackResolutionForQuery(std.testing.allocator, .{
        .family = "monospace",
    });
    defer resolution.deinit();
    for (resolution.candidates) |candidate| {
        try std.testing.expect(pathExists(candidate.path));
    }
}

test {
    std.testing.refAllDecls(@This());
}
