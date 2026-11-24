//! Native deterministic catalog lifecycle regressions. No timing sleeps.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Discovery = @import("pure_discovery.zig").Discovery;
const index = @import("metadata_index.zig");
const disk_cache = @import("metadata/index_cache.zig");
const snapshots = @import("metadata/snapshot.zig");
const test_font = @import("metadata/test_font.zig");
const hooks = @import("concurrency_hooks.zig");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn wait(event: *std.Io.Event) !void {
    const deadline = std.Io.Timeout.toDeadline(.{ .duration = .{
        .raw = .fromSeconds(20),
        .clock = .awake,
    } }, io);
    while (!event.isSet()) {
        event.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => {
                if (deadline.deadline.raw.nanoseconds <= std.Io.Clock.now(.awake, io).nanoseconds)
                    return error.BarrierTimeout;
            },
            else => return err,
        };
    }
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &path_buffer);
        const root = try allocator.dupe(u8, path_buffer[0..len]);
        errdefer allocator.free(root);
        var fixture = Fixture{ .tmp = tmp, .root = root };
        try fixture.write("Lease Sans", 'A');
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, family: []const u8, codepoint: u21) !void {
        const table = try test_font.buildTestCmap(allocator, &.{.{ .start = codepoint, .end = codepoint }}, 12);
        defer allocator.free(table);
        const font = try test_font.buildTestFont(allocator, .{
            .family = family,
            .postscript_name = "LeaseSans-Regular",
            .cmap = table,
            .instances = &.{.{ .subfamily = "Light", .postscript_name = "LeaseSans-Light", .weight = 300 }},
        });
        defer allocator.free(font);
        try self.tmp.dir.writeFile(io, .{ .sub_path = "lease.ttf", .data = font });
    }

    fn options(self: *const Fixture, roots: *[1][]const u8) index.Options {
        roots.* = .{self.root};
        return .{ .roots = roots, .enable_cache = false };
    }
};

// The first matching boundary pauses. Destruction signals are filtered to the
// selected epoch, so rebuilding a newer snapshot cannot mask a premature free.
const Barrier = struct {
    point: hooks.Point,
    entered: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    destroyed: std.Io.Event = .unset,
    refresh_waiting: std.Io.Event = .unset,
    refresh_locked: std.Io.Event = .unset,
    second_builder: std.Io.Event = .unset,
    builders: std.atomic.Value(usize) = .init(0),
    calls: std.atomic.Value(usize) = .init(0),
    epoch: std.atomic.Value(u64) = .init(0),

    fn install(self: *Barrier) void {
        hooks.active = .{ .context = self, .callback = callback };
    }

    fn callback(context: *anyopaque, point: hooks.Point, epoch: u64) void {
        const self: *Barrier = @ptrCast(@alignCast(context));
        if (point == .snapshot_destroyed and epoch == self.epoch.load(.acquire)) self.destroyed.set(io);
        if (point == .refresh_waiting) self.refresh_waiting.set(io);
        if (point == .refresh_locked) self.refresh_locked.set(io);
        if (point == .build_waiting and self.builders.fetchAdd(1, .acq_rel) + 1 == 2) self.second_builder.set(io);
        if (point != self.point or self.calls.fetchAdd(1, .acq_rel) != 0) return;
        self.epoch.store(epoch, .release);
        self.entered.set(io);
        self.proceed.waitUncancelable(io);
    }
};

