# Unicode format2, format8, and format10 discovery

Fontz supports Unicode cmap2/8/10 through raw mapping, font-file eligibility,
retained coverage, and catalog discovery. Query and Discovery APIs are unchanged.
The implementation uses separate numeric readers, a shared selection module, and
an explicit policy module; format12/13 retained plans remain intact.

## Record identity and default selection

New Unicode proof accepts only platform0 encodings0/1/2 for all three formats,
and encoding4 for format8/10. Encoding3 excludes these formats; encoding5/6 keep
their format14/13 roles. Unknown Unicode encodings and Windows codepage, Macintosh,
ISO, and custom platform records do not provide new Unicode proof. Rejected new
records are skipped without invalidating registered siblings.

The presence of any standard eligible format2/8/10 record switches the complete
nominal candidate set to the consuming Cangjie Face's default priority:

| Mapping | Priority |
| --- | ---: |
| Windows Unicode format12 | 8 |
| Unicode format12 | 7 |
| Unicode encoding4 format8 | 6 |
| Windows Unicode BMP format4 | 5 |
| Unicode format4 | 4 |
| Registered format13 and Unicode encoding4 format10 | 2 |
| Unicode format2/6 and format0 | 1 |
| Deprecated Unicode format8/10 and other compatible low-priority records | 0 |

The first record wins equal priorities, including an initial zero-priority
candidate. A zero glyph or malformed selected body does not fall through to a
lower-priority sibling. This prevents format10+BMP4 and deprecated-format8+BMP4
from claiming a mapping that the installed Face's default charmap will not use.
Without an eligible new record, original Fontz priorities, record-order ties,
nominal quirks, and format12/13 plans remain unchanged.

## Full new-context qualification

A font file containing any standard eligible new record must provide a valid,
nonzero maxp.numGlyphs. Every eligible new subtable is validated, including
lower-priority tables that were not selected. Each complete new mapping domain
must fit within that glyph set. No old BMP mapping or valid nondefault format14
mapping can bypass a malformed new table that the consuming Face would reject.

The retained entry stores the complete context proof and loaded glyph count.
Scalar, default-UVS, and nondefault-UVS queries reuse that proof. Warm queries add
no file IO, allocations, or repeated whole-subtable validation. Disabled or
oversized caches query the same eligibility rules without retaining a proof.
Actual IO and allocation errors remain retryable; structural negatives remain
stable until the cache/index epoch changes. TTC indexes and named-instance
identities continue through the existing metadata path.

A raw `tableCovers` query has only cmap bytes. It checks complete new grammar and
the representable u16 glyph domain, but cannot claim qualification against maxp.
`tableCoversBounded` checks complete new domains against an explicit glyph count;
file/cache/discovery paths obtain that count from the actual font. Raw glyph65535
is representable, while bounded qualification rejects it when numGlyphs=65535.

## Numeric format contracts

Format2 uses u16 declared length and language0. All 256 keys must be eight-byte
aligned and the entire referenced SubHeader array must exist. Nonempty ranges
must fit the low-byte domain and their glyph addresses must lie after the
SubHeaders and inside the declared subtable. Unicode ranges are checked for each
actual referencing high byte. All SubHeaders up to maxIndex receive grammar and
GID checks, even if an individual header is unreferenced. Empty headers have no
addressable range and keep their legacy firstCode/delta/offset freedom.
Key0 need not equal0; nonzero high bytes with key0 are unmapped. Raw glyph0 remains
missing without delta application; nonzero glyphs use signed u16 wrapping delta.
A wrapped result0 is missing.

Format8 requires the complete 8192-byte is32 bitmap, reserved0/language0, u32
length, an exact group-array body, sorted/disjoint Unicode scalar ranges, and
checked sequential glyph arithmetic. Groups contain Unicode scalars, not packed
UTF16 surrogate pairs. Mapped BMP words require is32=0; supplementary ranges
require is32[scalar>>16]=1 for every involved high word. Unused bitmap bits are
permitted. The whole group glyph extent must fit the raw u16 domain or the bounded
maxp domain.

Format10 uses reserved0/language0 and u32 length. numChars*2 must exactly match the
trimmed glyph array. The start must be a scalar even for an empty array. Nonempty
endpoints use widened arithmetic, remain at most10FFFF, and never cross the
surrogate interval. Truncation, extra array bytes, overflow, and any out-of-range
GID fail qualification. Glyph0 is missing.

Default format14 sequences require a valid nonzero nominal glyph and the complete
new-context proof. Extended nominal format8/10 lengths use u32 at offset4, not the
reserved word. Format14-only nondefault sequences preserve their existing
independence from a missing nominal base. If new eligible tables exist, all
sequence paths first require their full context qualification.

Old format0/4/6/12/13 scalar eligibility does not automatically read maxp when no
new context exists. The old cold control remains1 open/4 reads/128 bytes; newly
qualified SFNT fixtures add the single maxp read, with TTC adding its existing
face-offset read. This batch does not extend outlines or shaping parsers.

## Verification and publication

`test-unicode-cmap` is the explicit owner root for the new named grammar,
qualification, cache, and actual discovery fixtures. The package verifier's
`--unicode-cmap-tests` option counts every declared named test in exported source
and checks the observed execution total, preventing zero-test/declaration-only
successes. CI runs this owner with the existing matching, variation, and prepared
owners. Fixtures use Unicode records and independent byte builders; Windows
codepage format2 is a negative control.

Local native execution is coordinated under the shared Zig guard. Reports, logs,
and final publication audits are written outside the published paths, in /tmp.
The final audit compares the complete export path set and literal bytes with the
frozen source, including documentation, without putting a package report inside
its own published package.
