//! Exercise the package's published types and function signatures as a consumer.
const std = @import("std");
const fontz = @import("fontz");

test "variation sequence published API retains selector and rejects invalid coverage" {
    const query = fontz.Query{ .family = "Published UVS", .required_codepoint = 0x4e2d, .required_variation_selector = 0xe0100 };
    try std.testing.expectEqual(@as(?u21, 0xe0100), query.required_variation_selector);
    try std.testing.expect(query.validCoverage());
    try std.testing.expect((fontz.Query{ .family = "Published UVS", .required_codepoint = 0x4e2d, .required_variation_selector = 0xfe00 }).validCoverage());
    try std.testing.expect((fontz.Query{ .family = "Published UVS", .required_codepoint = 0x4e2d, .required_variation_selector = 0xfe0d }).validCoverage());
    const Covers = *const fn (*fontz.Discovery, []const u8, u32, u21, u21) anyerror!bool;
    const covers: Covers = fontz.Discovery.coversVariationSequence;
    var discovery = fontz.Discovery.init(std.testing.allocator);
    defer discovery.deinit();
    try std.testing.expect(!try covers(&discovery, "/missing/uvs-font.ttf", 0, 0x2764, 0xfe10));
    var missing = try discovery.resolveQuery(std.testing.allocator, .{ .family = "", .required_variation_selector = 0xfe0f });
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.candidates.len);
    try std.testing.expectEqual(@as(u64, 0), discovery.stats().coverage_file_opens);
}