const ResolveWorker = struct {
    discovery: *Discovery,
    query: types.Query,
    result: ?types.Resolution = null,
    failure: ?anyerror = null,

    fn run(self: *ResolveWorker) void {
        self.result = self.discovery.resolve(allocator, self.query) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn deinit(self: *ResolveWorker) void {
        if (self.result) |*result| result.deinit();
    }
};

const ResetWorker = struct {
    done: std.Io.Event = .unset,

    fn run(self: *ResetWorker) void {
        index.reset(io);
        self.done.set(io);
    }
};

test "catalog concurrency cross-owner refresh preserves selected face until clone" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    try std.testing.expect(index.prewarm(io, fixture.options(&roots)));
    var first = try Discovery.initWithRoots(allocator, &roots);
    defer first.deinit();
    var second = try Discovery.initWithRoots(allocator, &roots);
    defer second.deinit();
    var barrier = Barrier{ .point = .face_selected };
    barrier.install();
    defer hooks.active = null;
    var worker = ResolveWorker{ .discovery = &first, .query = .{
        .family = "Lease Sans",
        .postscript_name = "LeaseSans-Light",
        .weight = 300,
        .required_codepoint = 'A',
        .max_candidates = 1,
    } };
    defer worker.deinit();
    const thread = try std.Thread.spawn(.{}, ResolveWorker.run, .{&worker});
    var joined = false;
    defer {
        barrier.proceed.set(io);
        if (!joined) thread.join();
    }
    try wait(&barrier.entered);
    const old_epoch = barrier.epoch.load(.acquire);
    // The other owner's refresh must complete even with the first owner's
    // selected Face borrowed. Its reset drops only the global reference.
    try std.testing.expect(try second.refresh());
    try std.testing.expect(index.generation() != old_epoch);
    try std.testing.expect(!barrier.destroyed.isSet());
    barrier.proceed.set(io);
    thread.join();
    joined = true;
    try std.testing.expect(worker.failure == null);
    try wait(&barrier.destroyed);
    const result = worker.result.?;
    try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
    try std.testing.expectEqualStrings("Lease Sans", result.candidates[0].family.?);
    try std.testing.expectEqualStrings("LeaseSans-Light", result.candidates[0].postscript_name.?);
    try std.testing.expectEqual(@as(u16, 1), result.candidates[0].named_instance);
    try std.testing.expectEqual(@as(u64, old_epoch), first.coverage.generation.?);
}

test "catalog concurrency miss insertion retains its lease epoch after reset" {
    if (builtin.single_threaded) return error.SkipZigTest;
    for ([_]u21{ 'A', 'B' }) |codepoint| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        index.reset(io);
        defer index.reset(io);
        var roots: [1][]const u8 = undefined;
        try std.testing.expect(index.prewarm(io, fixture.options(&roots)));
        var discovery = try Discovery.initWithRoots(allocator, &roots);
        defer discovery.deinit();
        var barrier = Barrier{ .point = .face_selected };
        barrier.install();
        defer hooks.active = null;
        const query = types.Query{
            .family = "Lease Sans",
            .postscript_name = "LeaseSans-Regular",
            .required_codepoint = codepoint,
            .max_candidates = 1,
        };
        var worker = ResolveWorker{ .discovery = &discovery, .query = query };
        defer worker.deinit();
        const thread = try std.Thread.spawn(.{}, ResolveWorker.run, .{&worker});
        var joined = false;
        defer {
            barrier.proceed.set(io);
            if (!joined) thread.join();
        }
        try wait(&barrier.entered);
        var resetter: ResetWorker = .{};
        const reset_thread = try std.Thread.spawn(.{}, ResetWorker.run, .{&resetter});
        defer reset_thread.join();
        try wait(&resetter.done);
        try std.testing.expect(!barrier.destroyed.isSet());
        barrier.proceed.set(io);
        thread.join();
        joined = true;
        try std.testing.expect(worker.failure == null);
        try std.testing.expectEqual(@as(usize, if (codepoint == 'A') 1 else 0), worker.result.?.candidates.len);
        if (codepoint == 'A') {
            const candidate = worker.result.?.candidates[0];
            const fixture_path = try std.fs.path.join(allocator, &.{ fixture.root, "lease.ttf" });
            defer allocator.free(fixture_path);
            try std.testing.expectEqual(types.Provider.metadata_index, candidate.provider);
            try std.testing.expectEqualStrings(fixture_path, candidate.path);
            try std.testing.expectEqualStrings("LeaseSans-Regular", candidate.postscript_name.?);
        }
        try std.testing.expectEqual(barrier.epoch.load(.acquire), discovery.coverage.generation.?);
        const before = discovery.stats();
        var next = try discovery.resolve(allocator, query);
        defer next.deinit();
        try std.testing.expectEqual(@as(usize, if (codepoint == 'A') 1 else 0), next.candidates.len);
        const after = discovery.stats();
        try std.testing.expectEqual(before.cache_misses + 1, after.cache_misses);
        try std.testing.expectEqual(before.cache_hits, after.cache_hits);
        try std.testing.expectEqual(before.coverage_file_opens + 1, after.coverage_file_opens);
        try std.testing.expectEqual(index.generation(), discovery.coverage.generation.?);
        try std.testing.expect(worker.result.?.shared != next.shared);
        // Once rebuilt, exact hits retain without output allocation or font IO.
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        var hit = try discovery.resolve(failing.allocator(), query);
        defer hit.deinit();
        try std.testing.expect(next.shared == hit.shared);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expectEqual(after.coverage_file_opens, discovery.stats().coverage_file_opens);
    }
}

