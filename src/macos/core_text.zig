//! Native macOS system-font discovery through CoreText.
//!
//! CoreText owns family, locale, symbolic-trait, and Unicode fallback choice.
//! Zui keeps only the resolved file URL and stable face identity. CoreText does
//! not publish a TTC index, so candidates intentionally carry URL + PostScript
//! name and FontManager asks Cangjie to resolve that identity before parsing.

const std = @import("std");
const types = @import("../types.zig");
const query_cache = @import("../query_cache.zig");

const CFIndex = isize;
const CFStringEncoding = u32;
const CTFontSymbolicTraits = u32;

const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,
};
const CFString = opaque {};
const CFURL = opaque {};
const CFArray = opaque {};
const CTFont = opaque {};
const CFStringRef = *const CFString;
const CFURLRef = *const CFURL;
const CFArrayRef = *const CFArray;
const CTFontRef = *const CTFont;

const utf8_encoding: CFStringEncoding = 0x08000100;
const posix_path_style: CFIndex = 0;
const ui_font_system: u32 = 2;
const ui_font_fixed_pitch: u32 = 1;
const trait_italic: CTFontSymbolicTraits = 1 << 0;
const trait_bold: CTFontSymbolicTraits = 1 << 1;
const trait_expanded: CTFontSymbolicTraits = 1 << 5;
const trait_condensed: CTFontSymbolicTraits = 1 << 6;

extern "CoreFoundation" fn CFRelease(value: *const anyopaque) callconv(.c) void;
extern "CoreFoundation" fn CFStringCreateWithBytes(
    allocator: ?*const anyopaque,
    bytes: [*]const u8,
    byte_count: CFIndex,
    encoding: CFStringEncoding,
    external_representation: u8,
) callconv(.c) ?CFStringRef;
extern "CoreFoundation" fn CFStringGetLength(value: CFStringRef) callconv(.c) CFIndex;
extern "CoreFoundation" fn CFStringGetMaximumSizeForEncoding(
    length: CFIndex,
    encoding: CFStringEncoding,
) callconv(.c) CFIndex;
extern "CoreFoundation" fn CFStringGetCString(
    value: CFStringRef,
    buffer: [*]u8,
    buffer_size: CFIndex,
    encoding: CFStringEncoding,
) callconv(.c) u8;
extern "CoreFoundation" fn CFURLCopyFileSystemPath(
    url: CFURLRef,
    path_style: CFIndex,
) callconv(.c) ?CFStringRef;
extern "CoreFoundation" fn CFArrayGetCount(array: CFArrayRef) callconv(.c) CFIndex;
extern "CoreFoundation" fn CFArrayGetValueAtIndex(
    array: CFArrayRef,
    index: CFIndex,
) callconv(.c) ?*const anyopaque;

extern "CoreText" fn CTFontCreateUIFontForLanguage(
    ui_type: u32,
    size: f64,
    language: ?CFStringRef,
) callconv(.c) ?CTFontRef;
extern "CoreText" fn CTFontCreateWithName(
    name: CFStringRef,
    size: f64,
    matrix: ?*const anyopaque,
) callconv(.c) ?CTFontRef;
extern "CoreText" fn CTFontCreateCopyWithSymbolicTraits(
    font: CTFontRef,
    size: f64,
    matrix: ?*const anyopaque,
    value: CTFontSymbolicTraits,
    mask: CTFontSymbolicTraits,
) callconv(.c) ?CTFontRef;
extern "CoreText" fn CTFontCreateForStringWithLanguage(
    current_font: CTFontRef,
    string: CFStringRef,
    range: CFRange,
    language: ?CFStringRef,
) callconv(.c) ?CTFontRef;
extern "CoreText" fn CTFontCopyAttribute(
    font: CTFontRef,
    attribute: CFStringRef,
) callconv(.c) ?*const anyopaque;
extern "CoreText" fn CTFontCopyPostScriptName(font: CTFontRef) callconv(.c) ?CFStringRef;
extern "CoreText" fn CTFontCopyFamilyName(font: CTFontRef) callconv(.c) ?CFStringRef;
extern "CoreText" fn CTFontManagerCopyAvailableFontFamilyNames() callconv(.c) ?CFArrayRef;
extern "CoreText" var kCTFontURLAttribute: CFStringRef;

