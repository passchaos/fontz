//! Stable legacy ranking and Cangjie default ranking for extended Unicode contexts.
pub fn isExtended(format: u16) bool {
    return format == 2 or format == 8 or format == 10;
}
pub fn eligibleExtended(platform: u16, encoding: u16, format: u16) bool {
    return isExtended(format) and platform == 0 and (encoding <= 2 or (encoding == 4 and (format == 8 or format == 10)));
}

/// This profile is unchanged when no standard eligible extended record exists.
pub fn legacyScore(platform: u16, encoding: u16, format: u16) u8 {
    if (format == 12 or format == 13) {
        if (platform == 3 and encoding == 10) return 100;
        if (platform == 0 and (encoding == 4 or encoding == 6)) return 95;
        return 60;
    }
    if (format == 4) {
        if (platform == 3 and encoding == 1) return 80;
        if (platform == 0 and (encoding == 3 or encoding == 4)) return 75;
        return 40;
    }
    if (format == 6) return 30;
    if (format == 0) return 10;
    return 0;
}

/// Match the consuming Face's default picker. Zero is a valid priority for
/// deprecated Unicode format8/10; null means the record is not a candidate.
/// Ties keep the first record. Selection never unions sibling coverage.
pub fn mixedScore(platform: u16, encoding: u16, format: u16) ?u8 {
    if (isExtended(format) and !eligibleExtended(platform, encoding, format)) return null;
    if (format == 12 and platform == 3 and encoding == 10) return 8;
    if (format == 12 and platform == 0) return 7;
    if (format == 8 and platform == 0 and encoding == 4) return 6;
    if (format == 4 and platform == 3 and encoding == 1) return 5;
    if (format == 4 and platform == 0) return 4;
    if (format == 13 and ((platform == 0 and encoding == 6) or (platform == 3 and encoding == 10))) return 2;
    if (format == 10 and platform == 0 and encoding == 4) return 2;
    if ((format == 2 or format == 6) and (platform == 0 or platform == 3)) return 1;
    if (format == 0) return 1;
    return switch (format) {
        2, 4, 6, 8, 10, 12, 13 => 0,
        else => null,
    };
}
