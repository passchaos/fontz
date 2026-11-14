const std = @import("std");

pub const Role = enum {
    ui,
    cjk,
    emoji,
    monospace,
    symbol,
};

pub const Provider = enum {
    fallback_paths,
    /// Pure-Zig system-font catalog (metadata index + fontconfig config).
    metadata_index,
    /// Retained for compatibility with older diagnostics.
    fontconfig,
    core_text,
    direct_write,
};

pub const Style = enum {
    normal,
    italic,
    oblique,
};

/// Descriptor for one system-font lookup.
///
/// `family` is a CSS `font-family` list (`"Noto Sans", sans-serif`), not a
/// single concrete name. Providers walk the list in order.
///
/// `weight` is an OpenType/CSS weight in the range 1..1000 (400 is regular).
/// `stretch` is a CSS font-stretch percentage (100 is normal, valid roughly
/// 50..200). `required_codepoint` must be a Unicode scalar value; callers
/// should reject surrogate and out-of-range values before building a query.
pub const Query = struct {
    family: []const u8,
    postscript_name: ?[]const u8 = null,
    weight: u16 = 400,
    stretch: u16 = 100,
    style: Style = .normal,
    language: ?[]const u8 = null,
    required_codepoint: ?u21 = null,
    max_candidates: usize = 8,
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    family: ?[]u8 = null,
    postscript_name: ?[]u8 = null,
    /// Exact collection face. The pure provider resolves this from the font's
    /// metadata; callers may also use the PostScript name as a stable identity.
    face_index: ?u32 = null,
    provider_index: u32 = 0,
    named_instance: u16 = 0,
    provider: Provider,
    /// Face attributes when the provider exposes them. These are advisory for
    /// consumers that validate a candidate before installation.
    weight: u16 = 400,
    /// CSS font-stretch percentage (100 is normal).
    stretch: u16 = 100,
    style: Style = .normal,
    monospaced: bool = false,
    /// Single allocation backing `path`, `family` and `postscript_name` when
    /// produced by `init`. Candidates built by external code may leave this
    /// null and own each string separately.
    storage: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        family: ?[]const u8,
        postscript_name: ?[]const u8,
        face_index: ?u32,
        provider_index: u32,
        named_instance: u16,
        provider: Provider,
    ) !Candidate {
        const family_len = if (family) |value| value.len else 0;
        const postscript_len = if (postscript_name) |value| value.len else 0;
        const total_len = path.len + family_len + postscript_len;
        const storage = try allocator.alloc(u8, total_len);
        errdefer allocator.free(storage);

        @memcpy(storage[0..path.len], path);
        var offset = path.len;
        const owned_family: ?[]u8 = if (family) |value| blk: {
            const dest = storage[offset..][0..value.len];
            @memcpy(dest, value);
            offset += value.len;
            break :blk dest;
        } else null;
        const owned_postscript: ?[]u8 = if (postscript_name) |value| blk: {
            const dest = storage[offset..][0..value.len];
            @memcpy(dest, value);
            offset += value.len;
            break :blk dest;
        } else null;

        return .{
            .allocator = allocator,
            .path = storage[0..path.len],
            .family = owned_family,
            .postscript_name = owned_postscript,
            .face_index = face_index,
            .provider_index = provider_index,
            .named_instance = named_instance,
            .provider = provider,
            .storage = storage,
        };
    }

    pub fn deinit(self: *Candidate) void {
        if (self.storage) |storage| {
            self.allocator.free(storage);
        } else {
            self.allocator.free(self.path);
            if (self.family) |family| self.allocator.free(family);
            if (self.postscript_name) |name| self.allocator.free(name);
        }
        self.* = undefined;
    }

    pub fn setMetadata(
        self: *Candidate,
        weight: u16,
        stretch: u16,
        style: Style,
        monospaced: bool,
    ) void {
        self.weight = weight;
        self.stretch = stretch;
        self.style = style;
        self.monospaced = monospaced;
    }

    pub fn clone(self: Candidate, allocator: std.mem.Allocator) !Candidate {
        var out = try Candidate.init(
            allocator,
            self.path,
            self.family,
            self.postscript_name,
            self.face_index,
            self.provider_index,
            self.named_instance,
            self.provider,
        );
        out.setMetadata(self.weight, self.stretch, self.style, self.monospaced);
        return out;
    }
};

pub const SharedResolution = struct {
    allocator: std.mem.Allocator,
    candidates: []Candidate,
    provider: Provider,
    refs: std.atomic.Value(usize),
};

