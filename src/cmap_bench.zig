//! Matched benchmark: existing Cache.coversCodepoint only, no Query cache.
const std = @import("std");
const coverage = @import("metadata/coverage_cache.zig");
const cmap = @import("metadata/cmap.zig");
const font = @import("metadata/test_font.zig");
const metadata = @import("metadata_index.zig");
const unicode = @import("variation.zig");

const Info = struct { offset: usize, format: u16, count: u32 };
fn info(bytes: []const u8) !Info {
    if (bytes.len < 4) return error.BadTable;
    const records = readU16(bytes, 2);
    var selected: ?Info = null;
    var score: u8 = 0;
    for (0..records) |i| {
        const record = 4 + i * 8;
        if (record + 8 > bytes.len) return error.BadTable;
        const platform = readU16(bytes, record);
        const encoding = readU16(bytes, record + 2);
        const offset = readU32(bytes, record + 4);
        if (@as(u64, offset) + 2 > bytes.len) continue;
        const format = readU16(bytes, offset);
        const candidate: u8 = if (format == 12 or format == 13)
            (if (platform == 3 and encoding == 10) 100 else if (platform == 0 and (encoding == 4 or encoding == 6)) 95 else 60)
        else if (format == 4)
            (if (platform == 3 and encoding == 1) 80 else if (platform == 0 and (encoding == 3 or encoding == 4)) 75 else 40)
        else if (format == 6) 30 else if (format == 0) 10 else 0;
        if (candidate > score) {
            score = candidate;
            selected = .{ .offset = offset, .format = format, .count = 0 };
        }
    }
    var result = selected orelse return error.BadTable;
    if (result.format != 12 and result.format != 13) return error.UnsupportedBenchmarkFormat;
    if (result.offset + 16 > bytes.len) return error.BadTable;
    result.count = readU32(bytes, result.offset + 12);
    if (result.count == 0 or @as(u64, result.count) * 12 > bytes.len - result.offset - 16) return error.BadTable;
    return result;
}
fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

const Host = struct { named_instance: u16 = 0, expected_sha: ?[]const u8 = null, expected_groups: ?u32 = null };

