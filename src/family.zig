//! CSS family-list tokenization used by discovery and metadata matching.

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

test "family iterator keeps quoted names and skips empty items" {
    var iterator = FamilyIterator.init("  'Noto Sans', \"M PLUS 1p\", , serif ");
    try std.testing.expectEqualStrings("Noto Sans", iterator.next().?);
    try std.testing.expectEqualStrings("M PLUS 1p", iterator.next().?);
    try std.testing.expectEqualStrings("serif", iterator.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());
}