pub const Discovery = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cache: query_cache.Cache,
    generation_value: u64 = 1,
    catalog_fingerprint: u64 = 0,
    available_value: bool = false,

    pub fn init(allocator: std.mem.Allocator) Discovery {
        const probe = CTFontCreateUIFontForLanguage(ui_font_system, 0, null);
        if (probe) |font| release(font);
        return .{
            .allocator = allocator,
            .cache = query_cache.Cache.init(allocator),
            .catalog_fingerprint = catalogFingerprint(allocator) catch 0,
            .available_value = probe != null,
        };
    }

    pub fn deinit(self: *Discovery) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
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
        const next = try catalogFingerprint(self.allocator);
        if (next == self.catalog_fingerprint) return false;
        self.catalog_fingerprint = next;
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
        if (!self.available_value or query.max_candidates == 0) {
            return try emptyResolution(allocator);
        }
        const language = if (query.language) |value| try createString(value) else null;
        defer if (language) |value| release(value);
        const base = try createBaseFont(query, language);
        defer release(base);
        const styled = applyTraits(base, query) orelse base;
        defer if (styled != base) release(styled);

        var candidates = std.ArrayList(types.Candidate).empty;
        errdefer deinitCandidates(&candidates, allocator);
        if (query.required_codepoint) |codepoint| {
            const fallback = try fallbackForCodepoint(styled, codepoint, language);
            defer release(fallback);
            try appendFont(&candidates, allocator, fallback, query.max_candidates);
            if (candidates.items.len < query.max_candidates and fallback != styled) {
                try appendFont(&candidates, allocator, styled, query.max_candidates);
            }
        } else {
            try appendFont(&candidates, allocator, styled, query.max_candidates);
        }
        return .{
            .allocator = allocator,
            .candidates = try candidates.toOwnedSlice(allocator),
            .provider = .core_text,
        };
    }
};

fn createBaseFont(query: types.Query, language: ?CFStringRef) !CTFontRef {
    const requested_name = query.postscript_name orelse
        if (!isGenericFamily(query.family)) query.family else "";
    if (requested_name.len != 0) {
        const name = try createString(requested_name);
        defer release(name);
        return CTFontCreateWithName(name, 0, null) orelse
            return error.CoreTextFontUnavailable;
    }
    return CTFontCreateUIFontForLanguage(
        if (isMonospaceFamily(query.family)) ui_font_fixed_pitch else ui_font_system,
        0,
        language,
    ) orelse error.CoreTextFontUnavailable;
}

fn applyTraits(base: CTFontRef, query: types.Query) ?CTFontRef {
    var value: CTFontSymbolicTraits = 0;
    var mask: CTFontSymbolicTraits = trait_bold | trait_italic |
        trait_condensed | trait_expanded;
    if (query.weight >= 600) value |= trait_bold;
    if (query.style != .normal) value |= trait_italic;
    if (query.stretch < 90) value |= trait_condensed;
    if (query.stretch > 110) value |= trait_expanded;
    if (value == 0) mask = 0;
    if (mask == 0) return null;
    return CTFontCreateCopyWithSymbolicTraits(base, 0, null, value, mask);
}

fn fallbackForCodepoint(
    base: CTFontRef,
    codepoint: u21,
    language: ?CFStringRef,
) !CTFontRef {
    var encoded: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &encoded);
    const string = try createString(encoded[0..len]);
    defer release(string);
    return CTFontCreateForStringWithLanguage(
        base,
        string,
        .{ .location = 0, .length = CFStringGetLength(string) },
        language,
    ) orelse error.CoreTextFontUnavailable;
}

