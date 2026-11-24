//! Explicit test root prevents lazy declarations from hiding cmap14 tests.
comptime {
    _ = @import("root.zig");
    _ = @import("metadata/variation_tests.zig");
    _ = @import("metadata/variation_cache_tests.zig");
    _ = @import("query_cache.zig");
    _ = @import("variation_fallback_tests.zig");
}
