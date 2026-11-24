//! CSS face ranking over an immutable candidate list.

const std = @import("std");
const types = @import("../types.zig");

/// Check the CSS best face first, then screen remaining candidates if it misses.
/// Small families use stack storage; larger lists remain bounded by the catalog.
/// A filter can own a cmap cache, but cannot retain pointers beyond the lease.
pub fn selectFiltered(
    comptime Face: type,
    allocator: std.mem.Allocator,
    faces: []const Face,
    indices: []const u32,
    query: types.Query,
    filter: anytype,
) !?*const Face {
    const preferred = selectBestFace(Face, faces, indices, query) orelse return null;
    if (try filter.accept(preferred)) return preferred;
    var buffer: [64]u32 = undefined;
    const eligible = if (indices.len <= buffer.len)
        buffer[0..indices.len]
    else
        try allocator.alloc(u32, indices.len);
    defer if (indices.len > buffer.len) allocator.free(eligible);
    var count: usize = 0;
    for (indices) |face_index| {
        if (face_index >= faces.len) continue;
        if (&faces[face_index] == preferred) continue;
        if (try filter.accept(&faces[face_index])) {
            eligible[count] = face_index;
            count += 1;
        }
    }
    return selectBestFace(Face, faces, eligible[0..count], query);
}

/// CSS Fonts Level 3 face selection over a candidate index list.
pub fn selectBestFace(
    comptime Face: type,
    faces: []const Face,
    indices: []const u32,
    query: types.Query,
) ?*const Face {
    if (indices.len == 0) return null;
    const stretch = matchingStretch(Face, faces, indices, query.stretch) orelse return null;
    const style = matchingStyle(Face, faces, indices, stretch, query.style) orelse return null;
    const weight = matchingWeight(Face, faces, indices, stretch, style, query.weight) orelse return null;
    var best: ?*const Face = null;
    var best_score: f32 = std.math.inf(f32);
    for (indices) |index| {
        if (index >= faces.len) continue;
        const face = &faces[index];
        if (face.stretch != stretch or face.style != style or face.weight != weight) continue;
        if (query.opsz) |requested| {
            const score = opszScore(Face, face, requested);
            if (best == null or score < best_score) {
                best = face;
                best_score = score;
            }
        } else {
            return face;
        }
    }
    return best;
}

/// Lower is better: a containing range wins, then the nearest range, and
/// faces without `opsz` metadata rank last.
fn opszScore(comptime Face: type, face: *const Face, requested: f32) f32 {
    const min = face.opsz_min orelse return std.math.inf(f32);
    const max = face.opsz_max orelse min;
    if (requested < min) return min - requested;
    if (requested > max) return requested - max;
    const default = face.opsz_default orelse min;
    return @abs(requested - default) * 1e-6;
}

fn matchingStretch(comptime Face: type, faces: []const Face, indices: []const u32, requested: u16) ?u16 {
    for (indices) |index| {
        if (index < faces.len and faces[index].stretch == requested) return requested;
    }
    if (requested <= 100) {
        var below: ?u16 = null;
        for (indices) |index| {
            if (index >= faces.len) continue;
            const value = faces[index].stretch;
            if (value < requested and (below == null or value > below.?)) below = value;
        }
        if (below) |value| return value;
        var above: ?u16 = null;
        for (indices) |index| {
            if (index >= faces.len) continue;
            const value = faces[index].stretch;
            if (value > requested and (above == null or value < above.?)) above = value;
        }
        return above;
    }
    var above: ?u16 = null;
    for (indices) |index| {
        if (index >= faces.len) continue;
        const value = faces[index].stretch;
        if (value > requested and (above == null or value < above.?)) above = value;
    }
    if (above) |value| return value;
    var below: ?u16 = null;
    for (indices) |index| {
        if (index >= faces.len) continue;
        const value = faces[index].stretch;
        if (value < requested and (below == null or value > below.?)) below = value;
    }
    return below;
}

fn matchingStyle(
    comptime Face: type,
    faces: []const Face,
    indices: []const u32,
    stretch: u16,
    requested: types.Style,
) ?types.Style {
    const preference = switch (requested) {
        .normal => [_]types.Style{ .normal, .oblique, .italic },
        .italic => [_]types.Style{ .italic, .oblique, .normal },
        .oblique => [_]types.Style{ .oblique, .italic, .normal },
    };
    for (preference) |style| {
        for (indices) |index| {
            if (index >= faces.len) continue;
            const face = &faces[index];
            if (face.stretch == stretch and face.style == style) return style;
        }
    }
    return null;
}

fn matchingWeight(
    comptime Face: type,
    faces: []const Face,
    indices: []const u32,
    stretch: u16,
    style: types.Style,
    requested: u16,
) ?u16 {
    const eligible = struct {
        fn check(faces_: []const Face, indices_: []const u32, stretch_: u16, style_: types.Style, weight_: u16) bool {
            for (indices_) |index| {
                if (index >= faces_.len) continue;
                const face = &faces_[index];
                if (face.stretch == stretch_ and face.style == style_ and face.weight == weight_) return true;
            }
            return false;
        }
    };
    if (eligible.check(faces, indices, stretch, style, requested)) return requested;
    if (requested >= 400 and requested < 450 and eligible.check(faces, indices, stretch, style, 500)) {
        return 500;
    }
    if (requested >= 450 and requested <= 500 and eligible.check(faces, indices, stretch, style, 400)) {
        return 400;
    }
    if (requested <= 500) {
        var below: ?u16 = null;
        for (indices) |index| {
            if (index >= faces.len) continue;
            const face = &faces[index];
            if (face.stretch != stretch or face.style != style) continue;
            const value = face.weight;
            if (value <= requested and (below == null or value > below.?)) below = value;
        }
        if (below) |value| return value;
        var above: ?u16 = null;
        for (indices) |index| {
            if (index >= faces.len) continue;
            const face = &faces[index];
            if (face.stretch != stretch or face.style != style) continue;
            const value = face.weight;
            if (value > requested and (above == null or value < above.?)) above = value;
        }
        return above;
    }
    var above: ?u16 = null;
    for (indices) |index| {
        if (index >= faces.len) continue;
        const face = &faces[index];
        if (face.stretch != stretch or face.style != style) continue;
        const value = face.weight;
        if (value >= requested and (above == null or value < above.?)) above = value;
    }
    if (above) |value| return value;
    var below: ?u16 = null;
    for (indices) |index| {
        if (index >= faces.len) continue;
        const face = &faces[index];
        if (face.stretch != stretch or face.style != style) continue;
        const value = face.weight;
        if (value < requested and (below == null or value > below.?)) below = value;
    }
    return below;
}
