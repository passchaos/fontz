//! Pure-Zig system-font discovery.
//!
//! Uses the bounded metadata index for catalog/matching, the pure-Zig
//! fontconfig configuration reader on Linux, and `cmap` coverage checks.
//! No fontconfig/CoreText/DirectWrite library is linked.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const family_mod = @import("family.zig");
const fallback_paths = @import("fallback_paths.zig");
const metadata_index = @import("metadata_index.zig");
const fontconfig = @import("metadata/fontconfig.zig");
const cmap = @import("metadata/cmap.zig");
const query_cache = @import("query_cache.zig");

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cache: query_cache.Cache,
    generation_value: u64 = 1,
    config: fontconfig.Config,
    roots: []const []const u8,
    generic_mappings: []const metadata_index.GenericMapping,
    available_value: bool = true,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        const io = std.Options.debug_io;
        var config = fontconfig.load(io, allocator) catch fontconfig.empty(allocator);
        const arena = config.arena.allocator();
        const roots = if (config.dirs.len != 0)
            config.dirs
        else
            metadata_index.defaultRoots(io, arena) catch &.{};
        const mappings = buildGenericMappings(arena, config.aliases) catch &.{};
        return .{
            .allocator = allocator,
            .cache = query_cache.Cache.init(allocator),
            .config = config,
            .roots = roots,
            .generic_mappings = mappings,
        };
    }

    /// Build a provider with explicit roots. Used by tests and embedders.
    pub fn initWithRoots(
        allocator: std.mem.Allocator,
        roots: []const []const u8,
    ) !Discovery {
        var config = fontconfig.empty(allocator);
        errdefer config.deinit();
        const arena = config.arena.allocator();
        const copied = try copyRoots(arena, roots);
        const mappings = try buildGenericMappings(arena, &.{});
        return .{
            .allocator = allocator,
            .cache = query_cache.Cache.init(allocator),
            .config = config,
            .roots = copied,
            .generic_mappings = mappings,
        };
    }

    pub fn deinit(self: *Discovery) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        self.config.deinit();
        self.cache.deinit();
        self.mutex.unlock(std.Options.debug_io);
        self.* = undefined;
    }

    pub fn available(self: *const Discovery) bool {
        return self.available_value;
    }

    pub fn resolve(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: types.Query,
    ) !types.Resolution {
        return try query_cache.Cache.resolveCached(
            &self.cache,
            &self.mutex,
            allocator,
            self.generation_value,
            query,
            self,
        );
    }

    pub fn refresh(self: *Discovery) !bool {
        const io = std.Options.debug_io;
        var new_config = fontconfig.load(io, self.allocator) catch return false;
        errdefer new_config.deinit();
        const arena = new_config.arena.allocator();
        const roots = if (new_config.dirs.len != 0)
            new_config.dirs
        else
            metadata_index.defaultRoots(io, arena) catch &.{};
        const mappings = try buildGenericMappings(arena, new_config.aliases);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.config.deinit();
        self.config = new_config;
        self.roots = roots;
        self.generic_mappings = mappings;
        self.generation_value +%= 1;
        if (self.generation_value == 0) self.generation_value = 1;
        self.cache.clear();
        metadata_index.reset(io);
        return true;
    }

    pub fn stats(self: *Discovery) types.DiscoveryStats {
        return query_cache.Cache.cachedStats(
            &self.cache,
            &self.mutex,
            self.generation_value,
        );
    }

    /// Builds the metadata index ahead of the first query. Safe to call from a
    /// background worker; resolution and prewarm serialize on the process-wide
    /// index mutex.
    pub fn prewarm(self: *Discovery) bool {
        const io = std.Options.debug_io;
        return metadata_index.prewarm(io, .{
            .roots = self.roots,
            .generic_mappings = self.generic_mappings,
        });
    }

    pub fn allFamilyNames(
        self: *Discovery,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        return metadata_index.familyNames(std.Options.debug_io, allocator, .{
            .roots = self.roots,
            .generic_mappings = self.generic_mappings,
        });
    }

    pub fn resolveUncached(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: types.Query,
    ) !types.Resolution {
        if (query.max_candidates == 0) return try emptyResolution(allocator);
        const io = std.Options.debug_io;
        const options = metadata_index.Options{
            .roots = self.roots,
            .generic_mappings = self.generic_mappings,
        };
        const hinted = hintQuery(query);
        var face = metadata_index.findFace(io, hinted, options);
        if (face) |selected| {
            if (query.required_codepoint) |codepoint| {
                if (!(cmap.coversCodepoint(io, selected.path, selected.face_index, codepoint) catch false)) {
                    face = null;
                }
            }
        }

        var candidates: std.ArrayList(types.Candidate) = .empty;
        errdefer {
            for (candidates.items) |*candidate| candidate.deinit();
            candidates.deinit(allocator);
        }
        if (face) |selected| {
            var candidate = try types.Candidate.init(
                allocator,
                selected.path,
                selected.family,
                selected.postscript_name,
                selected.face_index,
                selected.face_index,
                selected.named_instance,
                .metadata_index,
            );
            candidate.setMetadata(
                selected.weight,
                selected.stretch,
                selected.style,
                selected.monospaced,
            );
            try candidates.append(allocator, candidate);
        }

        const family_hint = firstFamily(query.family);
        for (fallback_paths.forQuery(query)) |fallback| {
            if (candidates.items.len >= query.max_candidates) break;
            if (!pathExists(fallback.path)) continue;
            if (query.required_codepoint) |codepoint| {
                if (!(cmap.coversCodepoint(io, fallback.path, fallback.face_index, codepoint) catch false)) continue;
            }
            if (containsCandidate(candidates.items, fallback.path, fallback.face_index)) continue;
            var candidate = try types.Candidate.init(
                allocator,
                fallback.path,
                family_hint,
                null,
                fallback.face_index,
                fallback.face_index,
                0,
                .fallback_paths,
            );
            candidate.setMetadata(
                if (query.weight >= 600) 700 else 400,
                query.stretch,
                query.style,
                false,
            );
            try candidates.append(allocator, candidate);
        }

        return .{
            .allocator = allocator,
            .candidates = try candidates.toOwnedSlice(allocator),
            .provider = .metadata_index,
        };
    }
};