const ReadWorker = struct {
    discovery: *Discovery,
    enumerate: bool,
    warmed: bool = false,
    names: ?[]const []const u8 = null,
    failure: ?anyerror = null,

    fn run(self: *ReadWorker) void {
        if (self.enumerate) {
            self.names = self.discovery.allFamilyNames(allocator) catch |err| {
                self.failure = err;
                return;
            };
        } else self.warmed = self.discovery.prewarm();
    }

    fn deinit(self: *ReadWorker) void {
        if (self.names) |names| types.freeFamilyNames(allocator, names);
    }
};

const RefreshWorker = struct {
    discovery: *Discovery,
    success: bool = false,
    failure: ?anyerror = null,

    fn run(self: *RefreshWorker) void {
        self.success = self.discovery.refresh() catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "catalog concurrency owner prewarm and enumeration serialize refresh config reads" {
    if (builtin.single_threaded) return error.SkipZigTest;
    for ([_]bool{ false, true }) |enumerate| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        index.reset(io);
        defer index.reset(io);
        const roots = [_][]const u8{fixture.root};
        var discovery = try Discovery.initWithRoots(allocator, &roots);
        defer discovery.deinit();
        var barrier = Barrier{ .point = .owner_read };
        barrier.install();
        defer hooks.active = null;
        var reader = ReadWorker{ .discovery = &discovery, .enumerate = enumerate };
        defer reader.deinit();
        const read_thread = try std.Thread.spawn(.{}, ReadWorker.run, .{&reader});
        var read_joined = false;
        defer {
            barrier.proceed.set(io);
            if (!read_joined) read_thread.join();
        }
        try wait(&barrier.entered);
        // This observation is made at an explicit boundary, not after a sleep.
        const unexpectedly_unlocked = discovery.mutex.tryLock();
        if (unexpectedly_unlocked) discovery.mutex.unlock(io);
        try std.testing.expect(!unexpectedly_unlocked);
        var refresher = RefreshWorker{ .discovery = &discovery };
        const refresh_thread = try std.Thread.spawn(.{}, RefreshWorker.run, .{&refresher});
        var refresh_joined = false;
        defer {
            barrier.proceed.set(io);
            if (!refresh_joined) refresh_thread.join();
        }
        try wait(&barrier.refresh_waiting);
        try std.testing.expect(!barrier.refresh_locked.isSet());
        barrier.proceed.set(io);
        read_thread.join();
        read_joined = true;
        refresh_thread.join();
        refresh_joined = true;
        try std.testing.expect(reader.failure == null);
        try std.testing.expect(refresher.failure == null and refresher.success);
        try std.testing.expect(barrier.refresh_locked.isSet());
        if (enumerate) {
            try std.testing.expectEqual(@as(usize, 1), reader.names.?.len);
            try std.testing.expectEqualStrings("Lease Sans", reader.names.?[0]);
        } else try std.testing.expect(reader.warmed);
    }
}

const BuildWorker = struct {
    options: index.Options,
    lease: ?index.ReadLease = null,

    fn run(self: *BuildWorker) void {
        self.lease = index.acquireRead(io, self.options);
    }

    fn deinit(self: *BuildWorker) void {
        if (self.lease) |*lease| lease.deinit();
    }
};

test "catalog concurrency simultaneous cold readers share one accepted snapshot" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    const options = fixture.options(&roots);
    var barrier = Barrier{ .point = .before_publish };
    barrier.install();
    defer hooks.active = null;
    var first = BuildWorker{ .options = options };
    defer first.deinit();
    var second = BuildWorker{ .options = options };
    defer second.deinit();
    const first_thread = try std.Thread.spawn(.{}, BuildWorker.run, .{&first});
    var first_joined = false;
    defer {
        barrier.proceed.set(io);
        if (!first_joined) first_thread.join();
    }
    try wait(&barrier.entered);
    const second_thread = try std.Thread.spawn(.{}, BuildWorker.run, .{&second});
    var second_joined = false;
    defer {
        barrier.proceed.set(io);
        if (!second_joined) second_thread.join();
    }
    try wait(&barrier.second_builder);
    try std.testing.expectEqual(@as(usize, 1), barrier.calls.load(.acquire));
    barrier.proceed.set(io);
    first_thread.join();
    first_joined = true;
    second_thread.join();
    second_joined = true;
    try std.testing.expectEqual(@as(usize, 1), barrier.calls.load(.acquire));
    try std.testing.expect(first.lease.?.available() and second.lease.?.available());
    try std.testing.expect(first.lease.?.snapshot == second.lease.?.snapshot);
    try std.testing.expectEqual(first.lease.?.epoch, second.lease.?.epoch);
}

