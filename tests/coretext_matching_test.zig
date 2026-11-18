//! macOS-only differential: fontz descriptor resolution vs Core Text.
//!
//! Core Text is used only as an oracle. fontz never links CoreText; this test
//! declares the small C surface it needs and compares PostScript identities for
//! the same family/weight/stretch/style queries.
//!
//! Run with `zig build test-macos-coretext` on a macOS host. Families that
//! Core Text cannot resolve are skipped so the gate survives system-font churn.

const std = @import("std");
const builtin = @import("builtin");
const fontz = @import("fontz");

const CFTypeRef = *const anyopaque;
const CFStringRef = CFTypeRef;
const CFDictionaryRef = CFTypeRef;
const CFNumberRef = CFTypeRef;
const CTFontDescriptorRef = CFTypeRef;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberFloat32Type: c_int = 5;

extern const kCTFontFamilyNameAttribute: CFStringRef;
extern const kCTFontTraitsAttribute: CFStringRef;
extern const kCTFontNameAttribute: CFStringRef;
extern const kCTFontWeightTrait: CFStringRef;
extern const kCTFontWidthTrait: CFStringRef;
extern const kCTFontSlantTrait: CFStringRef;

extern "c" fn CFRelease(value: CFTypeRef) void;
extern "c" fn CFStringCreateWithBytes(
    allocator: ?CFTypeRef,
    bytes: [*]const u8,
    length: c_long,
    encoding: u32,
    external: u8,
) ?CFStringRef;
extern "c" fn CFStringGetCString(
    string: CFStringRef,
    buffer: [*]u8,
    buffer_size: c_long,
    encoding: u32,
) u8;
extern "c" fn CFNumberCreate(
    allocator: ?CFTypeRef,
    number_type: c_int,
    value: *const anyopaque,
) ?CFNumberRef;
extern "c" fn CFDictionaryCreate(
    allocator: ?CFTypeRef,
    keys: [*]const ?CFTypeRef,
    values: [*]const ?CFTypeRef,
    count: c_long,
    key_callbacks: ?CFTypeRef,
    value_callbacks: ?CFTypeRef,
) ?CFDictionaryRef;
extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: CFDictionaryRef) ?CTFontDescriptorRef;
extern "c" fn CTFontDescriptorCreateMatchingFontDescriptor(
    descriptor: CTFontDescriptorRef,
    mandatory_attributes: ?CFTypeRef,
) ?CTFontDescriptorRef;
extern "c" fn CTFontDescriptorCopyAttribute(descriptor: CTFontDescriptorRef, attribute: CFStringRef) ?CFTypeRef;

fn cfString(value: []const u8) CFStringRef {
    return CFStringCreateWithBytes(null, value.ptr, @intCast(value.len), kCFStringEncodingUTF8, 0) orelse unreachable;
}

fn coretextMatch(buffer: []u8, family: []const u8, weight: u16, stretch: u16, italic: bool) ?[]const u8 {
    const family_str = cfString(family);
    defer CFRelease(family_str);

    var weight_value: f32 = weightTrait(weight);
    var width_value: f32 = widthTrait(stretch);
    var slant_value: f32 = if (italic) 1 else 0;
    const weight_num = CFNumberCreate(null, kCFNumberFloat32Type, &weight_value) orelse unreachable;
    defer CFRelease(weight_num);
    const width_num = CFNumberCreate(null, kCFNumberFloat32Type, &width_value) orelse unreachable;
    defer CFRelease(width_num);
    const slant_num = CFNumberCreate(null, kCFNumberFloat32Type, &slant_value) orelse unreachable;
    defer CFRelease(slant_num);

    const trait_keys = [_]?CFTypeRef{ kCTFontWeightTrait, kCTFontWidthTrait, kCTFontSlantTrait };
    const trait_values = [_]?CFTypeRef{ weight_num, width_num, slant_num };
    const traits = CFDictionaryCreate(null, &trait_keys, &trait_values, 3, null, null) orelse unreachable;
    defer CFRelease(traits);

    const keys = [_]?CFTypeRef{ kCTFontFamilyNameAttribute, kCTFontTraitsAttribute };
    const values = [_]?CFTypeRef{ family_str, traits };
    const attrs = CFDictionaryCreate(null, &keys, &values, 2, null, null) orelse unreachable;
    defer CFRelease(attrs);

    const descriptor = CTFontDescriptorCreateWithAttributes(attrs) orelse unreachable;
    defer CFRelease(descriptor);
    const matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, null) orelse return null;
    defer CFRelease(matched);
    const name_attr = CTFontDescriptorCopyAttribute(matched, kCTFontNameAttribute) orelse return null;
    defer CFRelease(name_attr);
    if (CFStringGetCString(name_attr, buffer.ptr, @intCast(buffer.len), kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buffer, 0);
}

fn weightTrait(weight: u16) f32 {
    // Core Text normalized weight: 0.0 regular, 0.4 bold, -0.4 light.
    return switch (weight) {
        100 => -0.8,
        200 => -0.6,
        300 => -0.4,
        400 => 0,
        500 => 0.23,
        600 => 0.32,
        700 => 0.4,
        800 => 0.56,
        900 => 0.62,
        else => 0,
    };
}