fn emptyResolution(allocator: std.mem.Allocator) !types.Resolution {
    return .{
        .allocator = allocator,
        .candidates = try allocator.alloc(types.Candidate, 0),
        .provider = .metadata_index,
    };
}

fn copyRoots(allocator: std.mem.Allocator, roots: []const []const u8) ![]const []const u8 {
    const copied = try allocator.alloc([]const u8, roots.len);
    for (roots, copied) |root, *out| {
        out.* = try allocator.dupe(u8, root);
    }
    return copied;
}

fn hintQuery(query: types.Query) types.Query {
    var result = query;
    if (query.family.len == 0) {
        if (query.postscript_name != null) return result;
        result.family = if (query.required_codepoint) |codepoint|
            familyForCodepoint(codepoint, query.language)
        else
            "sans-serif";
        return result;
    }
    var iterator = family_mod.FamilyIterator.init(query.family);
    const first = iterator.next() orelse return result;
    const generic = family_mod.genericFamily(first) orelse return result;
    switch (generic) {
        .sans_serif, .system_ui, .rounded => if (query.required_codepoint) |codepoint| {
            result.family = familyForCodepoint(codepoint, query.language);
        },
        .emoji => result.family = platformEmojiFamily(),
        .math => result.family = platformMathFamily(),
        .monospace => if (query.required_codepoint) |codepoint| {
            if (fallback_paths.roleForCodepoint(codepoint)) |role| {
                if (role == .cjk) result.family = platformCjkFamily(query.language);
            }
        },
        else => {},
    }
    return result;
}

