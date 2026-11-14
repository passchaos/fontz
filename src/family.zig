//! CSS family-list tokenization, generic-family classification and shared
//! family-name comparison used by discovery and metadata matching.

const std = @import("std");

pub const FamilyIterator = struct {
    rest: []const u8,

    pub fn init(value: []const u8) FamilyIterator {
        return .{ .rest = value };
    }

    pub fn next(self: *FamilyIterator) ?[]const u8 {
        while (nextSourceItem(&self.rest)) |raw_item| {
            const item = std.mem.trim(u8, raw_item, " \t\r\n");
            if (item.len == 0) continue;
            if (item[0] == '\'' or item[0] == '"') {
                if (item.len >= 2 and item[item.len - 1] == item[0]) {
                    return item[1 .. item.len - 1];
                }
                continue;
            }
            return item;
        }
        return null;
    }
};

fn nextSourceItem(rest: *[]const u8) ?[]const u8 {
    while (rest.*.len != 0) {
        const comma = topLevelComma(rest.*) orelse rest.*.len;
        const item = rest.*[0..comma];
        rest.* = if (comma == rest.*.len) "" else rest.*[comma + 1 ..];
        if (std.mem.trim(u8, item, " \t\r\n").len != 0) return item;
    }
    return null;
}

fn topLevelComma(value: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    for (value, 0..) |c, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != 0) {
            if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth != 0) depth -= 1;
        } else if (c == ',' and depth == 0) {
            return index;
        }
    }
    return null;
}

/// CSS generic family names understood by the discovery layer. The set is a
/// superset of `cangjie.font.database.GenericFamily` so the two packages can
/// agree on generic-family intent without a dependency.
pub const GenericFamily = enum {
    serif,
    sans_serif,
    monospace,
    cursive,
    fantasy,
    system_ui,
    emoji,
    math,
    rounded,
};

/// Classify a CSS generic family name. `null` means the name is concrete.
pub fn genericFamily(name: []const u8) ?GenericFamily {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "serif") or
        std.ascii.eqlIgnoreCase(trimmed, "ui-serif"))
    {
        return .serif;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "sans-serif") or
        std.ascii.eqlIgnoreCase(trimmed, "ui-sans-serif") or
        std.ascii.eqlIgnoreCase(trimmed, "system-ui") or
        std.ascii.eqlIgnoreCase(trimmed, "-apple-system") or
        std.ascii.eqlIgnoreCase(trimmed, "BlinkMacSystemFont"))
    {
        return .sans_serif;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "monospace") or
        std.ascii.eqlIgnoreCase(trimmed, "ui-monospace"))
    {
        return .monospace;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "cursive")) return .cursive;
    if (std.ascii.eqlIgnoreCase(trimmed, "fantasy")) return .fantasy;
    if (std.ascii.eqlIgnoreCase(trimmed, "emoji") or
        std.ascii.eqlIgnoreCase(trimmed, "ui-emoji"))
    {
        return .emoji;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "math")) return .math;
    if (std.ascii.eqlIgnoreCase(trimmed, "ui-rounded")) return .rounded;
    return null;
}

/// A platform-neutral fontconfig-style family name for a generic family.
/// `system_ui` intentionally maps to `sans-serif` because fontconfig has no
/// `system-ui` alias on all distributions.
pub fn genericFamilyName(generic: GenericFamily) []const u8 {
    return switch (generic) {
        .serif => "serif",
        .sans_serif, .system_ui => "sans-serif",
        .monospace => "monospace",
        .cursive => "cursive",
        .fantasy => "fantasy",
        .emoji => "emoji",
        .math => "math",
        .rounded => "sans-serif",
    };
}

/// Map an OpenType `usWidthClass` (1..9) to a CSS font-stretch percentage.
pub fn widthClassToStretch(width_class: u16) u16 {
    return switch (width_class) {
        1 => 50,
        2 => 62,
        3 => 75,
        4 => 87,
        5 => 100,
        6 => 112,
        7 => 125,
        8 => 150,
        9 => 200,
        else => 100,
    };
}

