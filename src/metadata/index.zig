//! Bounded system-font metadata discovery for concrete `font-family` names.
//!
//! The index reads only sfnt headers plus `name`/`OS/2`/`post` tables; it never
//! rasterizes and never installs a face until a document selects it. Discovery
//! is opt-in through `ResourcePolicy.allow_system_fonts` because ambient
//! filesystem access is a caller decision. The process-wide index is bounded by
//! file, face, per-table and total metadata budgets.
//!
//! The index keeps every localized family name plus PostScript/full names and
//! face attributes so callers can resolve the same face identity that Cangjie
//! will parse later. Face selection follows the CSS Fonts Level 3 order:
//! `font-stretch` first, then `font-style`, then `font-weight`.

const std = @import("std");
const builtin = @import("builtin");
const family_mod = @import("../family.zig");
const types = @import("../types.zig");
const parse = @import("parse.zig");
const env = @import("../env.zig");
const test_font = @import("test_font.zig");
const metadata_cache = @import("index_cache.zig");

pub const LocalizedName = parse.LocalizedName;

pub const Face = struct {
    /// Absolute path as `root/entry.path` under the scanned font root.
    path: []const u8,
    /// Zero-based face inside a TrueType/OpenType collection, otherwise 0.
    face_index: u32 = 0,
    /// Zero for the face's default instance; otherwise `N` selects the
    /// zero-based `fvar` named instance `N - 1`.
    named_instance: u16 = 0,
    /// Preferred English/typographic family name.
    family: []const u8,
    /// Every localized family name found in the `name` table. `family` is
    /// always present in this list.
    families: []const LocalizedName = &.{},
    subfamily: []const u8,
    full_name: []const u8 = "",
    postscript_name: []const u8 = "",
    weight: u16 = 400,
    /// CSS font-stretch percentage (100 is normal).
    stretch: u16 = 100,
    /// OpenType `usWidthClass` (1..9, 5 is normal).
    width_class: u16 = 5,
    italic: bool = false,
    style: types.Style = .normal,
    monospaced: bool = false,
    /// `opsz` axis range in design units, when the face declares one.
    opsz_min: ?f32 = null,
    opsz_default: ?f32 = null,
    opsz_max: ?f32 = null,
};

pub const GenericMapping = struct {
    generic: family_mod.GenericFamily,
    families: []const []const u8,
};

pub const Options = struct {
    /// Override the platform roots (tests and embedders).
    ///
    /// Options are fixed after the first successful index build. Call `reset`
    /// before switching roots or budgets.
    roots: ?[]const []const u8 = null,
    max_files: usize = 4096,
    max_faces: usize = 4096,
    /// Per-file cap for the `name` table. Larger tables are skipped.
    max_name_table_bytes: usize = 128 * 1024,
    /// Total metadata bytes read across the scan.
    max_total_metadata_bytes: usize = 64 * 1024 * 1024,
    /// Optional mapping from CSS generic families to concrete family stacks.
    generic_mappings: []const GenericMapping = &.{},
    /// Override the persistent metadata cache path (tests and embedders).
    cache_path: ?[]const u8 = null,
    /// Disable the persistent metadata cache for this build.
    enable_cache: bool = true,
};

const Index = struct {
    arena: std.heap.ArenaAllocator,
    faces: []const Face,
    /// Normalized family name -> face indexes.
    family_index: std.StringHashMapUnmanaged(std.ArrayList(u32)),
    /// Lower-cased PostScript name -> face index.
    postscript_index: std.StringHashMapUnmanaged(u32),
    /// Sorted, unique primary family names.
    family_names: []const []const u8,
};

var index_mutex: std.Io.Mutex = .init;
var index_cache: ?Index = null;
/// Whether the most recent successful index build came from the disk cache.
/// Diagnostics/tests only; not a synchronization primitive.
var last_index_from_cache: bool = false;
/// Bumped whenever the process-wide index is dropped; query caches include it
/// so an external font-change reset invalidates cached resolutions.
var index_generation: u64 = 1;

/// Reset the process-wide index. Tests only; the production cache lives for the
/// process lifetime. Callers must not hold `Face` pointers across this call.
pub fn resetForTesting(io: std.Io) void {
    reset(io);
}

/// Builds the process-wide metadata index without resolving a query. Hosts can
/// call this from a background worker at startup so the first text layout does
/// not pay the cold scan. Returns false when the index could not be built.
pub fn prewarm(io: std.Io, options: Options) bool {
    return ensureIndex(io, options) != null;
}

