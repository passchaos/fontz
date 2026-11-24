//! Deterministic test barriers. Install/remove only while workers are quiescent.

const builtin = @import("builtin");
const std = @import("std");

pub const Point = enum {
    before_publish,
    build_waiting,
    snapshot_destroyed,
    face_selected,
    owner_read,
    refresh_waiting,
    refresh_locked,
    cache_temp_created,
};

pub const Hook = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, Point, u64) void,
};

pub var active: ?Hook = null;
/// Allocation injection is installed only with all catalog workers quiescent.
pub var snapshot_allocator: ?std.mem.Allocator = null;
pub var persistent_allocator: ?std.mem.Allocator = null;

pub inline fn fire(point: Point, epoch: u64) void {
    if (builtin.is_test) {
        if (active) |hook| hook.callback(hook.context, point, epoch);
    }
}
