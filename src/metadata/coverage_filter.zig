//! Lease-epoch cmap eligibility supplied to catalog matching.

const std = @import("std");
const coverage_cache = @import("coverage_cache.zig");

pub const Filter = struct {
    cache: *coverage_cache.Cache,
    io: std.Io,
    codepoint: u21,
    variation_selector: ?u21 = null,
    epoch: u64,

    pub fn accept(self: *const Filter, face: anytype) !bool {
        const covered = if (self.variation_selector) |selector|
            self.cache.coversVariationSequence(self.io, face.path, face.face_index, self.codepoint, selector, self.epoch)
        else
            self.cache.coversCodepoint(self.io, face.path, face.face_index, self.codepoint, self.epoch);
        return covered catch |err| switch (err) {
            // An allocation failure must not become a cached missing glyph.
            error.OutOfMemory => return err,
            else => return false,
        };
    }
};