/// Whether the most recent build reused the persistent metadata cache.
pub fn lastBuildUsedCache() bool {
    return last_index_from_cache;
}

/// Explicitly drop the process-wide index. Callers must not hold `Face`
/// pointers across this call. `Options` are fixed after the first successful
/// index build; use this to switch roots/budgets in tests or embedders.
pub fn reset(io: std.Io) void {
    index_mutex.lockUncancelable(io);
    defer index_mutex.unlock(io);
    if (index_cache) |*cached| cached.arena.deinit();
    index_cache = null;
    index_generation +%= 1;
    if (index_generation == 0) index_generation = 1;
}

/// Current process-wide index generation.
pub fn generation() u64 {
    return index_generation;
}

/// Find the best installed face for an authored CSS family list.
///
/// `stretch` is an OpenType `usWidthClass` (1..9, 5 is normal) for compatibility
/// with callers that already convert CSS percentages. New code should prefer
/// `findFace` and pass CSS `stretch`.
///
/// Items are considered in order; generic keywords are resolved through
/// `Options.generic_mappings`. The best face minimizes CSS stretch, style and
/// weight distance in that order. Returns a pointer into the process-wide
/// index.
pub fn findFamily(
    io: std.Io,
    families: []const u8,
    weight: u16,
    italic: bool,
    stretch: u16,
    options: Options,
) ?*const Face {
    return findFace(io, .{
        .family = families,
        .weight = weight,
        .stretch = family_mod.widthClassToStretch(stretch),
        .style = if (italic) .italic else .normal,
    }, options);
}

/// Find the best installed face for a full descriptor query.
///
/// `query.required_codepoint` is accepted for API symmetry but is not verified
/// here: this index intentionally does not parse `cmap`. Native providers or
/// Cangjie remain responsible for coverage proof.
pub fn findFace(io: std.Io, query: types.Query, options: Options) ?*const Face {
    const index = ensureIndex(io, options) orelse return null;
    if (query.postscript_name) |requested| {
        if (findByPostScriptIndex(index, requested)) |face| return face;
    }
    var iterator = family_mod.FamilyIterator.init(query.family);
    while (iterator.next()) |raw_family| {
        const family = std.mem.trim(u8, raw_family, " \t\r\n");
        if (family.len == 0) continue;
        if (family_mod.genericFamily(family)) |generic| {
            for (options.generic_mappings) |mapping| {
                if (mapping.generic != generic) continue;
                for (mapping.families) |mapped| {
                    if (findConcrete(index, mapped, query)) |face| return face;
                }
            }
            continue;
        }
        if (findConcrete(index, family, query)) |face| return face;
    }
    return null;
}

/// Resolve an exact PostScript name to a face.
pub fn findByPostScript(
    io: std.Io,
    postscript_name: []const u8,
    options: Options,
) ?*const Face {
    const index = ensureIndex(io, options) orelse return null;
    return findByPostScriptIndex(index, postscript_name);
}

