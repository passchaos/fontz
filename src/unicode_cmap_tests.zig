//! Explicit owner root keeps all new named tests discoverable by the package gate.
comptime {
    _ = @import("metadata/numeric_unit_tests.zig");
    _ = @import("metadata/numeric_cache_tests.zig");
    _ = @import("metadata/numeric_discovery_tests.zig");
}
