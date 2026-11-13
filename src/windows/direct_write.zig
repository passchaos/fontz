//! Native Windows system-font discovery through DirectWrite.

const std = @import("std");
const types = @import("../types.zig");
const query_cache = @import("../query_cache.zig");
const dw = @import("dwrite_api.zig");

const ui_families = [_][]const u8{ "Segoe UI Variable Text", "Segoe UI" };
const mono_families = [_][]const u8{ "Cascadia Mono", "Cascadia Code", "Consolas" };
const emoji_families = [_][]const u8{ "Segoe UI Emoji", "Segoe UI Symbol" };
const symbol_families = [_][]const u8{ "Segoe UI Symbol", "Segoe UI" };
const cjk_ja_families = [_][]const u8{ "Yu Gothic UI", "Meiryo UI", "Meiryo" };
const cjk_ko_families = [_][]const u8{ "Malgun Gothic", "Malgun Gothic Semilight" };
const cjk_traditional_families = [_][]const u8{ "Microsoft JhengHei UI", "Microsoft JhengHei" };
const cjk_simplified_families = [_][]const u8{ "Microsoft YaHei UI", "Microsoft YaHei", "DengXian" };
const cjk_default_families = [_][]const u8{
    "Microsoft YaHei UI",
    "Microsoft JhengHei UI",
    "Yu Gothic UI",
    "Malgun Gothic",
};

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    factory: ?*dw.Factory,
    collection: ?*dw.FontCollection,
    mutex: std.Io.Mutex = .init,
    cache: query_cache.Cache,
    generation_value: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        const factory = dw.createFactory();
        const collection = if (factory) |value| dw.systemCollection(value, false) else null;
        if (factory != null and collection == null) dw.release(factory.?);
        return .{
            .allocator = allocator,
            .factory = if (collection != null) factory else null,
            .collection = collection,
            .cache = query_cache.Cache.init(allocator),
        };
    }

    pub fn deinit(self: *Discovery) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
        if (self.collection) |collection| dw.release(collection);
        if (self.factory) |factory| dw.release(factory);
        self.cache.deinit();
        self.mutex.unlock(std.Options.debug_io);
        self.* = undefined;
    }

    pub fn available(self: *const Discovery) bool {
        return self.collection != null;
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
        const factory = self.factory orelse return false;
        const replacement = dw.systemCollection(factory, true) orelse
            return error.DirectWriteRefreshFailed;
        if (replacement == self.collection.?) {
            dw.release(replacement);
            return false;
        }
        dw.release(self.collection.?);
        self.collection = replacement;
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
        const collection = self.collection orelse return try emptyResolution(allocator);
        if (query.max_candidates == 0) return try emptyResolution(allocator);
        var candidates = std.ArrayList(types.Candidate).empty;
        errdefer deinitCandidates(&candidates, allocator);

        if (query.postscript_name) |postscript| {
            try scanPostScript(
                collection,
                allocator,
                query,
                postscript,
                &candidates,
            );
        } else if (!isGenericFamily(query.family)) {
            try appendFamily(collection, allocator, query, query.family, &candidates);
        } else {
            for (preferredFamilies(query)) |family| {
                try appendFamily(collection, allocator, query, family, &candidates);
                if (candidates.items.len >= query.max_candidates) break;
            }
        }
        if (query.required_codepoint != null and candidates.items.len == 0) {
            try scanCoverage(collection, allocator, query, &candidates);
        }
        return .{
            .allocator = allocator,
            .candidates = try candidates.toOwnedSlice(allocator),
            .provider = .direct_write,
        };
    }
};