/// Sorted, unique primary family names. Localized names still participate in
/// `findFace` matching. Callers release the result with
/// `types.freeFamilyNames`.
pub fn familyNames(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) ![]const []const u8 {
    const index = ensureIndex(io, options) orelse return try allocator.alloc([]const u8, 0);
    const names = try allocator.alloc([]const u8, index.family_names.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (index.family_names, names) |name, *out| {
        out.* = try allocator.dupe(u8, name);
        initialized += 1;
    }
    return names;
}

pub const allFamilyNames = familyNames;

/// Resolve the collection face index for a PostScript name by reading only the
/// font's metadata. Useful when a caller only has a URL + PostScript identity
/// and needs a TTC index.
pub fn findFaceIndexByPostScript(
    io: std.Io,
    path: []const u8,
    postscript_name: []const u8,
) !?u32 {
    if (postscript_name.len == 0) return null;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var persist = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer persist.deinit();
    const collection = (try parse.readFileMetadata(
        io,
        file,
        scratch.allocator(),
        persist.allocator(),
        128 * 1024,
        64 * 1024 * 1024,
    )) orelse return null;
    for (collection.faces[0..collection.count], 0..) |meta, face_index| {
        if (std.ascii.eqlIgnoreCase(meta.postscript_name, postscript_name)) {
            return @intCast(face_index);
        }
    }
    return null;
}

fn findByPostScriptIndex(index: *const Index, requested: []const u8) ?*const Face {
    var buffer: [256]u8 = undefined;
    if (normalizePostScriptKeyInto(&buffer, requested)) |key| {
        if (index.postscript_index.get(key)) |face_index| {
            if (face_index < index.faces.len) return &index.faces[face_index];
        }
        return null;
    }
    for (index.faces) |*face| {
        if (std.ascii.eqlIgnoreCase(face.postscript_name, requested)) return face;
    }
    return null;
}

fn findConcrete(index: *const Index, family: []const u8, query: types.Query) ?*const Face {
    var buffer: [512]u8 = undefined;
    if (normalizeFamilyKeyInto(&buffer, family)) |key| {
        if (key.len == 0) return null;
        if (index.family_index.get(key)) |candidates| {
            return selectBestFace(index.faces, candidates.items, query);
        }
        return null;
    }
    // Extremely long family name: fall back to a linear scan.
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(std.heap.page_allocator);
    for (index.faces, 0..) |*face, face_index| {
        if (faceMatchesFamily(face, family)) {
            indices.append(std.heap.page_allocator, @intCast(face_index)) catch return null;
        }
    }
    return selectBestFace(index.faces, indices.items, query);
}

fn isHiddenFamilyName(name: []const u8) bool {
    return name.len != 0 and name[0] == '.';
}

fn faceMatchesFamily(face: *const Face, family: []const u8) bool {
    if (family_mod.familyNamesEqual(face.family, family)) return true;
    for (face.families) |localized| {
        if (family_mod.familyNamesEqual(localized.name, family)) return true;
    }
    return false;
}

/// CSS Fonts Level 3 face selection over a candidate index list.
fn selectBestFace(
    faces: []const Face,
    indices: []const u32,
    query: types.Query,
) ?*const Face {
    if (indices.len == 0) return null;
    const stretch = matchingStretch(faces, indices, query.stretch) orelse return null;
    const style = matchingStyle(faces, indices, stretch, query.style) orelse return null;
    const weight = matchingWeight(faces, indices, stretch, style, query.weight) orelse return null;
    var best: ?*const Face = null;
    var best_score: f32 = std.math.inf(f32);
    for (indices) |index| {
        if (index >= faces.len) continue;
        const face = &faces[index];
        if (face.stretch != stretch or face.style != style or face.weight != weight) continue;
        if (query.opsz) |requested| {
            const score = opszScore(face, requested);
            if (score < best_score) {
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
fn opszScore(face: *const Face, requested: f32) f32 {
    const min = face.opsz_min orelse return std.math.inf(f32);
    const max = face.opsz_max orelse min;
    if (requested < min) return min - requested;
    if (requested > max) return requested - max;
    const default = face.opsz_default orelse min;
    return @abs(requested - default) * 1e-6;
}

fn matchingStretch(faces: []const Face, indices: []const u32, requested: u16) ?u16 {
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

fn ensureIndex(io: std.Io, options: Options) ?*const Index {
    index_mutex.lockUncancelable(io);
    if (index_cache != null) {
        const cached = &index_cache.?;
        index_mutex.unlock(io);
        return cached;
    }
    index_mutex.unlock(io);

    var built = buildIndex(io, options) catch return null;

    index_mutex.lockUncancelable(io);
    if (index_cache == null) {
        index_cache = built;
    } else {
        built.arena.deinit();
    }
    const cached = if (index_cache) |*value| value else null;
    index_mutex.unlock(io);
    return cached;
}

fn buildIndex(io: std.Io, options: Options) !Index {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const roots = try collectRoots(io, allocator, options);
    const stamps = try collectFileStamps(io, allocator, roots, options);
    const limits_hash = optionsLimitsHash(options);
    const cache_path = resolveCachePath(allocator, options);
    last_index_from_cache = false;
    if (cache_path) |path| {
        if (try metadata_cache.load(
            Face,
            io,
            allocator,
            path,
            roots,
            stamps,
            limits_hash,
        )) |faces| {
            last_index_from_cache = true;
            return try finishIndex(&arena, faces);
        }
    }

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var faces: std.ArrayList(Face) = .empty;
    var metadata_bytes: usize = 0;
    for (stamps) |stamp| {
        if (faces.items.len >= options.max_faces or
            metadata_bytes >= options.max_total_metadata_bytes)
        {
            break;
        }
        _ = scratch.reset(.retain_capacity);
        var file = std.Io.Dir.openFileAbsolute(io, stamp.path, .{}) catch continue;
        defer file.close(io);
        const collection = (parse.readFileMetadata(
            io,
            file,
            scratch.allocator(),
            allocator,
            options.max_name_table_bytes,
            options.max_total_metadata_bytes - metadata_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        }) orelse continue;
        metadata_bytes += collection.bytes_read;
        for (collection.faces[0..collection.count], 0..) |meta, face_index| {
            if (faces.items.len >= options.max_faces) break;
            try faces.append(allocator, .{
                .path = stamp.path,
                .face_index = @intCast(face_index),
                .family = meta.family,
                .families = meta.families,
                .subfamily = meta.subfamily,
                .full_name = meta.full_name,
                .postscript_name = meta.postscript_name,
                .weight = meta.weight,
                .stretch = meta.stretch,
                .width_class = meta.width_class,
                .italic = meta.italic,
                .style = meta.style,
                .monospaced = meta.monospaced,
                .opsz_min = meta.opsz_min,
                .opsz_default = meta.opsz_default,
                .opsz_max = meta.opsz_max,
            });
            for (meta.instances) |instance| {
                if (faces.items.len >= options.max_faces) break;
                try faces.append(allocator, .{
                    .path = stamp.path,
                    .face_index = @intCast(face_index),
                    .named_instance = @intCast(@as(usize, instance.index) + 1),
                    .family = meta.family,
                    .families = meta.families,
                    .subfamily = instance.subfamily,
                    .full_name = meta.full_name,
                    .postscript_name = instance.postscript_name,
                    .weight = instance.weight,
                    .stretch = instance.stretch,
                    .width_class = meta.width_class,
                    .italic = instance.style != .normal,
                    .style = instance.style,
                    .monospaced = meta.monospaced,
                    .opsz_min = meta.opsz_min,
                    .opsz_default = meta.opsz_default,
                    .opsz_max = meta.opsz_max,
                });
            }
        }
    }
    const owned_faces = try faces.toOwnedSlice(allocator);
    if (cache_path) |path| {
        metadata_cache.store(
            Face,
            io,
            scratch.allocator(),
            path,
            roots,
            stamps,
            owned_faces,
            limits_hash,
        );
    }
    return try finishIndex(&arena, owned_faces);
}

fn finishIndex(arena: *std.heap.ArenaAllocator, owned_faces: []const Face) !Index {
    const allocator = arena.allocator();
    var family_index: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    var postscript_index: std.StringHashMapUnmanaged(u32) = .empty;
    var family_name_set: std.StringHashMapUnmanaged(void) = .empty;
    for (owned_faces, 0..) |face, face_index| {
        for (face.families) |localized| {
            // Dot-prefixed families are CoreText-style hidden aliases. They
            // remain addressable by PostScript name but must not participate
            // in ordinary family matching or family listing.
            if (isHiddenFamilyName(localized.name)) continue;
            const key = try normalizeFamilyKey(allocator, localized.name);
            const gop = try family_index.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, @intCast(face_index));
        }
        if (!isHiddenFamilyName(face.family)) {
            try family_name_set.put(allocator, face.family, {});
        }
        if (face.postscript_name.len != 0) {
            const key = try normalizePostScriptKey(allocator, face.postscript_name);
            const gop = try postscript_index.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(face_index);
        }
    }

    var names: std.ArrayList([]const u8) = .empty;
    var name_iterator = family_name_set.keyIterator();
    while (name_iterator.next()) |key| try names.append(allocator, key.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    const family_names = try names.toOwnedSlice(allocator);

    return .{
        .arena = arena.*,
        .faces = owned_faces,
        .family_index = family_index,
        .postscript_index = postscript_index,
        .family_names = family_names,
    };
}

fn collectFileStamps(
    io: std.Io,
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    options: Options,
) ![]const metadata_cache.FileStamp {
    var stamps: std.ArrayList(metadata_cache.FileStamp) = .empty;
    for (roots) |root| {
        if (stamps.items.len >= options.max_files) break;
        var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch continue;
        defer root_dir.close(io);
        var walker = root_dir.walk(allocator) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!isFontFile(entry.basename)) continue;
            if (stamps.items.len >= options.max_files) break;
            var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
            defer file.close(io);
            const stat = file.stat(io) catch continue;
            const path = try std.fs.path.join(allocator, &.{ root, entry.path });
            try stamps.append(allocator, .{
                .path = path,
                .mtime_ns = stat.mtime.nanoseconds,
                .size = stat.size,
            });
        }
    }
    std.mem.sort(metadata_cache.FileStamp, stamps.items, {}, lessThanStamp);
    return try stamps.toOwnedSlice(allocator);
}

fn lessThanStamp(_: void, a: metadata_cache.FileStamp, b: metadata_cache.FileStamp) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn optionsLimitsHash(options: Options) u64 {
    var hash = std.hash.Wyhash.init(metadata_cache.version);
    hash.update(std.mem.asBytes(&options.max_files));
    hash.update(std.mem.asBytes(&options.max_faces));
    hash.update(std.mem.asBytes(&options.max_name_table_bytes));
    hash.update(std.mem.asBytes(&options.max_total_metadata_bytes));
    return hash.final();
}

fn resolveCachePath(allocator: std.mem.Allocator, options: Options) ?[]const u8 {
    if (options.cache_path) |path| return path;
    if (!options.enable_cache) return null;
    // Explicit roots are tests/embedders; do not write their synthetic catalog
    // into the user's real cache directory.
    if (options.roots != null) return null;
    switch (builtin.os.tag) {
        .windows => {
            const local = env.get(allocator, "LOCALAPPDATA") orelse return null;
            defer allocator.free(local);
            const dir = std.fs.path.join(allocator, &.{ local, "fontz" }) catch return null;
            defer allocator.free(dir);
            return std.fs.path.join(allocator, &.{ dir, "metadata-v1.bin" }) catch null;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const home = env.get(allocator, "HOME") orelse return null;
            defer allocator.free(home);
            const dir = std.fs.path.join(allocator, &.{ home, "Library", "Caches", "fontz" }) catch return null;
            defer allocator.free(dir);
            return std.fs.path.join(allocator, &.{ dir, "metadata-v1.bin" }) catch null;
        },
        else => {
            const cache_home = env.get(allocator, "XDG_CACHE_HOME");
            defer if (cache_home) |value| allocator.free(value);
            const base = cache_home orelse blk: {
                const home = env.get(allocator, "HOME") orelse return null;
                const cache = std.fs.path.join(allocator, &.{ home, ".cache" }) catch {
                    allocator.free(home);
                    return null;
                };
                allocator.free(home);
                break :blk cache;
            };
            defer allocator.free(base);
            const dir = std.fs.path.join(allocator, &.{ base, "fontz" }) catch return null;
            defer allocator.free(dir);
            return std.fs.path.join(allocator, &.{ dir, "metadata-v1.bin" }) catch null;
        },
    }
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn normalizeFamilyKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name) |byte| {
        if (byte < 0x80 and !std.ascii.isAlphanumeric(byte)) continue;
        try out.append(allocator, if (byte < 0x80) std.ascii.toLower(byte) else byte);
    }
    return try out.toOwnedSlice(allocator);
}

fn normalizeFamilyKeyInto(buffer: []u8, name: []const u8) ?[]const u8 {
    var len: usize = 0;
    for (name) |byte| {
        if (byte < 0x80 and !std.ascii.isAlphanumeric(byte)) continue;
        if (len == buffer.len) return null;
        buffer[len] = if (byte < 0x80) std.ascii.toLower(byte) else byte;
        len += 1;
    }
    return buffer[0..len];
}

fn normalizePostScriptKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, out) |byte, *dest| dest.* = std.ascii.toLower(byte);
    return out;
}

fn normalizePostScriptKeyInto(buffer: []u8, name: []const u8) ?[]const u8 {
    if (name.len > buffer.len) return null;
    for (name, buffer[0..name.len]) |byte, *dest| dest.* = std.ascii.toLower(byte);
    return buffer[0..name.len];
}

pub const familyNamesEqual = family_mod.familyNamesEqual;

fn isFontFile(basename: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(basename, ".ttf") or
        std.ascii.endsWithIgnoreCase(basename, ".otf") or
        std.ascii.endsWithIgnoreCase(basename, ".ttc") or
        std.ascii.endsWithIgnoreCase(basename, ".otc");
}

fn platformRoots() []const []const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => &.{
            "/usr/share/fonts",
            "/usr/local/share/fonts",
        },
        .macos, .ios, .tvos, .watchos, .visionos => &.{
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
            "/Library/Fonts",
            // System-reserved faces that CoreText exposes as regular families.
            // PingFang lives here on current macOS releases, so skipping this
            // root makes `PingFang SC` unresolvable even though the family is
            // visible to native text stacks.
            "/System/Library/PrivateFrameworks/FontServices.framework/Versions/Current/Resources/Reserved",
        },
        .windows => &.{},
        else => &.{},
    };
}

