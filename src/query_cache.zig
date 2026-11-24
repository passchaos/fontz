//! Small owned cache for platform font resolutions.

const std = @import("std");
const types = @import("types.zig");

const max_entries = 32;

/// An owned miss and the catalog epoch used to produce it.
pub const EpochResolution = struct {
    resolution: types.Resolution,
    index_generation: u64,
};

const Key = struct {
    allocator: std.mem.Allocator,
    family: []u8,
    postscript_name: ?[]u8,
    language: ?[]u8,
    weight: u16,
    stretch: u16,
    style: types.Style,
    required_codepoint: ?u21,
    required_variation_selector: ?u21,
    opsz: ?f32,
    max_candidates: usize,

    fn init(allocator: std.mem.Allocator, query: types.Query) !Key {
        const family = try allocator.dupe(u8, query.family);
        errdefer allocator.free(family);
        const postscript = if (query.postscript_name) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (postscript) |value| allocator.free(value);
        const language = if (query.language) |value|
            try allocator.dupe(u8, value)
        else
            null;
        return .{
            .allocator = allocator,
            .family = family,
            .postscript_name = postscript,
            .language = language,
            .weight = query.weight,
            .stretch = query.stretch,
            .style = query.style,
            .required_codepoint = query.required_codepoint,
            .required_variation_selector = query.required_variation_selector,
            .opsz = query.opsz,
            .max_candidates = query.max_candidates,
        };
    }

    fn deinit(self: *Key) void {
        self.allocator.free(self.family);
        if (self.postscript_name) |value| self.allocator.free(value);
        if (self.language) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn eql(self: Key, query: types.Query) bool {
        return std.mem.eql(u8, self.family, query.family) and
            optionalStringEql(self.postscript_name, query.postscript_name) and
            optionalStringEql(self.language, query.language) and
            self.weight == query.weight and
            self.stretch == query.stretch and
            self.style == query.style and
            self.required_codepoint == query.required_codepoint and
            self.required_variation_selector == query.required_variation_selector and
            self.opsz == query.opsz and
            self.max_candidates == query.max_candidates;
    }
};

const Entry = struct {
    key: Key,
    resolution: types.Resolution,
    generation: u64,
    index_generation: u64,
    stamp: u64,

    fn deinit(self: *Entry) void {
        self.key.deinit();
        self.resolution.deinit();
        self.* = undefined;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    stamp: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    /// The owner mutex must be held before reading either generation and for
    /// the whole call. Exact hits only retain their owned candidate storage.
    pub fn resolveCached(
        cache: *Cache,
        allocator: std.mem.Allocator,
        generation: u64,
        index_generation: u64,
        query: types.Query,
        owner: anytype,
    ) !types.Resolution {
        if (!query.validCoverage()) return .{
            .allocator = allocator,
            .candidates = try allocator.alloc(types.Candidate, 0),
            .provider = .metadata_index,
        };
        if (try cache.get(query, generation, index_generation, allocator)) |hit| return hit;
        const resolved = try owner.resolveUncachedLocked(owner.allocator, query);
        var resolution = resolved.resolution;
        var shared = resolution.intoShared() catch |err| {
            resolution.deinit();
            return err;
        };
        errdefer shared.deinit();
        var cache_ref = shared.retain();
        cache.put(query, generation, resolved.index_generation, cache_ref) catch |err| {
            cache_ref.deinit();
            return err;
        };
        return shared;
    }

    pub fn cachedStats(
        cache: *Cache,
        mutex: *std.Io.Mutex,
        generation: u64,
    ) types.DiscoveryStats {
        mutex.lockUncancelable(std.Options.debug_io);
        defer mutex.unlock(std.Options.debug_io);
        return cache.stats(generation);
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Cache) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.clearRetainingCapacity();
    }

    pub fn get(
        self: *Cache,
        query: types.Query,
        generation: u64,
        index_generation: u64,
        out_allocator: std.mem.Allocator,
    ) !?types.Resolution {
        for (self.entries.items) |*entry| {
            if (entry.generation != generation or
                entry.index_generation != index_generation or
                !entry.key.eql(query)) continue;
            self.stamp +%= 1;
            entry.stamp = self.stamp;
            self.hits += 1;
            if (entry.resolution.shared != null) return entry.resolution.retain();
            return try entry.resolution.clone(out_allocator);
        }
        self.misses += 1;
        return null;
    }

    /// Adopt `resolution` into the cache. The caller must not deinit it after a
    /// successful return. The cached entry is reference-counted; later `get`
    /// calls retain it without copying candidates.
    pub fn put(
        self: *Cache,
        query: types.Query,
        generation: u64,
        index_generation: u64,
        resolution: types.Resolution,
    ) !void {
        var key = try Key.init(self.allocator, query);
        errdefer key.deinit();
        if (self.entries.items.len < max_entries) {
            try self.entries.ensureUnusedCapacity(self.allocator, 1);
        }
        const shared = try resolution.intoShared();
        self.stamp +%= 1;
        const entry = Entry{
            .key = key,
            .resolution = shared,
            .generation = generation,
            .index_generation = index_generation,
            .stamp = self.stamp,
        };
        if (self.entries.items.len < max_entries) {
            self.entries.appendAssumeCapacity(entry);
            return;
        }
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |existing, index| {
            if (existing.stamp < self.entries.items[oldest].stamp) oldest = index;
        }
        self.entries.items[oldest].deinit();
        self.entries.items[oldest] = entry;
    }

    pub fn stats(self: *const Cache, generation: u64) types.DiscoveryStats {
        return .{
            .generation = generation,
            .cache_hits = self.hits,
            .cache_misses = self.misses,
            .cache_entries = self.entries.items.len,
        };
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "query cache owns positive and negative resolutions" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const query = types.Query{ .family = "Example Sans" };
    var candidates = try std.testing.allocator.alloc(types.Candidate, 1);
    candidates[0] = try types.Candidate.init(
        std.testing.allocator,
        "/fonts/example.ttf",
        "Example Sans",
        "ExampleSans-Regular",
        0,
        0,
        0,
        .fontconfig,
    );
    try cache.put(query, 1, 0, .{
        .allocator = std.testing.allocator,
        .candidates = candidates,
        .provider = .fontconfig,
    });
    var hit = (try cache.get(query, 1, 0, std.testing.allocator)).?;
    defer hit.deinit();
    try std.testing.expectEqualStrings("Example Sans", hit.candidates[0].family.?);

    const missing_query = types.Query{ .family = "Missing" };
    try cache.put(missing_query, 1, 0, .{
        .allocator = std.testing.allocator,
        .candidates = try std.testing.allocator.alloc(types.Candidate, 0),
        .provider = .fontconfig,
    });
    var missing = (try cache.get(missing_query, 1, 0, std.testing.allocator)).?;
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    const stats = cache.stats(1);
    try std.testing.expectEqual(@as(u64, 2), stats.cache_hits);
    try std.testing.expectEqual(@as(usize, 2), stats.cache_entries);

    // A new process-wide index generation invalidates every cached query.
    try std.testing.expect((try cache.get(query, 1, 1, std.testing.allocator)) == null);
}

test "variation sequence query cache keys base selector and nominal resolutions independently" {
    const a = std.testing.allocator;
    var cache = Cache.init(a);
    defer cache.deinit();
    const covered = types.Query{ .family = "UVS Cache", .required_codepoint = 0x2764, .required_variation_selector = 0xfe0f };
    var candidates = try a.alloc(types.Candidate, 1);
    candidates[0] = try types.Candidate.init(a, "/fixture/uvs.ttf", "UVS Cache", "UVSCache-Regular", 3, 3, 1, .metadata_index);
    try cache.put(covered, 1, 5, .{ .allocator = a, .candidates = candidates, .provider = .metadata_index });
    var unsupported = covered;
    unsupported.required_variation_selector = 0xfe0e;
    try cache.put(unsupported, 1, 5, .{ .allocator = a, .candidates = try a.alloc(types.Candidate, 0), .provider = .metadata_index });
    var hit = (try cache.get(covered, 1, 5, a)).?;
    defer hit.deinit();
    try std.testing.expectEqual(@as(usize, 1), hit.candidates.len);
    try std.testing.expectEqual(@as(?u32, 3), hit.candidates[0].face_index);
    try std.testing.expectEqual(@as(u16, 1), hit.candidates[0].named_instance);
    var negative = (try cache.get(unsupported, 1, 5, a)).?;
    defer negative.deinit();
    try std.testing.expectEqual(@as(usize, 0), negative.candidates.len);
    var different_base = covered;
    different_base.required_codepoint = 0x4e2d;
    try std.testing.expect((try cache.get(different_base, 1, 5, a)) == null);
    var nominal = covered;
    nominal.required_variation_selector = null;
    try std.testing.expect((try cache.get(nominal, 1, 5, a)) == null);
    try std.testing.expect((try cache.get(covered, 1, 6, a)) == null);
    try std.testing.expect((try cache.get(unsupported, 2, 5, a)) == null);
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var retained = (try cache.get(covered, 1, 5, fail.allocator())).?;
    defer retained.deinit();
    try std.testing.expect(hit.shared == retained.shared);
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);
}
