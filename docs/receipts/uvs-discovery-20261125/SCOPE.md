# Fontz complete Unicode variation sequence discovery

Base HEAD: `97127bc`; branch: `feat/uvs-font-discovery-20261125`.
Source write boundary: `/Users/bytedance/project-z/fontz-uvs-discovery-20261125`.
No commits, pushes, or agents were created. Iris/Lux and sibling source trees were not edited.

Public API: `Query.required_variation_selector: ?u21 = null` with the base in
`required_codepoint`; `Discovery.coversVariationSequence(path: []const u8,
face_index: u32, base: u21, selector: u21) !bool`.
VS1-16 (`FE00..FE0F`) and supplementary IVS (`E0100..E01EF`) are accepted.
Invalid scalar/selector or missing base returns an empty resolution before catalog
or font-file IO. Unsupported sequences resolve empty; nominal fallback is an explicit
new query with a null selector.

Format 14 eligibility validates default and nondefault lists, malformed offsets,
row ordering, Unicode ranges, disjoint lists, and nonzero glyph IDs below maxp's
numGlyphs. Default mappings additionally require a nominal glyph inside its own
subtable and glyph-count bounds; nondefault mappings need no nominal base.
The coverage cache shares cmap bytes across scalar/base/selector queries and TTC
faces retain their exact indexes. maxp metadata is lazy after scalar prewarming.
The unfiltered metadata-only findFace API rejects sequence constraints; discovery
uses the explicit coverage filter.

Receipts preserve the real red: 18/21 passed, 3 expected failures selecting nominal
instead of nondefault-only/named TTC faces and falsely accepting an unsupported
selector. Final gates and exported package report enumerate executed named tests.
The frozen source record covers all Zig source/tests, build files, README, and the
package verifier; logs/reports are excluded from that source-set digest to avoid
self-referential hashes. Export verification must match every frozen source hash.
Native compiles use the shared guard with -j1; available disk remained above 50 GiB.

Final exported gates: 28/28 matching (26 named), 17/17 sequence (14 named), 1/1 published API. Legacy scalar cmap controls: 4/4 named tests passed using a transient explicit comptime-import root; the root was removed. Source audit: all 38 frozen source files match current and exported hashes.