fn collectRoots(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) ![]const []const u8 {
    if (options.roots) |roots| return roots;
    var roots: std.ArrayList([]const u8) = .empty;
    for (platformRoots()) |root| try roots.append(allocator, root);
    switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => {
            if (env.get(allocator, "HOME")) |home| {
                defer allocator.free(home);
                try appendJoined(allocator, &roots, &.{ home, ".local/share/fonts" });
                try appendJoined(allocator, &roots, &.{ home, ".fonts" });
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            if (env.get(allocator, "HOME")) |home| {
                defer allocator.free(home);
                try appendJoined(allocator, &roots, &.{ home, "Library/Fonts" });
            }
            try appendJoined(allocator, &roots, &.{"/Network/Library/Fonts"});
            try appendAssetsV2(io, allocator, &roots);
        },
        .windows => {
            if (env.get(allocator, "WINDIR")) |windir| {
                defer allocator.free(windir);
                try appendJoined(allocator, &roots, &.{ windir, "Fonts" });
            } else {
                try roots.append(allocator, "C:\\Windows\\Fonts");
            }
            if (env.get(allocator, "LOCALAPPDATA")) |local| {
                defer allocator.free(local);
                try appendJoined(allocator, &roots, &.{ local, "Microsoft", "Windows", "Fonts" });
            }
            if (env.get(allocator, "APPDATA")) |appdata| {
                defer allocator.free(appdata);
                try appendJoined(allocator, &roots, &.{ appdata, "Microsoft", "Windows", "Fonts" });
            } else if (env.get(allocator, "USERPROFILE")) |profile| {
                defer allocator.free(profile);
                try appendJoined(allocator, &roots, &.{ profile, "AppData", "Roaming", "Microsoft", "Windows", "Fonts" });
            }
        },
        else => {},
    }
    return try roots.toOwnedSlice(allocator);
}