fn widthTrait(stretch: u16) f32 {
    const s: f32 = @floatFromInt(stretch);
    return (s - 100.0) / 100.0;
}

const Case = struct {
    family: []const u8,
    weight: u16 = 400,
    stretch: u16 = 100,
    style: fontz.Style = .normal,
};

fn expectParity(discovery: *fontz.Discovery, cases: []const Case) !void {
    const allocator = std.testing.allocator;
    var mismatches: usize = 0;
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const expected = coretextMatch(&buffer, case.family, case.weight, case.stretch, case.style != .normal) orelse continue;
        var resolution = try discovery.resolveQuery(allocator, .{
            .family = case.family,
            .weight = case.weight,
            .stretch = case.stretch,
            .style = case.style,
        });
        defer resolution.deinit();
        if (resolution.candidates.len == 0) {
            std.debug.print("fontz has no candidate for {s} w={d}\n", .{ case.family, case.weight });
            mismatches += 1;
            continue;
        }
        const actual = resolution.candidates[0].postscript_name orelse "";
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print(
                "mismatch {s} w={d} stretch={d} style={s}: coretext={s} fontz={s}\n",
                .{ case.family, case.weight, case.stretch, @tagName(case.style), expected, actual },
            );
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "fontz matches Core Text for static system families" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var discovery = fontz.Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    try expectParity(&discovery, &.{
        .{ .family = "Helvetica" },
        .{ .family = "Helvetica", .weight = 700 },
        .{ .family = "Helvetica", .style = .italic },
        .{ .family = "Helvetica", .weight = 700, .style = .italic },
        .{ .family = "Helvetica Neue", .weight = 700 },
        .{ .family = "Arial" },
        .{ .family = "Arial", .weight = 700 },
        .{ .family = "Arial", .style = .italic },
        .{ .family = "Arial", .weight = 700, .style = .italic },
        .{ .family = "Times New Roman" },
        .{ .family = "Times New Roman", .weight = 700, .style = .italic },
        .{ .family = "Courier New", .weight = 700 },
        .{ .family = "Georgia" },
        .{ .family = "Verdana", .weight = 700 },
        .{ .family = "Tahoma" },
        .{ .family = "Trebuchet MS" },
        .{ .family = "Menlo" },
        .{ .family = "Menlo", .weight = 700 },
        .{ .family = "Monaco" },
        .{ .family = "Baskerville" },
        .{ .family = "Futura" },
        .{ .family = "Gill Sans" },
        .{ .family = "Optima" },
        .{ .family = "Palatino" },
        .{ .family = "Apple Symbols" },
    });
}

test "fontz matches Core Text variable named instances" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var discovery = fontz.Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    // PingFang lives under the FontServices reserved root and exposes its
    // weights as fvar named instances rather than separate faces.
    try expectParity(&discovery, &.{
        .{ .family = "PingFang SC" },
        .{ .family = "PingFang SC", .weight = 700 },
        .{ .family = "Hiragino Sans GB" },
    });
}

test "fontz keeps CSS weight policy where Core Text differs" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var discovery = fontz.Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    // Heiti SC ships Light and Medium. CSS Fonts 4 prefers 500 before going
    // below 400, while Core Text picks Light; fontz intentionally follows CSS.
    var resolution = try discovery.resolveQuery(std.testing.allocator, .{ .family = "Heiti SC" });
    defer resolution.deinit();
    if (resolution.candidates.len == 0) return;
    try std.testing.expectEqualStrings("STHeitiSC-Medium", resolution.candidates[0].postscript_name.?);
}

test "fontz fallback chooses a covering macOS system font" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var discovery = fontz.Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    const cases = [_]struct { codepoint: u21, expected: []const u8 }{
        .{ .codepoint = 0x05d0, .expected = "Lucida" },
        .{ .codepoint = 0x0633, .expected = "Arabic" },
        .{ .codepoint = 0x0e01, .expected = "Thonburi" },
        .{ .codepoint = 0x0905, .expected = "Kohinoor" },
        .{ .codepoint = 0x4e2d, .expected = "PingFang" },
        .{ .codepoint = 0x3042, .expected = "Hiragino" },
        .{ .codepoint = 0xac00, .expected = "Gothic" },
        .{ .codepoint = 0x1f600, .expected = "Emoji" },
        .{ .codepoint = 0x0531, .expected = "Armenian" },
    };
    for (cases) |case| {
        var resolution = try discovery.resolveQuery(std.testing.allocator, .{
            .family = "Helvetica",
            .required_codepoint = case.codepoint,
        });
        defer resolution.deinit();
        if (resolution.candidates.len == 0) {
            std.debug.print("no fallback for U+{X:0>4}\n", .{case.codepoint});
            return error.TestUnexpectedResult;
        }
        const path = resolution.candidates[0].path;
        if (std.mem.indexOf(u8, path, case.expected) == null) {
            std.debug.print("U+{X:0>4}: expected {s}, got {s}\n", .{ case.codepoint, case.expected, path });
            return error.TestUnexpectedResult;
        }
    }
}