fn familyForCodepoint(codepoint: u21, language: ?[]const u8) []const u8 {
    if (isMathCodepoint(codepoint)) return platformMathFamily();
    if (fallback_paths.roleForCodepoint(codepoint)) |role| {
        return switch (role) {
            .emoji => platformEmojiFamily(),
            .cjk => platformCjkFamily(language),
            .symbol => platformSymbolFamily(),
            .monospace => platformMonospaceFamily(),
            .ui => "sans-serif",
        };
    }
    return "sans-serif";
}

fn isMathCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x2200 and codepoint <= 0x22ff) or
        (codepoint >= 0x27c0 and codepoint <= 0x27ef) or
        (codepoint >= 0x2980 and codepoint <= 0x2aff) or
        (codepoint >= 0x1d400 and codepoint <= 0x1d7ff);
}

const CjkLanguage = enum { ja, ko, sc, tc, hk };

fn cjkLanguage(language: ?[]const u8) CjkLanguage {
    const value = language orelse return .sc;
    const primary = languagePrimary(value);
    if (std.ascii.eqlIgnoreCase(primary, "ja")) return .ja;
    if (std.ascii.eqlIgnoreCase(primary, "ko")) return .ko;
    if (std.ascii.eqlIgnoreCase(primary, "zh")) {
        if (containsLanguagePart(value, "hk")) return .hk;
        if (containsLanguagePart(value, "tw") or containsLanguagePart(value, "hant")) return .tc;
        return .sc;
    }
    return .sc;
}

fn platformCjkFamily(language: ?[]const u8) []const u8 {
    const lang = cjkLanguage(language);
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => switch (lang) {
            .ja => "Hiragino Sans",
            .ko => "Apple SD Gothic Neo",
            .sc => "PingFang SC",
            .tc => "PingFang TC",
            .hk => "PingFang HK",
        },
        .windows => switch (lang) {
            .ja => "Yu Gothic UI",
            .ko => "Malgun Gothic",
            .sc => "Microsoft YaHei UI",
            .tc, .hk => "Microsoft JhengHei UI",
        },
        else => switch (lang) {
            .ja => "Noto Sans CJK JP",
            .ko => "Noto Sans CJK KR",
            .sc => "Noto Sans CJK SC",
            .tc => "Noto Sans CJK TC",
            .hk => "Noto Sans CJK HK",
        },
    };
}

fn platformEmojiFamily() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "Apple Color Emoji",
        .windows => "Segoe UI Emoji",
        else => "Noto Color Emoji",
    };
}

fn platformSymbolFamily() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "Apple Symbols",
        .windows => "Segoe UI Symbol",
        else => "Noto Sans Symbols2",
    };
}

fn platformMathFamily() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "STIX Two Math",
        .windows => "Cambria Math",
        else => "Latin Modern Math",
    };
}

fn platformMonospaceFamily() []const u8 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "Menlo",
        .windows => "Consolas",
        else => "DejaVu Sans Mono",
    };
}

fn languagePrimary(language: []const u8) []const u8 {
    var end: usize = 0;
    while (end < language.len and language[end] != '-' and language[end] != '_') : (end += 1) {}
    return language[0..end];
}

fn containsLanguagePart(language: []const u8, part: []const u8) bool {
    var iterator = std.mem.tokenizeAny(u8, language, "-_");
    while (iterator.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, part)) return true;
    }
    return false;
}

