//! Cross-platform environment variable lookup without linking libc.

const std = @import("std");
const builtin = @import("builtin");

/// Returns an owned UTF-8 value for `name`, or null when unset/unavailable.
pub fn get(allocator: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) return getWindows(allocator, name);
    return getPosix(allocator, name);
}

fn getPosix(allocator: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    const threaded = std.Options.debug_threaded_io orelse return null;
    const slice = threaded.environ.process_environ.block.slice;
    for (slice) |entry_ptr| {
        const entry = std.mem.span(entry_ptr orelse continue);
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..separator], name)) {
            return allocator.dupe(u8, entry[separator + 1 ..]) catch null;
        }
    }
    return null;
}

fn getWindows(allocator: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    const environment = std.os.windows.peb().ProcessParameters.Environment;
    var index: usize = 0;
    while (environment[index] != 0) {
        const key_start = index;
        while (environment[index] != 0 and environment[index] != '=') : (index += 1) {}
        const key = environment[key_start..index];
        if (environment[index] != '=') {
            index += 1;
            continue;
        }
        index += 1;
        const value_start = index;
        while (environment[index] != 0) : (index += 1) {}
        const value = environment[value_start..index];
        index += 1;
        if (keyEquals(key, name)) {
            return std.unicode.utf16LeToUtf8Alloc(allocator, value) catch null;
        }
    }
    return null;
}

fn keyEquals(key: []const u16, comptime name: []const u8) bool {
    if (key.len != name.len) return false;
    for (key, name) |unit, expected| {
        if (unit != expected) return false;
    }
    return true;
}