fn appendJoined(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList([]const u8),
    parts: []const []const u8,
) !void {
    const joined = try std.fs.path.join(allocator, parts);
    errdefer allocator.free(joined);
    try roots.append(allocator, joined);
}

fn appendAssetsV2(
    io: std.Io,
    allocator: std.mem.Allocator,
    roots: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, "/System/Library/AssetsV2", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "com_apple_MobileAsset_Font")) continue;
        try appendJoined(allocator, roots, &.{ "/System/Library/AssetsV2", entry.name });
    }
}

/// Platform font roots including user font directories. Callers own the
/// returned slice in `allocator`.
pub fn defaultRoots(io: std.Io, allocator: std.mem.Allocator) ![]const []const u8 {
    return collectRoots(io, allocator, .{});
}

test "family comparison ignores separators and case" {
    try std.testing.expect(familyNamesEqual("Noto Sans", "noto sans"));
    try std.testing.expect(familyNamesEqual("M PLUS 1p", "Mplus 1p"));
    try std.testing.expect(!familyNamesEqual("Noto Sans", "Noto Serif"));
    try std.testing.expect(!familyNamesEqual("宋体", "黑体"));
}

test "index resolves a family from configured roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Test Sans",
        .subfamily = "Bold Italic",
        .weight = 700,
        .italic = true,
        .postscript_name = "TestSans-BoldItalic",
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "TestSans-BoldItalic.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findFamily(
        io,
        "\"Test Sans\", sans-serif",
        700,
        true,
        5,
        .{ .roots = &roots },
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Test Sans", face.family);
    try std.testing.expectEqual(@as(u16, 700), face.weight);
    try std.testing.expect(face.italic);
    try std.testing.expectEqualStrings("TestSans-BoldItalic", face.postscript_name);
}