test "catalog concurrency discards pre-reset cold build and cache-origin diagnostic" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    const cache_path = try std.fs.path.join(allocator, &.{ fixture.root, "index.bin" });
    defer allocator.free(cache_path);
    const roots = [_][]const u8{fixture.root};
    const options = index.Options{ .roots = &roots, .cache_path = cache_path };
    try std.testing.expect(index.prewarm(io, options));
    try std.testing.expect(!index.lastBuildUsedCache());
    index.reset(io);
    var barrier = Barrier{ .point = .before_publish };
    barrier.install();
    defer hooks.active = null;
    var worker = BuildWorker{ .options = options };
    defer worker.deinit();
    const thread = try std.Thread.spawn(.{}, BuildWorker.run, .{&worker});
    var joined = false;
    defer {
        barrier.proceed.set(io);
        if (!joined) thread.join();
    }
    try wait(&barrier.entered);
    // The paused attempt loaded the old cache, but has not been accepted.
    try std.testing.expect(!index.lastBuildUsedCache());
    try fixture.write("Replacement Lease Family", 'B');
    var resetter: ResetWorker = .{};
    const reset_thread = try std.Thread.spawn(.{}, ResetWorker.run, .{&resetter});
    defer reset_thread.join();
    try wait(&resetter.done);
    const accepted_epoch = index.generation();
    barrier.proceed.set(io);
    thread.join();
    joined = true;
    try wait(&barrier.destroyed);
    const lease = worker.lease.?;
    try std.testing.expect(lease.available());
    try std.testing.expectEqual(accepted_epoch, lease.epoch);
    try std.testing.expectEqual(@as(usize, 2), barrier.calls.load(.acquire));
    try std.testing.expect(lease.findFace(.{ .family = "Lease Sans" }, options) == null);
    const face = lease.findFace(.{ .family = "Replacement Lease Family" }, options).?;
    try std.testing.expectEqualStrings("Replacement Lease Family", face.family);
    try std.testing.expect(!index.lastBuildUsedCache());
    index.reset(io);
    try std.testing.expect(index.prewarm(io, options));
    try std.testing.expect(index.lastBuildUsedCache());
}

test "catalog concurrency family copy retains snapshot across reset" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    var lease = index.acquireRead(io, fixture.options(&roots));
    var lease_live = true;
    defer if (lease_live) lease.deinit();
    const epoch = lease.epoch;
    var barrier = Barrier{ .point = .face_selected };
    barrier.epoch.store(epoch, .release);
    barrier.install();
    defer hooks.active = null;
    index.reset(io);
    try std.testing.expect(!barrier.destroyed.isSet());
    const names = try lease.familyNames(allocator);
    defer types.freeFamilyNames(allocator, names);
    lease.deinit();
    lease_live = false;
    try std.testing.expect(barrier.destroyed.isSet());
    try std.testing.expectEqualStrings("Lease Sans", names[0]);
}

const ReleaseWorker = struct {
    resolution: types.Resolution,
    start: *std.Io.Event,

    fn run(self: *ReleaseWorker) void {
        self.start.waitUncancelable(io);
        self.resolution.deinit();
    }
};

