//! Unicode validity shared by discovery, file readers and retained tables.
pub fn isScalar(value: u21) bool {
    return value <= 0x10ffff and (value < 0xd800 or value > 0xdfff);
}

pub fn isSelector(value: u21) bool {
    return (value >= 0xfe00 and value <= 0xfe0f) or
        (value >= 0xe0100 and value <= 0xe01ef);
}

pub fn validCoverage(base: ?u21, selector: ?u21) bool {
    if (base) |value| {
        if (!isScalar(value)) return false;
    }
    if (selector) |value| return base != null and isSelector(value);
    return true;
}
