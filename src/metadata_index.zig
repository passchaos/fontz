//! Public compatibility surface for the bounded sfnt metadata index.
//!
//! Parsing lives in `metadata/parse.zig`; indexing, matching and the
//! process-wide cache live in `metadata/index.zig`.

const std = @import("std");
const index = @import("metadata/index.zig");

pub const LocalizedName = index.LocalizedName;
pub const Face = index.Face;
pub const GenericMapping = index.GenericMapping;
pub const Options = index.Options;
pub const prewarm = index.prewarm;
pub const lastBuildUsedCache = index.lastBuildUsedCache;
pub const generation = index.generation;
pub const resetForTesting = index.resetForTesting;
pub const reset = index.reset;
pub const findFamily = index.findFamily;
pub const findFace = index.findFace;
pub const findByPostScript = index.findByPostScript;
pub const familyNames = index.familyNames;
pub const allFamilyNames = index.allFamilyNames;
pub const findFaceIndexByPostScript = index.findFaceIndexByPostScript;
pub const familyNamesEqual = index.familyNamesEqual;
pub const defaultRoots = index.defaultRoots;

test {
    std.testing.refAllDecls(@This());
}
