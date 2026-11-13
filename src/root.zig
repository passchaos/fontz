//! Unified system-font discovery for Project-Z.
//!
//! `fontz` owns platform font enumeration and descriptor resolution. It does
//! not parse outlines, shape text, or rasterize glyphs; consumers feed the
//! returned paths/face indices/PostScript identities into Cangjie or another
//! font engine.
//!
//! Platform discovery is optional at deployment time. Linux uses a
//! runtime-loaded fontconfig provider, macOS uses CoreText, Windows uses
//! DirectWrite, and unsupported targets fall back to deterministic path
//! candidates. `metadata_index` provides an opt-in bounded sfnt metadata scan
//! for callers that need family matching without a native provider.

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
pub const MissingGlyphSink = types.MissingGlyphSink;
pub const Service = types.Service;

pub const fallback_paths = @import("fallback_paths.zig");
pub const family = @import("family.zig");
pub const metadata_index = @import("metadata_index.zig");

const PlatformDiscovery = switch (builtin.target.os.tag) {
    .linux => @import("linux_fontconfig.zig").Discovery,
    .macos => @import("macos/core_text.zig").Discovery,
    .windows => @import("windows/direct_write.zig").Discovery,
    else => UnavailableDiscovery,
};

const UnavailableDiscovery = struct {
    fn init(_: std.mem.Allocator) UnavailableDiscovery {
        return .{};
    }
    fn deinit(_: *UnavailableDiscovery) void {}
    fn available(_: *const UnavailableDiscovery) bool {
        return false;
    }
    fn resolve(
        _: *UnavailableDiscovery,
        allocator: std.mem.Allocator,
        _: Query,
    ) !Resolution {
        return .{
            .allocator = allocator,
            .candidates = try allocator.alloc(Candidate, 0),
            .provider = .fallback_paths,
        };
    }
    fn refresh(_: *UnavailableDiscovery) !bool {
        return false;
    }
    fn stats(_: *UnavailableDiscovery) DiscoveryStats {
        return .{};
    }
};

pub const Discovery = struct {
    platform: PlatformDiscovery,
    missing_glyph_sink: ?*MissingGlyphSink = null,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        return .{ .platform = PlatformDiscovery.init(allocator) };
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
        return try self.platform.resolve(allocator, queryForRole(role, language));
    }

    pub fn resolveQuery(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: Query,
    ) !Resolution {
        return try self.platform.resolve(allocator, query);
    }

    pub fn refresh(self: *Discovery) !bool {
        return try self.platform.refresh();
    }

    pub fn stats(self: *Discovery) DiscoveryStats {
        return self.platform.stats();
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
        if (self.missing_glyph_sink) |sink| sink.report(sink.context, missing);
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
    _ = context;
    // Native providers currently resolve descriptors rather than enumerate the
    // complete inventory. Callers that need a family picker can use
    // `metadata_index` or a provider-specific extension.
    return try allocator.alloc([]const u8, 0);
}

fn servicePrewarm(context: *anyopaque, queries: []const Query) void {
    _ = context;
    _ = queries;
    // Prewarming is provider-specific; the default implementation leaves
    // resolution lazy so headless/freestanding builds stay allocation-free.
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