fn appendFamily(
    collection: *dw.FontCollection,
    allocator: std.mem.Allocator,
    query: types.Query,
    family_name: []const u8,
    candidates: *std.ArrayList(types.Candidate),
) !void {
    if (candidates.items.len >= query.max_candidates) return;
    const family = try dw.findFamily(allocator, collection, family_name) orelse return;
    defer dw.release(family);
    const font = dw.matchingFont(
        family,
        query.weight,
        directWriteStretch(query.stretch),
        directWriteStyle(query.style),
    ) orelse return;
    defer dw.release(font);
    if (query.required_codepoint) |codepoint| {
        if (!dw.hasCharacter(font, codepoint)) return;
    }
    // Preserve the exact family spelling DirectWrite matched. GetFamilyNames
    // may return a different localized display string first, which would make
    // the later Zui/Cangjie query verifier reject a valid native match.
    try appendFont(allocator, font, family_name, candidates, query.max_candidates);
}

fn scanCoverage(
    collection: *dw.FontCollection,
    allocator: std.mem.Allocator,
    query: types.Query,
    candidates: *std.ArrayList(types.Candidate),
) !void {
    const codepoint = query.required_codepoint orelse return;
    const count = collection.lpVtbl.GetFontFamilyCount(collection);
    for (0..count) |raw_index| {
        if (candidates.items.len >= query.max_candidates) break;
        const family = dw.familyAt(collection, @intCast(raw_index)) orelse continue;
        defer dw.release(family);
        const font = dw.matchingFont(
            family,
            query.weight,
            directWriteStretch(query.stretch),
            directWriteStyle(query.style),
        ) orelse continue;
        defer dw.release(font);
        if (!dw.hasCharacter(font, codepoint)) continue;
        const family_name = try dw.familyName(allocator, family);
        defer if (family_name) |value| allocator.free(value);
        try appendFont(allocator, font, family_name, candidates, query.max_candidates);
    }
}

fn scanPostScript(
    collection: *dw.FontCollection,
    allocator: std.mem.Allocator,
    query: types.Query,
    requested: []const u8,
    candidates: *std.ArrayList(types.Candidate),
) !void {
    const family_count = collection.lpVtbl.GetFontFamilyCount(collection);
    for (0..family_count) |raw_family_index| {
        if (candidates.items.len >= query.max_candidates) break;
        const family = dw.familyAt(collection, @intCast(raw_family_index)) orelse continue;
        defer dw.release(family);
        const family_name = try dw.familyName(allocator, family);
        defer if (family_name) |value| allocator.free(value);
        const font_count = family.lpVtbl.GetFontCount(family);
        for (0..font_count) |raw_font_index| {
            var font: ?*dw.Font = null;
            if (dw.failed(family.lpVtbl.GetFont(
                family,
                @intCast(raw_font_index),
                &font,
            ))) continue;
            const owned_font = font orelse continue;
            defer dw.release(owned_font);
            const postscript = try dw.postscriptName(allocator, owned_font);
            defer if (postscript) |value| allocator.free(value);
            if (postscript == null or
                !std.ascii.eqlIgnoreCase(postscript.?, requested)) continue;
            if (query.required_codepoint) |codepoint| {
                if (!dw.hasCharacter(owned_font, codepoint)) continue;
            }
            try appendFont(
                allocator,
                owned_font,
                family_name,
                candidates,
                query.max_candidates,
            );
            return;
        }
    }
}

fn appendFont(
    allocator: std.mem.Allocator,
    font: *dw.Font,
    family_name: ?[]const u8,
    candidates: *std.ArrayList(types.Candidate),
    max_candidates: usize,
) !void {
    if (candidates.items.len >= max_candidates) return;
    var face_file = try dw.faceFile(allocator, font) orelse return;
    defer face_file.deinit(allocator);
    for (candidates.items) |candidate| {
        if (candidate.face_index == face_file.face_index and
            std.mem.eql(u8, candidate.path, face_file.path)) return;
    }
    const postscript = try dw.postscriptName(allocator, font);
    defer if (postscript) |value| allocator.free(value);
    try candidates.append(allocator, try types.Candidate.init(
        allocator,
        face_file.path,
        family_name,
        postscript,
        face_file.face_index,
        face_file.face_index,
        0,
        .direct_write,
    ));
}

