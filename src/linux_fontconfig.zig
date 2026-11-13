//! Runtime-loaded fontconfig provider.
//!
//! Font discovery is optional at deployment time: a missing fontconfig shared
//! library falls back to the deterministic path table without becoming a link
//! dependency for portable/headless builds.

const std = @import("std");
const types = @import("types.zig");
const query_cache = @import("query_cache.zig");

const Config = opaque {};
const Pattern = opaque {};
const CharSet = opaque {};
const FontSet = extern struct {
    nfont: c_int,
    sfont: c_int,
    fonts: [*]*Pattern,
};

const result_match: c_int = 0;
const match_pattern: c_int = 0;

const Api = struct {
    lib: std.DynLib,
    init_load_config_and_fonts: *const fn () callconv(.c) ?*Config,
    config_destroy: *const fn (*Config) callconv(.c) void,
    config_upto_date: *const fn (*Config) callconv(.c) c_int,
    pattern_create: *const fn () callconv(.c) ?*Pattern,
    pattern_destroy: *const fn (*Pattern) callconv(.c) void,
    pattern_add_string: *const fn (*Pattern, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    pattern_add_integer: *const fn (*Pattern, [*:0]const u8, c_int) callconv(.c) c_int,
    pattern_add_charset: *const fn (*Pattern, [*:0]const u8, *const CharSet) callconv(.c) c_int,
    pattern_get_string: *const fn (*const Pattern, [*:0]const u8, c_int, *?[*:0]u8) callconv(.c) c_int,
    pattern_get_integer: *const fn (*const Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    charset_create: *const fn () callconv(.c) ?*CharSet,
    charset_destroy: *const fn (*CharSet) callconv(.c) void,
    charset_add_char: *const fn (*CharSet, u32) callconv(.c) c_int,
    config_substitute: *const fn (?*Config, *Pattern, c_int) callconv(.c) c_int,
    default_substitute: *const fn (*Pattern) callconv(.c) void,
    font_sort: *const fn (*Config, *Pattern, c_int, ?*?*CharSet, *c_int) callconv(.c) ?*FontSet,
    font_set_sort_destroy: *const fn (*FontSet) callconv(.c) void,
    weight_from_opentype: *const fn (c_int) callconv(.c) c_int,

    fn load() ?Api {
        const names = [_][:0]const u8{ "libfontconfig.so.1", "libfontconfig.so" };
        for (names) |name| {
            var lib = std.DynLib.openZ(name.ptr) catch continue;
            return loadFromLibrary(&lib) orelse {
                lib.close();
                continue;
            };
        }
        return null;
    }

    fn deinit(self: *Api) void {
        self.lib.close();
    }
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    api: ?Api,
    config: ?*Config = null,
    mutex: std.Io.Mutex = .init,
    cache: query_cache.Cache,
    generation_value: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        var api = Api.load();
        var config: ?*Config = null;
        if (api) |*loaded| {
            config = loaded.init_load_config_and_fonts();
            if (config == null) {
                loaded.deinit();
                api = null;
            }
        }
        return .{
            .allocator = allocator,
            .api = api,
            .config = config,
            .cache = query_cache.Cache.init(allocator),
        };
    }

    pub fn deinit(self: *Discovery) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        if (self.api) |*api| {
            if (self.config) |config| api.config_destroy(config);
            api.deinit();
        }
        self.cache.deinit();
        self.mutex.unlock(std.Options.debug_io);
        self.* = undefined;
    }

    pub fn available(self: *const Discovery) bool {
        return self.api != null;
    }

    pub fn resolve(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: types.Query,
    ) !types.Resolution {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        if (try self.cache.get(query, self.generation_value, allocator)) |hit| {
            return hit;
        }
        var resolution = try self.resolveUncached(self.allocator, query);
        errdefer resolution.deinit();
        var output = try resolution.clone(allocator);
        errdefer output.deinit();
        try self.cache.put(query, self.generation_value, resolution);
        return output;
    }

    pub fn refresh(self: *Discovery) !bool {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        const api = &(self.api orelse return false);
        const config = self.config orelse return false;
        if (api.config_upto_date(config) != 0) return false;
        const replacement = api.init_load_config_and_fonts() orelse
            return error.FontconfigRefreshFailed;
        api.config_destroy(config);
        self.config = replacement;
        self.generation_value +%= 1;
        if (self.generation_value == 0) self.generation_value = 1;
        self.cache.clear();
        return true;
    }

    pub fn stats(self: *Discovery) types.DiscoveryStats {
        self.mutex.lockUncancelable(std.Options.debug_io);
        defer self.mutex.unlock(std.Options.debug_io);
        return self.cache.stats(self.generation_value);
    }

    fn resolveUncached(
        self: *Discovery,
        allocator: std.mem.Allocator,
        query: types.Query,
    ) !types.Resolution {
        const api = &(self.api orelse return try emptyResolution(allocator));
        const config = self.config orelse return try emptyResolution(allocator);
        const pattern = api.pattern_create() orelse return error.OutOfMemory;
        defer api.pattern_destroy(pattern);

        if (query.family.len != 0) {
            try addString(api, allocator, pattern, "family", query.family);
        }
        if (query.postscript_name) |name| {
            try addString(api, allocator, pattern, "postscriptname", name);
        }
        if (query.language) |language| {
            try addString(api, allocator, pattern, "lang", language);
        }
        if (api.pattern_add_integer(
            pattern,
            "weight",
            api.weight_from_opentype(query.weight),
        ) == 0) return error.FontconfigQueryFailed;
        if (api.pattern_add_integer(
            pattern,
            "width",
            @intCast(query.stretch),
        ) == 0) return error.FontconfigQueryFailed;
        if (api.pattern_add_integer(
            pattern,
            "slant",
            switch (query.style) {
                .normal => 0,
                .italic => 100,
                .oblique => 110,
            },
        ) == 0) return error.FontconfigQueryFailed;
        if (query.required_codepoint) |codepoint| {
            const charset = api.charset_create() orelse return error.OutOfMemory;
            defer api.charset_destroy(charset);
            if (api.charset_add_char(charset, codepoint) == 0 or
                api.pattern_add_charset(pattern, "charset", charset) == 0)
            {
                return error.FontconfigQueryFailed;
            }
        }
        if (api.config_substitute(config, pattern, match_pattern) == 0) {
            return error.FontconfigQueryFailed;
        }
        api.default_substitute(pattern);
        var match_result: c_int = result_match;
        const matches = api.font_sort(config, pattern, 0, null, &match_result) orelse
            return try emptyResolution(allocator);
        defer api.font_set_sort_destroy(matches);
        if (match_result != result_match or matches.nfont <= 0) {
            return try emptyResolution(allocator);
        }

        var candidates = std.ArrayList(types.Candidate).empty;
        errdefer {
            for (candidates.items) |*candidate| candidate.deinit();
            candidates.deinit(allocator);
        }
        const match_count: usize = @intCast(matches.nfont);
        for (matches.fonts[0..match_count]) |matched| {
            if (candidates.items.len >= query.max_candidates) break;
            var path_ptr: ?[*:0]u8 = null;
            if (api.pattern_get_string(matched, "file", 0, &path_ptr) != result_match) {
                continue;
            }
            const path = std.mem.span(path_ptr orelse continue);
            var raw_index: c_int = 0;
            _ = api.pattern_get_integer(matched, "index", 0, &raw_index);
            const provider_index: u32 = @bitCast(raw_index);
            if (containsCandidate(candidates.items, path, provider_index)) continue;
            var family_ptr: ?[*:0]u8 = null;
            const family: ?[]const u8 = if (api.pattern_get_string(
                matched,
                "family",
                0,
                &family_ptr,
            ) == result_match)
                std.mem.span(family_ptr orelse continue)
            else
                null;
            var postscript_ptr: ?[*:0]u8 = null;
            const postscript_name: ?[]const u8 = if (api.pattern_get_string(
                matched,
                "postscriptname",
                0,
                &postscript_ptr,
            ) == result_match)
                std.mem.span(postscript_ptr orelse continue)
            else
                null;
            try candidates.append(allocator, try types.Candidate.init(
                allocator,
                path,
                family,
                postscript_name,
                provider_index & 0xffff,
                provider_index,
                @intCast(provider_index >> 16),
                .fontconfig,
            ));
        }
        return .{
            .allocator = allocator,
            .candidates = try candidates.toOwnedSlice(allocator),
            .provider = .fontconfig,
        };
    }
};