fn appendFont(
    candidates: *std.ArrayList(types.Candidate),
    allocator: std.mem.Allocator,
    font: CTFontRef,
    max_candidates: usize,
) !void {
    if (candidates.items.len >= max_candidates) return;
    const url_value = CTFontCopyAttribute(font, kCTFontURLAttribute) orelse return;
    defer CFRelease(url_value);
    const url: CFURLRef = @ptrCast(@alignCast(url_value));
    const path_string = CFURLCopyFileSystemPath(url, posix_path_style) orelse return;
    defer release(path_string);
    const path = try copyString(allocator, path_string);
    defer allocator.free(path);
    const family_string = CTFontCopyFamilyName(font);
    defer if (family_string) |value| release(value);
    const family = if (family_string) |value| try copyString(allocator, value) else null;
    defer if (family) |value| allocator.free(value);
    const postscript_string = CTFontCopyPostScriptName(font);
    defer if (postscript_string) |value| release(value);
    const postscript = if (postscript_string) |value| try copyString(allocator, value) else null;
    defer if (postscript) |value| allocator.free(value);
    for (candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.path, path) and
            optionalEqual(candidate.postscript_name, postscript)) return;
    }
    const provider_index: u32 = @truncate(std.hash.Wyhash.hash(
        0,
        postscript orelse path,
    ));
    try candidates.append(allocator, try types.Candidate.init(
        allocator,
        path,
        family,
        postscript,
        null,
        provider_index,
        0,
        .core_text,
    ));
}

fn emptyResolution(allocator: std.mem.Allocator) !types.Resolution {
    return .{
        .allocator = allocator,
        .candidates = try allocator.alloc(types.Candidate, 0),
        .provider = .core_text,
    };
}

fn catalogFingerprint(allocator: std.mem.Allocator) !u64 {
    const names = CTFontManagerCopyAvailableFontFamilyNames() orelse return 0;
    defer release(names);
    var hash = std.hash.Wyhash.init(0);
    const count = CFArrayGetCount(names);
    if (count < 0) return error.InvalidCoreTextFontCatalog;
    var index: CFIndex = 0;
    while (index < count) : (index += 1) {
        const raw = CFArrayGetValueAtIndex(names, index) orelse continue;
        const name: CFStringRef = @ptrCast(@alignCast(raw));
        const bytes = try copyString(allocator, name);
        hash.update(bytes);
        hash.update(&.{0});
        allocator.free(bytes);
    }
    return hash.final();
}

fn createString(value: []const u8) !CFStringRef {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    return CFStringCreateWithBytes(
        null,
        value.ptr,
        @intCast(value.len),
        utf8_encoding,
        0,
    ) orelse error.OutOfMemory;
}

fn copyString(allocator: std.mem.Allocator, value: CFStringRef) ![]u8 {
    const maximum = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(value),
        utf8_encoding,
    );
    if (maximum < 0) return error.InvalidCoreTextString;
    const buffer = try allocator.alloc(u8, @as(usize, @intCast(maximum)) + 1);
    errdefer allocator.free(buffer);
    if (CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), utf8_encoding) == 0) {
        return error.InvalidCoreTextString;
    }
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    if (len == buffer.len) return error.InvalidCoreTextString;
    const result = try allocator.dupe(u8, buffer[0..len]);
    allocator.free(buffer);
    return result;
}

fn isGenericFamily(family: []const u8) bool {
    return family.len == 0 or isMonospaceFamily(family) or
        std.ascii.eqlIgnoreCase(family, "sans-serif") or
        std.ascii.eqlIgnoreCase(family, "system-ui") or
        std.ascii.eqlIgnoreCase(family, "ui-sans-serif") or
        std.ascii.eqlIgnoreCase(family, "emoji") or
        std.ascii.eqlIgnoreCase(family, "ui-emoji");
}

fn isMonospaceFamily(family: []const u8) bool {
    return std.ascii.eqlIgnoreCase(family, "monospace") or
        std.ascii.eqlIgnoreCase(family, "ui-monospace");
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn deinitCandidates(
    candidates: *std.ArrayList(types.Candidate),
    allocator: std.mem.Allocator,
) void {
    for (candidates.items) |*candidate| candidate.deinit();
    candidates.deinit(allocator);
}

fn release(value: anytype) void {
    CFRelease(@ptrCast(value));
}