fn preferredFamilies(query: types.Query) []const []const u8 {
    if (isMonospaceFamily(query.family)) return &mono_families;
    if (isEmojiFamily(query.family) or query.required_codepoint == 0x1f600) {
        return &emoji_families;
    }
    if (query.required_codepoint == 0x4e2d) return cjkFamilies(query.language);
    if (query.required_codepoint == 0x2191) return &symbol_families;
    return &ui_families;
}

fn cjkFamilies(language: ?[]const u8) []const []const u8 {
    const value = language orelse return &cjk_default_families;
    if (languageStartsWith(value, "ja")) return &cjk_ja_families;
    if (languageStartsWith(value, "ko")) return &cjk_ko_families;
    if (languageStartsWith(value, "zh-tw") or
        languageStartsWith(value, "zh-hk") or
        languageStartsWith(value, "zh-hant")) return &cjk_traditional_families;
    if (languageStartsWith(value, "zh")) return &cjk_simplified_families;
    return &cjk_default_families;
}

fn directWriteStretch(stretch: u16) u32 {
    if (stretch <= 50) return 1;
    if (stretch <= 62) return 2;
    if (stretch <= 75) return 3;
    if (stretch <= 87) return 4;
    if (stretch <= 112) return 5;
    if (stretch <= 125) return 6;
    if (stretch <= 150) return 7;
    if (stretch <= 200) return 8;
    return 9;
}

fn directWriteStyle(style: types.Style) u32 {
    return switch (style) {
        .normal => 0,
        .oblique => 1,
        .italic => 2,
    };
}

fn isGenericFamily(family: []const u8) bool {
    return family.len == 0 or isMonospaceFamily(family) or
        isEmojiFamily(family) or
        std.ascii.eqlIgnoreCase(family, "sans-serif") or
        std.ascii.eqlIgnoreCase(family, "system-ui") or
        std.ascii.eqlIgnoreCase(family, "ui-sans-serif");
}

fn isMonospaceFamily(family: []const u8) bool {
    return std.ascii.eqlIgnoreCase(family, "monospace") or
        std.ascii.eqlIgnoreCase(family, "ui-monospace");
}

fn isEmojiFamily(family: []const u8) bool {
    return std.ascii.eqlIgnoreCase(family, "emoji") or
        std.ascii.eqlIgnoreCase(family, "ui-emoji");
}

fn languageStartsWith(language: []const u8, prefix: []const u8) bool {
    if (language.len < prefix.len) return false;
    for (language[0..prefix.len], prefix) |actual, expected| {
        const normalized = if (actual == '_') '-' else std.ascii.toLower(actual);
        if (normalized != std.ascii.toLower(expected)) return false;
    }
    return language.len == prefix.len or language[prefix.len] == '-' or
        language[prefix.len] == '_';
}

fn emptyResolution(allocator: std.mem.Allocator) !types.Resolution {
    return .{
        .allocator = allocator,
        .candidates = try allocator.alloc(types.Candidate, 0),
        .provider = .direct_write,
    };
}

fn deinitCandidates(
    candidates: *std.ArrayList(types.Candidate),
    allocator: std.mem.Allocator,
) void {
    for (candidates.items) |*candidate| candidate.deinit();
    candidates.deinit(allocator);
}

test "DirectWrite query mapping preserves style stretch and CJK locale intent" {
    try std.testing.expectEqual(@as(u32, 5), directWriteStretch(100));
    try std.testing.expectEqual(@as(u32, 2), directWriteStyle(.italic));
    try std.testing.expectEqualStrings(
        "Yu Gothic UI",
        cjkFamilies("ja-JP")[0],
    );
    try std.testing.expectEqualStrings(
        "Microsoft JhengHei UI",
        cjkFamilies("zh-Hant-TW")[0],
    );
    try std.testing.expectEqualStrings(
        "Segoe UI Emoji",
        preferredFamilies(.{
            .family = "emoji",
            .required_codepoint = 0x1f600,
        })[0],
    );
}
