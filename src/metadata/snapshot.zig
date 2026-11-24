//! Heap-owned immutable payload with one reference per reader/cache owner.

const std = @import("std");

pub fn Snapshot(comptime Payload: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        payload: Payload,
        epoch: u64,
        from_cache: bool,
        refs: std.atomic.Value(usize),
        on_destroy: ?*const fn (u64) void = null,

        /// Adopt payload only on success. The initial reference belongs to the
        /// publisher; every read lease must retain its own reference.
        pub fn create(allocator: std.mem.Allocator, payload: Payload, epoch: u64, from_cache: bool) !*Self {
            const snapshot = try allocator.create(Self);
            snapshot.* = .{
                .allocator = allocator,
                .payload = payload,
                .epoch = epoch,
                .from_cache = from_cache,
                .refs = std.atomic.Value(usize).init(1),
            };
            return snapshot;
        }

        /// The caller already owns a reference or holds the publisher mutex.
        pub fn retain(self: *Self) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *Self) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            self.payload.deinit();
            if (self.on_destroy) |callback| callback(self.epoch);
            self.allocator.destroy(self);
        }
    };
}