pub const Resolution = struct {
    allocator: std.mem.Allocator,
    candidates: []Candidate,
    provider: Provider,
    /// Non-null when this resolution is reference-counted by the provider
    /// query cache. `deinit` releases one reference instead of freeing
    /// immediately.
    shared: ?*SharedResolution = null,

    pub fn deinit(self: *Resolution) void {
        if (self.shared) |shared| {
            if (shared.refs.fetchSub(1, .acq_rel) == 1) {
                for (shared.candidates) |*candidate| candidate.deinit();
                shared.allocator.free(shared.candidates);
                shared.allocator.destroy(shared);
            }
        } else {
            for (self.candidates) |*candidate| candidate.deinit();
            self.allocator.free(self.candidates);
        }
        self.* = undefined;
    }

    /// Add one reference. Only meaningful for resolutions returned by a
    /// provider cache (`shared != null`).
    pub fn retain(self: Resolution) Resolution {
        if (self.shared) |shared| _ = shared.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Convert an owned resolution into a reference-counted one. This consumes
    /// the caller's reference: after success the original value must not be
    /// deinitialized. If it is already shared, the same reference is returned
    /// and ownership is transferred to the caller. On failure the original
    /// resolution remains owned by the caller.
    pub fn intoShared(self: Resolution) !Resolution {
        if (self.shared != null) return self;
        const shared = try self.allocator.create(SharedResolution);
        shared.* = .{
            .allocator = self.allocator,
            .candidates = self.candidates,
            .provider = self.provider,
            .refs = std.atomic.Value(usize).init(1),
        };
        return .{
            .allocator = self.allocator,
            .candidates = self.candidates,
            .provider = self.provider,
            .shared = shared,
        };
    }

    pub fn clone(self: Resolution, allocator: std.mem.Allocator) !Resolution {
        if (self.shared != null) return self.retain();
        const candidates = try allocator.alloc(Candidate, self.candidates.len);
        var initialized: usize = 0;
        errdefer {
            for (candidates[0..initialized]) |*candidate| candidate.deinit();
            allocator.free(candidates);
        }
        for (self.candidates, candidates) |candidate, *out| {
            out.* = try candidate.clone(allocator);
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .candidates = candidates,
            .provider = self.provider,
        };
    }
};

pub const DiscoveryStats = struct {
    generation: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_entries: usize = 0,
};

/// Spacing behavior required of a fallback font. A host can use this to pick a
/// proportional or monospace replacement when a cluster exhausts fallback.
pub const FallbackFontClass = enum {
    proportional,
    monospace,
};

/// A cluster that the shaping/fallback layer could not cover. The host may
/// resolve and install a system face, then retry shaping.
pub const MissingGlyph = struct {
    cluster: []const u8,
    language: ?[]const u8 = null,
    script: ?[]const u8 = null,
    /// Advisory spacing class of the font that produced the missing glyph.
    font_class: ?FallbackFontClass = null,
    /// Discovery generation at report time. Hosts can drop reports produced
    /// before the latest font installation.
    generation: u64 = 0,
};

pub const MissingGlyphSink = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, missing: MissingGlyph) void,
};

/// Free a list returned by `Service.allFamilyNames` / `Discovery.allFamilyNames`.
pub fn freeFamilyNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

/// Runtime-injectable discovery contract. Implementations return owned
/// resolutions; callers deinitialize them with `Resolution.deinit`.
pub const Service = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            query: Query,
        ) anyerror!Resolution,
        /// Returns owned family-name strings plus the owning slice. Callers
        /// release them with `freeFamilyNames`.
        all_family_names: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]const []const u8,
        prewarm: *const fn (context: *anyopaque, queries: []const Query) void,
        set_missing_glyph_sink: *const fn (
            context: *anyopaque,
            sink: ?*MissingGlyphSink,
        ) void,
        generation: *const fn (context: *anyopaque) u64,
    };

    pub fn resolve(
        self: Service,
        allocator: std.mem.Allocator,
        query: Query,
    ) !Resolution {
        return try self.vtable.resolve(self.context, allocator, query);
    }

    pub fn allFamilyNames(
        self: Service,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        return try self.vtable.all_family_names(self.context, allocator);
    }

    pub fn prewarm(self: Service, queries: []const Query) void {
        self.vtable.prewarm(self.context, queries);
    }

    pub fn setMissingGlyphSink(
        self: Service,
        sink: ?*MissingGlyphSink,
    ) void {
        self.vtable.set_missing_glyph_sink(self.context, sink);
    }

    pub fn generation(self: Service) u64 {
        return self.vtable.generation(self.context);
    }
};

test "candidate uses one allocation and preserves metadata on clone" {
    var candidate = try Candidate.init(
        std.testing.allocator,
        "/fonts/example.ttf",
        "Example Sans",
        "ExampleSans-Regular",
        2,
        0x0002_0002,
        2,
        .fontconfig,
    );
    defer candidate.deinit();
    candidate.setMetadata(700, 125, .italic, true);
    var clone = try candidate.clone(std.testing.allocator);
    defer clone.deinit();
    try std.testing.expectEqualStrings("Example Sans", clone.family.?);
    try std.testing.expectEqualStrings("ExampleSans-Regular", clone.postscript_name.?);
    try std.testing.expectEqual(@as(u16, 700), clone.weight);
    try std.testing.expectEqual(@as(u16, 125), clone.stretch);
    try std.testing.expectEqual(Style.italic, clone.style);
    try std.testing.expect(clone.monospaced);
}

test "freeFamilyNames releases owned names" {
    const allocator = std.testing.allocator;
    const names = try allocator.alloc([]const u8, 2);
    names[0] = try allocator.dupe(u8, "One");
    names[1] = try allocator.dupe(u8, "Two");
    freeFamilyNames(allocator, names);
}

test "shared resolutions release only after the last reference" {
    const allocator = std.testing.allocator;
    const candidates = try allocator.alloc(Candidate, 1);
    candidates[0] = try Candidate.init(
        allocator,
        "/fonts/shared.ttf",
        "Shared Sans",
        "SharedSans-Regular",
        0,
        0,
        0,
        .fontconfig,
    );
    var owned = Resolution{
        .allocator = allocator,
        .candidates = candidates,
        .provider = .fontconfig,
    };
    var first = try owned.intoShared();
    var second = first.retain();
    first.deinit();
    try std.testing.expectEqualStrings("Shared Sans", second.candidates[0].family.?);
    second.deinit();
}