test "index matches fvar named instances by weight" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Variable Sans",
        .postscript_name = "VariableSans-Regular",
        .instances = &.{
            .{ .subfamily = "Light", .postscript_name = "VariableSans-Light", .weight = 300 },
            .{ .subfamily = "Bold", .postscript_name = "VariableSans-Bold", .weight = 700 },
        },
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "VariableSans.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);

    const regular = findFamily(io, "Variable Sans", 400, false, 5, .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("VariableSans-Regular", regular.postscript_name);
    try std.testing.expectEqual(@as(u16, 0), regular.named_instance);

    const light = findFamily(io, "Variable Sans", 300, false, 5, .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("VariableSans-Light", light.postscript_name);
    try std.testing.expectEqual(@as(u16, 1), light.named_instance);
    try std.testing.expectEqual(@as(u16, 300), light.weight);

    const bold = findFamily(io, "Variable Sans", 700, false, 5, .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("VariableSans-Bold", bold.postscript_name);
    try std.testing.expectEqual(@as(u16, 2), bold.named_instance);
    try std.testing.expectEqual(@as(u16, 700), bold.weight);
}

test "metadata cache round-trips and invalidates on file changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Cache Sans",
        .postscript_name = "CacheSans-Regular",
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "CacheSans.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    const cache_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "cache.bin" });
    defer std.testing.allocator.free(cache_path);
    const options = Options{ .roots = &roots, .cache_path = cache_path };

    resetForTesting(io);
    defer resetForTesting(io);
    _ = findFamily(io, "Cache Sans", 400, false, 5, options) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!lastBuildUsedCache());

    resetForTesting(io);
    _ = findFamily(io, "Cache Sans", 400, false, 5, options) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(lastBuildUsedCache());

    // A changed font file changes the stamp (and file size), so the next build
    // must ignore the stale cache.
    const changed = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Cache Sans Extended",
        .postscript_name = "CacheSansExtended-Regular",
    });
    defer std.testing.allocator.free(changed);
    try tmp.dir.writeFile(io, .{ .sub_path = "CacheSans.ttf", .data = changed });
    resetForTesting(io);
    _ = findFamily(io, "Cache Sans Extended", 400, false, 5, options) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!lastBuildUsedCache());
}

