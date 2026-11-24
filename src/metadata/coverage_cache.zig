//! Per-discovery cmap reuse across different descriptor/codepoint queries.
//!
//! Keys own the path and distinguish TTC face indexes. A generation change
//! drops all entries. The provider mutex protects this cache; no table bytes
//! escape into a Resolution or the process-wide metadata index.

const std = @import("std");
const cmap = @import("cmap.zig");

pub const max_entries = 64;
pub const max_bytes = 16 * 1024 * 1024;

pub const Limits = struct {
    entries: usize = max_entries,
    /// Retained cmap bytes plus owned path bytes. A table that cannot fit is
    /// still queried, then freed; the cache budget never changes coverage.
    bytes: usize = max_bytes,
};

test {
    _ = @import("coverage_tests.zig");
}

const Entry = struct {
    path: []const u8,
    face_index: u32,
    /// Null records a structural failure, such as a missing cmap. IO failures
    /// are not installed and therefore remain retryable.
    table: ?[]u8,
    num_glyphs: ?u16,
    glyph_count_loaded: bool,
    stamp: u64,

    fn bytes(self: Entry) usize {
        return self.path.len + if (self.table) |table| table.len else 0;
    }

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.table) |table| allocator.free(table);
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    entries: std.ArrayList(Entry) = .empty,
    generation: ?u64 = null,
    resident_bytes: usize = 0,
    stamp: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    reads: cmap.ReadStats = .{},

    pub fn init(allocator: std.mem.Allocator) Cache {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Cache {
        return .{
            .allocator = allocator,
            .limits = .{
                .entries = @min(limits.entries, max_entries),
                .bytes = @min(limits.bytes, max_bytes),
            },
        };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Clear retained tables without resetting cumulative work counters.
    pub fn clear(self: *Cache) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        self.resident_bytes = 0;
        self.generation = null;
    }

    pub fn coversCodepoint(
        self: *Cache,
        io: std.Io,
        path: []const u8,
        face_index: u32,
        codepoint: u21,
        generation: u64,
    ) !bool {
        return self.covers(io, path, face_index, codepoint, null, generation);
    }

    pub fn coversVariationSequence(
        self: *Cache,
        io: std.Io,
        path: []const u8,
        face_index: u32,
        base: u21,
        selector: u21,
        generation: u64,
    ) !bool {
        return self.covers(io, path, face_index, base, selector, generation);
    }

    fn covers(
        self: *Cache,
        io: std.Io,
        path: []const u8,
        face_index: u32,
        codepoint: u21,
        selector: ?u21,
        generation: u64,
    ) !bool {
        if (!@import("../variation.zig").validCoverage(codepoint, selector)) return false;
        if (self.generation == null or self.generation.? != generation) {
            self.clear();
            self.generation = generation;
        }
        if (self.stamp == std.math.maxInt(u64)) {
            for (self.entries.items) |*entry| entry.stamp >>= 1;
            self.stamp >>= 1;
        }
        self.stamp += 1;
        for (self.entries.items) |*entry| {
            if (entry.face_index != face_index or !std.mem.eql(u8, entry.path, path)) continue;
            self.hits += 1;
            entry.stamp = self.stamp;
            if (selector != null and entry.table != null and !entry.glyph_count_loaded) {
                // Failed IO remains retryable; do not record a missing maxp.
                entry.num_glyphs = try cmap.readGlyphCount(io, path, face_index, &self.reads);
                entry.glyph_count_loaded = true;
            }
            return coveredBy(entry.table, entry.num_glyphs, codepoint, selector);
        }
        self.misses += 1;
        const data = try cmap.readCoverageData(io, self.allocator, path, face_index, selector != null, &self.reads);
        const table = data.table;
        var adopted = false;
        defer if (!adopted) {
            if (table) |bytes| self.allocator.free(bytes);
        };
        const covered = coveredBy(table, data.num_glyphs, codepoint, selector);
        // Cache installation is best effort. A failed key/entry allocation must
        // not turn a successfully read glyph into a missing glyph.
        adopted = self.put(path, face_index, table, data.num_glyphs, selector != null) catch false;
        return covered;
    }

    /// Adopts table only on true. Oversized/disabled caches query uncached.
    fn put(self: *Cache, path: []const u8, face_index: u32, table: ?[]u8, num_glyphs: ?u16, glyph_count_loaded: bool) !bool {
        const bytes = std.math.add(usize, path.len, if (table) |data| data.len else 0) catch return false;
        if (self.limits.entries == 0 or bytes > self.limits.bytes) return false;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        if (self.entries.capacity < self.limits.entries) {
            try self.entries.ensureTotalCapacityPrecise(self.allocator, self.limits.entries);
        }
        while (self.entries.items.len >= self.limits.entries or
            self.resident_bytes > self.limits.bytes - bytes)
        {
            self.evictOldest();
        }
        self.entries.appendAssumeCapacity(.{
            .path = owned_path,
            .face_index = face_index,
            .table = table,
            .num_glyphs = num_glyphs,
            .glyph_count_loaded = glyph_count_loaded,
            .stamp = self.stamp,
        });
        self.resident_bytes += bytes;
        return true;
    }

    fn evictOldest(self: *Cache) void {
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |entry, index| {
            if (entry.stamp < self.entries.items[oldest].stamp) oldest = index;
        }
        const entry = self.entries.swapRemove(oldest);
        self.resident_bytes -= entry.bytes();
        entry.deinit(self.allocator);
    }
};

fn coveredBy(table: ?[]const u8, num_glyphs: ?u16, base: u21, selector: ?u21) bool {
    const bytes = table orelse return false;
    if (selector) |value| return cmap.tableCoversVariationSequence(bytes, base, value, num_glyphs orelse return false);
    return cmap.tableCovers(bytes, base);
}