test "catalog concurrency retained named-instance resolutions outlive owner and release in parallel" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    const roots = [_][]const u8{fixture.root};
    var discovery = try Discovery.initWithRoots(allocator, &roots);
    var owner_live = true;
    defer if (owner_live) discovery.deinit();
    var held = try discovery.resolve(allocator, .{
        .family = "Lease Sans",
        .postscript_name = "LeaseSans-Light",
        .max_candidates = 1,
    });
    defer held.deinit();
    var start: std.Io.Event = .unset;
    var workers: [4]ReleaseWorker = undefined;
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.set(io);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{ .resolution = held.retain(), .start = &start };
        thread.* = std.Thread.spawn(.{}, ReleaseWorker.run, .{worker}) catch |err| {
            worker.resolution.deinit();
            return err;
        };
        spawned += 1;
    }
    try std.testing.expect(try discovery.refresh());
    index.reset(io);
    discovery.deinit();
    owner_live = false;
    try std.testing.expectEqualStrings("Lease Sans", held.candidates[0].family.?);
    try std.testing.expectEqual(@as(u16, 1), held.candidates[0].named_instance);
    start.set(io);
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    try std.testing.expectEqualStrings("LeaseSans-Light", held.candidates[0].postscript_name.?);
}

const StoreWorker = struct {
    path: []const u8,
    faces: []const index.Face,
    stamps: []const disk_cache.FileStamp,

    fn run(self: *StoreWorker) void {
        disk_cache.store(index.Face, io, std.heap.page_allocator, self.path, &.{}, self.stamps, self.faces, 7);
    }
};

const StoreBarrier = struct {
    ready: std.Io.Event = .unset,
    proceed: std.Io.Event = .unset,
    writers: std.atomic.Value(usize) = .init(0),

    fn callback(context: *anyopaque, point: hooks.Point, _: u64) void {
        if (point != .cache_temp_created) return;
        const self: *StoreBarrier = @ptrCast(@alignCast(context));
        if (self.writers.fetchAdd(1, .acq_rel) + 1 == 2) self.ready.set(io);
        self.proceed.waitUncancelable(io);
    }
};

test "catalog concurrency disk writers own unique exclusive temporary files" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const path = try std.fs.path.join(allocator, &.{ fixture.root, "concurrent.bin" });
    defer allocator.free(path);
    const old_tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(old_tmp);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "concurrent.bin.tmp", .data = "unrelated writer" });
    const stamps = [_]disk_cache.FileStamp{.{ .path = "/fixture.ttf", .mtime_ns = 1, .size = 2 }};
    const first_faces = [_]index.Face{.{ .path = stamps[0].path, .family = "First Writer", .subfamily = "Regular" }};
    const second_faces = [_]index.Face{.{ .path = stamps[0].path, .family = "Second Writer", .subfamily = "Regular" }};
    var barrier: StoreBarrier = .{};
    hooks.active = .{ .context = &barrier, .callback = StoreBarrier.callback };
    defer hooks.active = null;
    var first = StoreWorker{ .path = path, .faces = &first_faces, .stamps = &stamps };
    var second = StoreWorker{ .path = path, .faces = &second_faces, .stamps = &stamps };
    const first_thread = try std.Thread.spawn(.{}, StoreWorker.run, .{&first});
    var first_joined = false;
    defer {
        barrier.proceed.set(io);
        if (!first_joined) first_thread.join();
    }
    const second_thread = try std.Thread.spawn(.{}, StoreWorker.run, .{&second});
    var second_joined = false;
    defer {
        barrier.proceed.set(io);
        if (!second_joined) second_thread.join();
    }
    try wait(&barrier.ready);
    var iterator = fixture.tmp.dir.iterate();
    var temps: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "concurrent.bin.tmp-")) temps += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), temps);
    barrier.proceed.set(io);
    first_thread.join();
    first_joined = true;
    second_thread.join();
    second_joined = true;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const loaded = (try disk_cache.load(index.Face, io, arena.allocator(), path, &.{}, &stamps, 7)).?;
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(std.mem.eql(u8, loaded[0].family, "First Writer") or std.mem.eql(u8, loaded[0].family, "Second Writer"));
    var file = try std.Io.Dir.openFileAbsolute(io, old_tmp, .{});
    defer file.close(io);
    var buffer: [16]u8 = undefined;
    const len = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualStrings("unrelated writer", buffer[0..len]);
    iterator = fixture.tmp.dir.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, "concurrent.bin.tmp-"));
    }
}