fn firstFamily(families: []const u8) ?[]const u8 {
    var iterator = family_mod.FamilyIterator.init(families);
    while (iterator.next()) |raw| {
        const family = std.mem.trim(u8, raw, " \t\r\n");
        if (family.len != 0) return family;
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    if (builtin.os.tag == .freestanding) return true;
    if (!std.fs.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn containsCandidate(
    candidates: []const types.Candidate,
    path: []const u8,
    face_index: u32,
) bool {
    for (candidates) |candidate| {
        if (candidate.face_index == face_index and std.mem.eql(u8, candidate.path, path)) {
            return true;
        }
    }
    return false;
}

const GenericDefaults = struct {
    sans: []const []const u8,
    serif: []const []const u8,
    mono: []const []const u8,
    cursive: []const []const u8,
    fantasy: []const []const u8,
    emoji: []const []const u8,
    math: []const []const u8,
};

const linux_sans = [_][]const u8{ "DejaVu Sans", "Noto Sans", "Liberation Sans" };
const linux_serif = [_][]const u8{ "DejaVu Serif", "Noto Serif", "Liberation Serif" };
const linux_mono = [_][]const u8{ "DejaVu Sans Mono", "Noto Sans Mono", "Liberation Mono" };
const linux_cursive = [_][]const u8{"Z003"};
const linux_fantasy = [_][]const u8{"Z003"};
const linux_emoji = [_][]const u8{"Noto Color Emoji"};
const linux_math = [_][]const u8{ "Latin Modern Math", "Noto Sans Math", "DejaVu Math TeX Gyre" };
const linux_defaults = GenericDefaults{
    .sans = &linux_sans,
    .serif = &linux_serif,
    .mono = &linux_mono,
    .cursive = &linux_cursive,
    .fantasy = &linux_fantasy,
    .emoji = &linux_emoji,
    .math = &linux_math,
};

const macos_sans = [_][]const u8{ "Helvetica Neue", "Helvetica", "Arial", "SF Pro Text" };
const macos_serif = [_][]const u8{ "Times New Roman", "Times", "New York" };
const macos_mono = [_][]const u8{ "Menlo", "Monaco", "SF Mono" };
const macos_cursive = [_][]const u8{ "Apple Chancery", "Snell Roundhand" };
const macos_fantasy = [_][]const u8{ "Papyrus", "Chalkboard" };
const macos_emoji = [_][]const u8{"Apple Color Emoji"};
const macos_math = [_][]const u8{ "STIX Two Math", "STIXGeneral", "Times" };
const macos_defaults = GenericDefaults{
    .sans = &macos_sans,
    .serif = &macos_serif,
    .mono = &macos_mono,
    .cursive = &macos_cursive,
    .fantasy = &macos_fantasy,
    .emoji = &macos_emoji,
    .math = &macos_math,
};

const windows_sans = [_][]const u8{ "Segoe UI", "Segoe UI Variable Text", "Arial" };
const windows_serif = [_][]const u8{ "Times New Roman", "Georgia", "Cambria" };
const windows_mono = [_][]const u8{ "Cascadia Mono", "Consolas", "Courier New" };
const windows_cursive = [_][]const u8{ "Segoe Script", "Comic Sans MS" };
const windows_fantasy = [_][]const u8{ "Impact", "Segoe Print" };
const windows_emoji = [_][]const u8{"Segoe UI Emoji"};
const windows_math = [_][]const u8{ "Cambria Math", "Segoe UI Symbol" };
const windows_defaults = GenericDefaults{
    .sans = &windows_sans,
    .serif = &windows_serif,
    .mono = &windows_mono,
    .cursive = &windows_cursive,
    .fantasy = &windows_fantasy,
    .emoji = &windows_emoji,
    .math = &windows_math,
};

fn defaultsForTarget() GenericDefaults {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => macos_defaults,
        .windows => windows_defaults,
        else => linux_defaults,
    };
}

fn buildGenericMappings(
    allocator: std.mem.Allocator,
    aliases: []const fontconfig.Alias,
) ![]const metadata_index.GenericMapping {
    var list: std.ArrayList(metadata_index.GenericMapping) = .empty;
    const defaults = defaultsForTarget();
    for (aliases) |alias| {
        const families = try mergeFamilies(
            allocator,
            alias.families,
            defaultsFor(alias.generic, defaults),
        );
        try list.append(allocator, .{
            .generic = alias.generic,
            .families = families,
        });
    }
    try addDefault(allocator, &list, .sans_serif, defaults.sans);
    try addDefault(allocator, &list, .serif, defaults.serif);
    try addDefault(allocator, &list, .monospace, defaults.mono);
    try addDefault(allocator, &list, .cursive, defaults.cursive);
    try addDefault(allocator, &list, .fantasy, defaults.fantasy);
    try addDefault(allocator, &list, .emoji, defaults.emoji);
    try addDefault(allocator, &list, .math, defaults.math);
    try addDefault(allocator, &list, .system_ui, defaults.sans);
    try addDefault(allocator, &list, .rounded, defaults.sans);
    return try list.toOwnedSlice(allocator);
}

fn defaultsFor(generic: family_mod.GenericFamily, defaults: GenericDefaults) []const []const u8 {
    return switch (generic) {
        .serif => defaults.serif,
        .sans_serif, .system_ui, .rounded => defaults.sans,
        .monospace => defaults.mono,
        .cursive => defaults.cursive,
        .fantasy => defaults.fantasy,
        .emoji => defaults.emoji,
        .math => defaults.math,
    };
}

fn mergeFamilies(
    allocator: std.mem.Allocator,
    preferred: []const []const u8,
    fallback: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (preferred.len != 0) try out.append(allocator, preferred[0]);
    for (fallback) |family| {
        if (!containsString(out.items, family)) try out.append(allocator, family);
    }
    for (preferred) |family| {
        if (!containsString(out.items, family)) try out.append(allocator, family);
    }
    return try out.toOwnedSlice(allocator);
}

fn containsString(items: []const []const u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn addDefault(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(metadata_index.GenericMapping),
    generic: family_mod.GenericFamily,
    families: []const []const u8,
) !void {
    for (list.items) |mapping| {
        if (mapping.generic == generic) return;
    }
    try list.append(allocator, .{ .generic = generic, .families = families });
}

test "pure provider resolves synthetic roots and generic families" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try @import("metadata/test_font.zig").buildTestFont(std.testing.allocator, .{
        .family = "DejaVu Sans",
        .subfamily = "Bold",
        .weight = 700,
        .postscript_name = "DejaVuSans-Bold",
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "DejaVuSans-Bold.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    metadata_index.resetForTesting(io);
    defer metadata_index.resetForTesting(io);

    var discovery = try Discovery.initWithRoots(std.testing.allocator, &roots);
    defer discovery.deinit();
    var resolution = try discovery.resolve(std.testing.allocator, .{
        .family = "sans-serif",
        .weight = 700,
    });
    defer resolution.deinit();
    try std.testing.expect(resolution.candidates.len > 0);
    try std.testing.expectEqual(types.Provider.metadata_index, resolution.provider);
    try std.testing.expectEqualStrings("DejaVu Sans", resolution.candidates[0].family.?);
    try std.testing.expectEqual(@as(u16, 700), resolution.candidates[0].weight);
}

test "pure provider prewarms the metadata index without a query" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try @import("metadata/test_font.zig").buildTestFont(std.testing.allocator, .{
        .family = "Prewarm Sans",
        .postscript_name = "PrewarmSans-Regular",
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "PrewarmSans-Regular.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    metadata_index.resetForTesting(io);
    defer metadata_index.resetForTesting(io);

    var discovery = try Discovery.initWithRoots(std.testing.allocator, &roots);
    defer discovery.deinit();
    try std.testing.expect(discovery.prewarm());
    var resolution = try discovery.resolve(std.testing.allocator, .{ .family = "Prewarm Sans" });
    defer resolution.deinit();
    try std.testing.expect(resolution.candidates.len > 0);
    try std.testing.expectEqual(types.Provider.metadata_index, resolution.provider);
    try std.testing.expectEqualStrings("Prewarm Sans", resolution.candidates[0].family.?);
}
