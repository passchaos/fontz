//! Lease-epoch cmap eligibility supplied to catalog matching.

const std = @import("std");
const coverage_cache = @import("coverage_cache.zig");

pub const Filter = struct {
    cache: *coverage_cache.Cache,
    io: std.Io,
    codepoint: u21,
    epoch: u64,

    pub fn accept(self: *const Filter, face: anytype) !bool {
        return self.cache.coversCodepoint(self.io, face.path, face.face_index, self.codepoint, self.epoch) catch |err| switch (err) {
            // An allocation failure must not become a cached missing glyph.
            error.OutOfMemory => return err,
            else => return false,
        };
    }
};