const TestPayload = struct {
    destroys: *usize,

    pub fn deinit(self: *TestPayload) void {
        self.destroys.* += 1;
    }
};

test "catalog OOM snapshot creation retains caller ownership on allocation failure" {
    var destroys: usize = 0;
    var payload = TestPayload{ .destroys = &destroys };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, snapshots.Snapshot(TestPayload).create(failing.allocator(), payload, 8, false));
    try std.testing.expectEqual(@as(usize, 0), destroys);
    payload.deinit();
    try std.testing.expectEqual(@as(usize, 1), destroys);
    const snapshot = try snapshots.Snapshot(TestPayload).create(allocator, .{ .destroys = &destroys }, 9, true);
    snapshot.retain();
    snapshot.release();
    try std.testing.expectEqual(@as(usize, 1), destroys);
    snapshot.release();
    try std.testing.expectEqual(@as(usize, 2), destroys);
}

test "catalog OOM failed catalog snapshot allocation destroys the built arena and retries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    const options = fixture.options(&roots);
    var persistent = std.testing.FailingAllocator.init(allocator, .{});
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    hooks.persistent_allocator = persistent.allocator();
    hooks.snapshot_allocator = failing.allocator();
    defer {
        hooks.snapshot_allocator = null;
        hooks.persistent_allocator = null;
    }
    const epoch = index.generation();
    var failed = index.acquireRead(io, options);
    defer failed.deinit();
    try std.testing.expect(!failed.available());
    try std.testing.expectEqual(epoch, failed.epoch);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(persistent.allocated_bytes > 0);
    try std.testing.expectEqual(persistent.allocated_bytes, persistent.freed_bytes);
    hooks.snapshot_allocator = null;
    var accepted = index.acquireRead(io, options);
    var accepted_live = true;
    defer if (accepted_live) accepted.deinit();
    try std.testing.expect(accepted.available());
    const face = accepted.findFace(.{ .family = "Lease Sans" }, options).?;
    try std.testing.expectEqualStrings("Lease Sans", face.family);
    index.reset(io);
    accepted.deinit();
    accepted_live = false;
    try std.testing.expectEqual(persistent.allocated_bytes, persistent.freed_bytes);
}

test "catalog OOM family copies clean partial output and keep detached lease readable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    var lease = index.acquireRead(io, fixture.options(&roots));
    defer lease.deinit();
    index.reset(io);
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, lease.familyNames(failing.allocator()));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    const names = try lease.familyNames(allocator);
    defer types.freeFamilyNames(allocator, names);
    try std.testing.expectEqualStrings("Lease Sans", names[0]);
}

fn oomResolve(out_allocator: std.mem.Allocator, roots: []const []const u8) !void {
    var discovery = try Discovery.initWithRoots(out_allocator, roots);
    defer discovery.deinit();
    const query = types.Query{ .family = "Lease Sans", .postscript_name = "LeaseSans-Light", .max_candidates = 1 };
    var resolution = try discovery.resolve(out_allocator, query);
    defer resolution.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolution.candidates.len);
    try std.testing.expectEqual(@as(u16, 1), resolution.candidates[0].named_instance);
    var hit = try discovery.resolve(out_allocator, query);
    defer hit.deinit();
    try std.testing.expect(resolution.candidates.ptr == hit.candidates.ptr);
    index.reset(io);
    try std.testing.expectEqualStrings("LeaseSans-Light", resolution.candidates[0].postscript_name.?);
}

test "catalog OOM named-instance resolution and query-cache adoption release every partial allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    index.reset(io);
    defer index.reset(io);
    var roots: [1][]const u8 = undefined;
    try std.testing.expect(index.prewarm(io, fixture.options(&roots)));
    try std.testing.checkAllAllocationFailures(allocator, oomResolve, .{@as([]const []const u8, &roots)});
}