/// Map a CSS font-stretch percentage to the nearest OpenType `usWidthClass`
/// (1..9). Exact CSS/OpenType boundary values round-trip.
pub fn stretchToWidthClass(stretch: u16) u16 {
    const values = [_]u16{ 50, 62, 75, 87, 100, 112, 125, 150, 200 };
    var best_index: u16 = 5;
    var best_distance: u16 = std.math.maxInt(u16);
    for (values, 0..) |value, index| {
        const distance = if (value >= stretch) value - stretch else stretch - value;
        if (distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index + 1);
        }
    }
    return best_index;
}

/// Compare family names case-insensitively while ignoring ASCII whitespace,
/// punctuation, hyphens and underscores. Non-ASCII codepoints are significant
/// and compared exactly, so `宋体` never matches `黑体` merely because both
/// names are outside the ASCII range.
pub fn familyNamesEqual(a: []const u8, b: []const u8) bool {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (true) {
        while (a_index < a.len and isSeparator(a[a_index])) a_index += 1;
        while (b_index < b.len and isSeparator(b[b_index])) b_index += 1;
        if (a_index == a.len or b_index == b.len) {
            return a_index == a.len and b_index == b.len;
        }
        const a_len = std.unicode.utf8ByteSequenceLength(a[a_index]) catch return false;
        const b_len = std.unicode.utf8ByteSequenceLength(b[b_index]) catch return false;
        if (a_len != b_len) return false;
        if (a_len == 1) {
            if (std.ascii.toLower(a[a_index]) != std.ascii.toLower(b[b_index])) {
                return false;
            }
        } else {
            const a_codepoint = std.unicode.utf8Decode(a[a_index..][0..a_len]) catch return false;
            const b_codepoint = std.unicode.utf8Decode(b[b_index..][0..b_len]) catch return false;
            if (a_codepoint != b_codepoint) return false;
        }
        a_index += a_len;
        b_index += b_len;
    }
}

fn isSeparator(byte: u8) bool {
    return byte < 0x80 and !std.ascii.isAlphanumeric(byte);
}

test "family iterator keeps quoted names and skips empty items" {
    var iterator = FamilyIterator.init("  'Noto Sans', \"M PLUS 1p\", , serif ");
    try std.testing.expectEqualStrings("Noto Sans", iterator.next().?);
    try std.testing.expectEqualStrings("M PLUS 1p", iterator.next().?);
    try std.testing.expectEqualStrings("serif", iterator.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());
}

test "generic families are classified consistently" {
    try std.testing.expectEqual(GenericFamily.sans_serif, genericFamily("system-ui").?);
    try std.testing.expectEqual(GenericFamily.monospace, genericFamily("ui-monospace").?);
    try std.testing.expectEqual(GenericFamily.serif, genericFamily("ui-serif").?);
    try std.testing.expectEqual(GenericFamily.emoji, genericFamily("ui-emoji").?);
    try std.testing.expectEqual(GenericFamily.rounded, genericFamily("ui-rounded").?);
    try std.testing.expect(genericFamily("Noto Sans") == null);
}

test "family comparison is UTF-8 aware" {
    try std.testing.expect(familyNamesEqual("Noto Sans", "noto sans"));
    try std.testing.expect(familyNamesEqual("M PLUS 1p", "Mplus 1p"));
    try std.testing.expect(!familyNamesEqual("Noto Sans", "Noto Serif"));
    try std.testing.expect(familyNamesEqual("宋体", "宋体"));
    try std.testing.expect(!familyNamesEqual("宋体", "黑体"));
    try std.testing.expect(!familyNamesEqual("思源黑体", "思源宋体"));
}

test "width class and stretch round-trip" {
    inline for (.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }) |class| {
        try std.testing.expectEqual(
            @as(u16, class),
            stretchToWidthClass(widthClassToStretch(class)),
        );
    }
}