test "index keeps more than 128 fvar instances" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var instances: [130]test_font.TestInstance = undefined;
    var subfamily_buf: [130][8]u8 = undefined;
    var postscript_buf: [130][16]u8 = undefined;
    for (&instances, 0..) |*instance, index| {
        const weight: f32 = @floatFromInt(100 + index);
        instance.* = .{
            .subfamily = try std.fmt.bufPrint(&subfamily_buf[index], "W{d}", .{100 + index}),
            .postscript_name = try std.fmt.bufPrint(&postscript_buf[index], "Many-{d}", .{100 + index}),
            .weight = weight,
        };
    }
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Many Instances",
        .postscript_name = "Many-Regular",
        .instances = &instances,
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "Many.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);

    const face = findFamily(io, "Many Instances", 229, false, 5, .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 130), face.named_instance);
    try std.testing.expectEqualStrings("Many-229", face.postscript_name);
}

test "CSS matching prefers style over weight distance" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const black = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Probe Sans",
        .subfamily = "Black",
        .weight = 900,
        .postscript_name = "ProbeSans-Black",
    });
    defer std.testing.allocator.free(black);
    const italic = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Probe Sans",
        .subfamily = "Italic",
        .weight = 400,
        .italic = true,
        .postscript_name = "ProbeSans-Italic",
    });
    defer std.testing.allocator.free(italic);
    try tmp.dir.writeFile(io, .{ .sub_path = "ProbeSans-Black.ttf", .data = black });
    try tmp.dir.writeFile(io, .{ .sub_path = "ProbeSans-Italic.ttf", .data = italic });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findFace(io, .{
        .family = "Probe Sans",
        .weight = 400,
        .style = .normal,
    }, .{ .roots = &roots }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!face.italic);
    try std.testing.expectEqualStrings("Black", face.subfamily);
}

test "localized family names resolve" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Localized Sans",
        .localized_family = .{ .name = "本地化字体", .language = 0x0804 },
        .postscript_name = "LocalizedSans-Regular",
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "LocalizedSans.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findFace(io, .{ .family = "本地化字体" }, .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Localized Sans", face.family);
    const names = try familyNames(io, std.testing.allocator, .{ .roots = &roots });
    defer types.freeFamilyNames(std.testing.allocator, names);
    var saw_primary = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "Localized Sans")) saw_primary = true;
    }
    try std.testing.expect(saw_primary);
}

