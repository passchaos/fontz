//! System-font discovery startup benchmark.
//!
//! Reports the cold and warm cost of building the process-wide metadata index
//! through the default (fontconfig/platform) roots. Run it twice: the first
//! invocation populates the persistent cache, the second should report
//! `from_cache=true` and a much lower elapsed time.
const std = @import("std");
const fontz = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const start = std.Io.Clock.awake.now(io);
    var discovery = fontz.Discovery.init(allocator);
    defer discovery.deinit();
    const prewarmed = discovery.prewarm();
    const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    const from_cache = fontz.metadata_index.lastBuildUsedCache();
    const families = discovery.allFamilyNames(allocator) catch &.{};
    defer if (families.len != 0) allocator.free(families);
    std.debug.print(
        "{{\"prewarmed\":{},\"from_cache\":{},\"elapsed_ms\":{d:.3},\"family_count\":{}}}\n",
        .{
            prewarmed,
            from_cache,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            families.len,
        },
    );
}