fn emptyResolution(allocator: std.mem.Allocator) !types.Resolution {
    return .{
        .allocator = allocator,
        .candidates = try allocator.alloc(types.Candidate, 0),
        .provider = .fontconfig,
    };
}

fn containsCandidate(
    candidates: []const types.Candidate,
    path: []const u8,
    provider_index: u32,
) bool {
    for (candidates) |candidate| {
        if (candidate.provider_index == provider_index and
            std.mem.eql(u8, candidate.path, path)) return true;
    }
    return false;
}

fn addString(
    api: *const Api,
    allocator: std.mem.Allocator,
    pattern: *Pattern,
    key: [*:0]const u8,
    value: []const u8,
) !void {
    const terminated = try allocator.dupeZ(u8, value);
    defer allocator.free(terminated);
    if (api.pattern_add_string(pattern, key, terminated.ptr) == 0) {
        return error.FontconfigQueryFailed;
    }
}

fn loadFromLibrary(lib: *std.DynLib) ?Api {
    return .{
        .lib = lib.*,
        .init_load_config_and_fonts = symbol(lib, @TypeOf(@as(Api, undefined).init_load_config_and_fonts), "FcInitLoadConfigAndFonts") orelse return null,
        .config_destroy = symbol(lib, @TypeOf(@as(Api, undefined).config_destroy), "FcConfigDestroy") orelse return null,
        .config_upto_date = symbol(lib, @TypeOf(@as(Api, undefined).config_upto_date), "FcConfigUptoDate") orelse return null,
        .pattern_create = symbol(lib, @TypeOf(@as(Api, undefined).pattern_create), "FcPatternCreate") orelse return null,
        .pattern_destroy = symbol(lib, @TypeOf(@as(Api, undefined).pattern_destroy), "FcPatternDestroy") orelse return null,
        .pattern_add_string = symbol(lib, @TypeOf(@as(Api, undefined).pattern_add_string), "FcPatternAddString") orelse return null,
        .pattern_add_integer = symbol(lib, @TypeOf(@as(Api, undefined).pattern_add_integer), "FcPatternAddInteger") orelse return null,
        .pattern_add_charset = symbol(lib, @TypeOf(@as(Api, undefined).pattern_add_charset), "FcPatternAddCharSet") orelse return null,
        .pattern_get_string = symbol(lib, @TypeOf(@as(Api, undefined).pattern_get_string), "FcPatternGetString") orelse return null,
        .pattern_get_integer = symbol(lib, @TypeOf(@as(Api, undefined).pattern_get_integer), "FcPatternGetInteger") orelse return null,
        .charset_create = symbol(lib, @TypeOf(@as(Api, undefined).charset_create), "FcCharSetCreate") orelse return null,
        .charset_destroy = symbol(lib, @TypeOf(@as(Api, undefined).charset_destroy), "FcCharSetDestroy") orelse return null,
        .charset_add_char = symbol(lib, @TypeOf(@as(Api, undefined).charset_add_char), "FcCharSetAddChar") orelse return null,
        .config_substitute = symbol(lib, @TypeOf(@as(Api, undefined).config_substitute), "FcConfigSubstitute") orelse return null,
        .default_substitute = symbol(lib, @TypeOf(@as(Api, undefined).default_substitute), "FcDefaultSubstitute") orelse return null,
        .font_sort = symbol(lib, @TypeOf(@as(Api, undefined).font_sort), "FcFontSort") orelse return null,
        .font_set_sort_destroy = symbol(lib, @TypeOf(@as(Api, undefined).font_set_sort_destroy), "FcFontSetSortDestroy") orelse return null,
        .weight_from_opentype = symbol(lib, @TypeOf(@as(Api, undefined).weight_from_opentype), "FcWeightFromOpenType") orelse return null,
    };
}

fn symbol(lib: *std.DynLib, comptime T: type, name: [:0]const u8) ?T {
    return lib.lookup(T, name);
}
