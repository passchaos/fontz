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
    fontconfig,
    core_text,
    direct_write,
};

pub const Style = enum {
    normal,
    italic,
    oblique,
};

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
    /// Exact collection face when the native provider exposes one. CoreText
    /// identifies a face by URL + PostScript name instead; FontManager resolves
    /// that identifier through Cangjie's metadata parser before installation.
    face_index: ?u32 = null,
    provider_index: u32 = 0,
    named_instance: u16 = 0,
    provider: Provider,

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
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_family = if (family) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_family) |value| allocator.free(value);
        const owned_postscript = if (postscript_name) |value|
            try allocator.dupe(u8, value)
        else
            null;
        return .{
            .allocator = allocator,
            .path = owned_path,
            .family = owned_family,
            .postscript_name = owned_postscript,
            .face_index = face_index,
            .provider_index = provider_index,
            .named_instance = named_instance,
            .provider = provider,
        };
    }

    pub fn deinit(self: *Candidate) void {
        self.allocator.free(self.path);
        if (self.family) |family| self.allocator.free(family);
        if (self.postscript_name) |name| self.allocator.free(name);
        self.* = undefined;
    }

    pub fn clone(self: Candidate, allocator: std.mem.Allocator) !Candidate {
        return try Candidate.init(
            allocator,
            self.path,
            self.family,
            self.postscript_name,
            self.face_index,
            self.provider_index,
            self.named_instance,
            self.provider,
        );
    }
};

pub const Resolution = struct {
    allocator: std.mem.Allocator,
    candidates: []Candidate,
    provider: Provider,

    pub fn deinit(self: *Resolution) void {
        for (self.candidates) |*candidate| candidate.deinit();
        self.allocator.free(self.candidates);
        self.* = undefined;
    }

    pub fn clone(self: Resolution, allocator: std.mem.Allocator) !Resolution {
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

/// A cluster that the shaping/fallback layer could not cover. The host may
/// resolve and install a system face, then retry shaping.
pub const MissingGlyph = struct {
    cluster: []const u8,
    language: ?[]const u8 = null,
    script: ?[]const u8 = null,
};

pub const MissingGlyphSink = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, missing: MissingGlyph) void,
};

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