fn run(init: std.process.Init, path: []const u8, face: u32, identity: []const u8, repetitions: usize, host: Host) !void {
    const allocator = init.gpa;
    const table = (try cmap.readTable(init.io, allocator, path, face, null)) orelse return error.NoCmap;
    defer allocator.free(table);
    const source = try info(table);
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(font_bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(font_bytes, &hash, .{});
    const font_sha = std.fmt.bytesToHex(hash, .lower);
    if (host.expected_sha) |expected_sha| if (!std.mem.eql(u8, expected_sha, &font_sha)) return error.HostFontChanged;
    if (host.expected_groups) |count| if (count != source.count) return error.HostCmapChanged;
    const queries = try allocator.alloc(u21, 16384);
    defer allocator.free(queries);
    var state: u32 = 0x67ac1234;
    var unique = std.AutoHashMap(u21, void).init(allocator);
    defer unique.deinit();
    var expected: u64 = 0;
    for (queries, 0..) |*query, i| {
        state = state *% 1664525 +% 1013904223;
        const index = state % source.count;
        const row = source.offset + 16 + @as(usize, index) * 12;
        const cp = switch (i % 4) {
            0 => readU32(table, row),
            1 => readU32(table, row + 4),
            2 => std.math.add(u32, readU32(table, row + 4), 1) catch 0x10ffff,
            else => 0x10ffff,
        };
        query.* = if (cp <= 0x10ffff and unicode.isScalar(@intCast(cp))) @intCast(cp) else 1;
        try unique.put(query.*, {});
        expected +%= if (cmap.tableCovers(table, query.*)) @as(u64, query.*) * 3 + 1 else @as(u64, query.*) * 7 + 2;
    }
    var prepare_ns: i96 = -1;
    if (@hasDecl(coverage, "prepareScalarPlan")) {
        const start = std.Io.Clock.awake.now(init.io);
        const plan = coverage.prepareScalarPlan(table);
        std.mem.doNotOptimizeAway(plan);
        prepare_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    }
    var counted = std.testing.FailingAllocator.init(allocator, .{});
    var cache = coverage.Cache.init(counted.allocator());
    defer cache.deinit();
    const first = queries[0];
    const start_cold = std.Io.Clock.awake.now(init.io);
    const cold_result = try cache.coversCodepoint(init.io, path, face, first, 1);
    const cold_ns = start_cold.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    if (cold_result != cmap.tableCovers(table, first)) return error.WrongCoverage;
    for (queries[0..1024]) |cp| _ = try cache.coversCodepoint(init.io, path, face, cp, 1);
    const reads = cache.reads;
    const allocations = counted.allocations;
    const allocated_bytes = counted.allocated_bytes;
    var checksum: u64 = 0;
    const start_warm = std.Io.Clock.awake.now(init.io);
    for (0..repetitions) |_| for (queries) |cp| {
        const hit = try cache.coversCodepoint(init.io, path, face, cp, 1);
        checksum +%= if (hit) @as(u64, cp) * 3 + 1 else @as(u64, cp) * 7 + 2;
    };
    const warm_ns = start_warm.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
    std.mem.doNotOptimizeAway(checksum);
    if (checksum != expected *% @as(u64, @intCast(repetitions))) return error.WrongChecksum;
    if (!std.meta.eql(reads, cache.reads) or allocations != counted.allocations) return error.WarmWork;
    var probe_visits = [_]i64{-1} ** 3;
    if (@hasDecl(coverage.Cache, "coversCodepointCounted")) {
        for ([_]u21{ 20013, 28450, 128512 }, 0..) |cp, i| {
            var work: cmap.WorkStats = .{};
            _ = try cache.coversCodepointCounted(init.io, path, face, cp, 1, &work);
            probe_visits[i] = @intCast(work.group_visits);
        }
    }
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .driver = "Cache.coversCodepoint",
        .path = path,
        .face_index = face,
        .identity = identity,
        .named_instance = host.named_instance,
        .metadata_source = if (host.expected_sha != null) "CoreText URL + independent SFNT/fvar proof" else if (std.mem.eql(u8, identity, "synthetic named SFNT")) "synthetic" else "Fontz metadata index",
        .probe_group_visits = probe_visits,
        .font_sha256 = font_sha[0..],
        .format = source.format,
        .source_groups = source.count,
        .query_count = queries.len * repetitions,
        .unique_scalars = unique.count(),
        .checksum = checksum,
        .cold_ns = cold_ns,
        .preparation_ns = prepare_ns,
        .warm_ns = warm_ns,
        .warm_ns_per_query = @as(f64, @floatFromInt(warm_ns)) / @as(f64, @floatFromInt(queries.len * repetitions)),
        .cold_opens = reads.file_opens,
        .cold_reads = reads.read_calls,
        .cold_bytes = reads.bytes_read,
        .warm_opens = cache.reads.file_opens - reads.file_opens,
        .warm_reads = cache.reads.read_calls - reads.read_calls,
        .warm_allocations = counted.allocations - allocations,
        .cold_allocations = allocations,
        .cache_allocated_bytes = allocated_bytes,
        .resident_bytes = cache.resident_bytes,
        .entry_size = @sizeOf(@TypeOf(cache.entries.items[0])),
    }, .{});
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    var family: ?[]const u8 = null;
    var host_proof: ?[]const u8 = null;
    var repetitions: usize = 8;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--family=")) family = arg[9..];
        if (std.mem.startsWith(u8, arg, "--host-proof=")) host_proof = arg[13..];
        if (std.mem.startsWith(u8, arg, "--repetitions=")) repetitions = try std.fmt.parseInt(usize, arg[14..], 10);
    }
    if (host_proof) |proof_path| {
        const proof_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, proof_path, init.gpa, .limited(1024 * 1024));
        defer init.gpa.free(proof_bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, proof_bytes, .{});
        defer parsed.deinit();
        for (parsed.value.object.get("fonts").?.array.items) |value| {
            const object = value.object;
            try run(init, object.get("path").?.string, @intCast(object.get("face_index").?.integer), object.get("postscript").?.string, repetitions, .{
                .named_instance = @intCast(object.get("named_instance").?.integer),
                .expected_sha = object.get("font_sha256").?.string,
                .expected_groups = @intCast(object.get("group_count").?.integer),
            });
        }
        return;
    }
    if (family) |name| {
        const selected = metadata.findFace(init.io, .{ .family = name }, .{}) orelse return error.MissingHostFamily;
        return run(init, selected.path, selected.face_index, selected.postscript_name, repetitions, .{ .named_instance = selected.named_instance });
    }
    const groups = try init.gpa.alloc(font.TestCoverageGroup, 32768);
    defer init.gpa.free(groups);
    for (groups, 0..) |*group, i| group.* = .{ .start = 0x10000 + @as(u32, @intCast(i)) * 2, .end = 0x10000 + @as(u32, @intCast(i)) * 2, .glyph = @intCast(i + 1) };
    for ([_]u16{ 12, 13 }) |format| {
        const table = try font.buildTestCmap(init.gpa, groups, format);
        defer init.gpa.free(table);
        const bytes = try font.buildTestFont(init.gpa, .{ .family = "Prepared Bench", .postscript_name = "PreparedBench-Regular", .cmap = table });
        defer init.gpa.free(bytes);
        const path = try std.fmt.allocPrint(init.gpa, "/tmp/fontz-cmap-bench-20261125-format{d}.ttf", .{format});
        defer init.gpa.free(path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
        try run(init, path, 0, "synthetic named SFNT", repetitions, .{});
    }
}