test "PostScript lookup and face index helper" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Postscript Sans",
        .postscript_name = "PostscriptSans-Regular",
        .monospaced = true,
    });
    defer std.testing.allocator.free(font);
    try tmp.dir.writeFile(io, .{ .sub_path = "PostscriptSans.ttf", .data = font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findByPostScript(io, "postscriptsans-regular", .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(face.monospaced);
    const index = try findFaceIndexByPostScript(io, face.path, "PostscriptSans-Regular");
    try std.testing.expectEqual(@as(?u32, 0), index);
}

test "CSS stretch selection prefers the closest class" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const regular = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Stretch Sans",
        .subfamily = "Regular",
        .width_class = 5,
        .postscript_name = "StretchSans-Regular",
    });
    defer std.testing.allocator.free(regular);
    const condensed = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Stretch Sans",
        .subfamily = "Condensed",
        .width_class = 3,
        .postscript_name = "StretchSans-Condensed",
    });
    defer std.testing.allocator.free(condensed);
    try tmp.dir.writeFile(io, .{ .sub_path = "StretchSans-Regular.ttf", .data = regular });
    try tmp.dir.writeFile(io, .{ .sub_path = "StretchSans-Condensed.ttf", .data = condensed });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findFace(io, .{
        .family = "Stretch Sans",
        .stretch = 75,
    }, .{ .roots = &roots }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 75), face.stretch);
    try std.testing.expectEqualStrings("Condensed", face.subfamily);
}

test "TT collection face indexes follow PostScript names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const regular = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Collection Sans",
        .subfamily = "Regular",
        .postscript_name = "CollectionSans-Regular",
    });
    defer std.testing.allocator.free(regular);
    const bold = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Collection Sans",
        .subfamily = "Bold",
        .weight = 700,
        .postscript_name = "CollectionSans-Bold",
    });
    defer std.testing.allocator.free(bold);
    const collection = try test_font.buildTestCollection(std.testing.allocator, &.{ regular, bold });
    defer std.testing.allocator.free(collection);
    try tmp.dir.writeFile(io, .{ .sub_path = "CollectionSans.ttc", .data = collection });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);
    const face = findByPostScript(io, "CollectionSans-Bold", .{ .roots = &roots }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), face.face_index);
    try std.testing.expectEqual(@as(u16, 700), face.weight);
    const index = try findFaceIndexByPostScript(io, face.path, "CollectionSans-Bold");
    try std.testing.expectEqual(@as(?u32, 1), index);
}

test "face selection prefers the optical-size range containing the query" {
    const faces = [_]Face{
        .{
            .path = "text.ttf",
            .family = "Opsz Sans",
            .subfamily = "Regular",
            .opsz_min = 8,
            .opsz_default = 10,
            .opsz_max = 12,
        },
        .{
            .path = "display.ttf",
            .family = "Opsz Sans",
            .subfamily = "Regular",
            .opsz_min = 48,
            .opsz_default = 64,
            .opsz_max = 96,
        },
    };
    const indices = [_]u32{ 0, 1 };
    const text = selectBestFace(&faces, &indices, .{
        .family = "Opsz Sans",
        .opsz = 11,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text.ttf", text.path);
    const display = selectBestFace(&faces, &indices, .{
        .family = "Opsz Sans",
        .opsz = 70,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("display.ttf", display.path);
    const no_preference = selectBestFace(&faces, &indices, .{
        .family = "Opsz Sans",
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text.ttf", no_preference.path);
}

test "index selects faces by opsz axis range" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text_font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Optical Sans",
        .subfamily = "Text",
        .postscript_name = "OpticalSans-Text",
        .opsz = .{ .min = 8, .default = 10, .max = 12 },
    });
    defer std.testing.allocator.free(text_font);
    const display_font = try test_font.buildTestFont(std.testing.allocator, .{
        .family = "Optical Sans",
        .subfamily = "Display",
        .postscript_name = "OpticalSans-Display",
        .opsz = .{ .min = 48, .default = 64, .max = 96 },
    });
    defer std.testing.allocator.free(display_font);
    try tmp.dir.writeFile(io, .{ .sub_path = "OpticalSans-Text.ttf", .data = text_font });
    try tmp.dir.writeFile(io, .{ .sub_path = "OpticalSans-Display.ttf", .data = display_font });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const roots = [_][]const u8{path_buffer[0..root_len]};
    resetForTesting(io);
    defer resetForTesting(io);

    const text = findFace(io, .{
        .family = "Optical Sans",
        .opsz = 11,
    }, .{ .roots = &roots }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("OpticalSans-Text", text.postscript_name);
    try std.testing.expectEqual(@as(?f32, 10), text.opsz_default);

    const display = findFace(io, .{
        .family = "Optical Sans",
        .opsz = 70,
    }, .{ .roots = &roots }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("OpticalSans-Display", display.postscript_name);
    try std.testing.expectEqual(@as(?f32, 64), display.opsz_default);
}
