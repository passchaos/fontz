# fontz

Unified system-font discovery for Project-Z.

`fontz` answers one question: **which installed face should be used for this
descriptor?** It returns a path, collection face index, PostScript identity and
advisory face attributes. It does not parse outlines, shape text, or rasterize
glyphs. Those remain in Cangjie and Iris.

## Backends

`fontz` is pure Zig. It does not link fontconfig, CoreText, DirectWrite, or
libc.

- `metadata_index`: bounded scan of platform font roots. Reads sfnt headers plus
  `name`/`OS/2`/`post`/`fvar` tables and keeps localized family names,
  PostScript/full names, weight, CSS stretch, style and monospaced metadata.
  Variable fonts contribute one matchable entry per `fvar` named instance;
  `Candidate.named_instance` is `0` for the default instance and `N` for the
  zero-based instance `N - 1`. Dot-prefixed families are treated as hidden
  CoreText-style aliases: addressable by PostScript name, excluded from family
  matching and family listings. A versioned metadata cache lives under the
  platform cache directory (`~/Library/Caches/fontz/metadata-v1.bin` on macOS)
  and is validated against the root list plus every font file's path, size, and
  mtime; writes are atomic and any mismatch falls back to a full scan. The
  on-disk format is version 3: older caches are rejected because they may
  contain TTC indexes renumbered after a malformed face was skipped.
- `metadata/fontconfig`: pure-Zig reader for fontconfig XML configuration
  (`<dir>`, `<include>`, `<alias>`), including XDG and `~` prefixes. Used on
  Linux to discover configured font directories and generic-family aliases.
- `metadata/cmap`: minimal pure-Zig `cmap` coverage reader (formats 0, 4, 6,
  12, 13) used to verify `required_codepoint`.
- `metadata/coverage_cache`: per-discovery LRU of owned cmap tables keyed by
  absolute path and TTC face index. Different descriptors, named instances,
  and codepoints reuse the table without reopening the font. It retains at
  most 64 entries and 16 MiB of table/path bytes. Tables that exceed the cache
  budget are queried and freed. The reader keeps its existing 16 MiB single
  table cap; one miss can temporarily use another 16 MiB while loading.
- `fallback_paths`: deterministic path candidates for roles, generic families,
  scripts and CJK TTC face indexes. Codepoint-driven fallback verifies `cmap`
  coverage before returning a candidate and prefers native macOS faces
  (Lucida Grande, SF Arabic/Geeza Pro, Thonburi, Kohinoor, PingFang,
  Hiragino, Apple SD Gothic Neo, Noto Sans Armenian, Apple Color Emoji).
- `pure_discovery`: combines the above into `Discovery`, with CSS-like family
  matching, platform generic mappings, query caching and reference-counted
  resolutions.

## API

```zig
const fontz = @import("fontz");

var discovery = fontz.Discovery.init(allocator);
defer discovery.deinit();

var resolution = try discovery.resolveQuery(allocator, .{
    // A CSS font-family list, not a single name.
    .family = "\"Noto Sans\", sans-serif",
    .weight = 500,
    .stretch = 100, // CSS percentage
    .language = "ja-JP",
});
defer resolution.deinit();

for (resolution.candidates) |candidate| {
    // candidate.path, candidate.face_index, candidate.postscript_name
    // candidate.family, candidate.weight, candidate.stretch,
    // candidate.style, candidate.monospaced
}
```

`Query.family` is a CSS family list. Generic families (`serif`,
`sans-serif`, `monospace`, `cursive`, `fantasy`, `system-ui`, `ui-serif`,
`ui-sans-serif`, `ui-monospace`, `ui-emoji`, `ui-rounded`, `emoji`, `math`)
are mapped through platform defaults and fontconfig aliases. `weight` is
1..1000, `stretch` is a CSS percentage (100 is normal), and
`required_codepoint` must be a Unicode scalar.

Set `required_variation_selector` with `required_codepoint` as the base to
require a complete Unicode variation sequence. Valid selectors are VS1–16
(`FE00..FE0F`) and supplementary IVS (`E0100..E01EF`). Discovery checks cmap
format 14: default sequences require a valid nominal glyph, and nondefault
sequences can select a face whose nominal cmap lacks the base. Invalid queries
return no candidates without catalog or font-file IO. Unsupported sequences
also return no candidates; a consumer that wants nominal fallback must issue
a separate query with `required_variation_selector = null`.

`Discovery.coversVariationSequence(path, face_index, base, selector)` proves
sequence support for an exact face. Coverage tables are shared with scalar
queries; glyph-count metadata is loaded only when sequence validation needs
it. `zig build test-coverage-matching test-variation-sequences test-variation-api
-j1` runs the focused catalog, cmap14/cache/fallback, and published API gates.
The package export verifier supports `--variation-sequence-tests` and verifies
that each exported gate executes all its declared named tests.

The runtime-injectable contract is `fontz.Service`:

```zig
var service = discovery.service();
var resolution = try service.resolve(allocator, query);
defer resolution.deinit();
```

`Service` also exposes `allFamilyNames`, `prewarm`, `setMissingGlyphSink`, and
`generation`. `allFamilyNames` returns owned strings; release them with
`fontz.freeFamilyNames`:

```zig
const names = try discovery.allFamilyNames(allocator);
defer fontz.freeFamilyNames(allocator, names);
```

Resolutions returned by the provider cache are reference-counted: cache hits
retain the cached candidates instead of cloning every string. `deinit` always
releases the caller's reference.

Operations on one `Discovery` serialize with refresh, including prewarm and
family enumeration. Each catalog reader holds an immutable snapshot until its
face metadata has been copied. Reset detaches the global snapshot immediately;
the final reader frees it. A miss that overlaps reset retains its actual catalog
epoch, so the next query rebuilds. Exact cache hits remain allocation and IO
free. Retained resolutions survive refresh/reset and owner destruction, and
their independent references may be released from different threads.

Join all operations before `Discovery.deinit`. An allocator shared by separate
discovery owners must support concurrent use or be serialized by the caller;
keep it alive until the last retained resolution is released.

Coverage storage has an independent lifetime: clearing or evicting a cmap
table cannot invalidate a retained `Resolution`. `refresh` clears both caches;
an external `metadata_index.reset` invalidates them through the index
generation. Font files are treated as an index snapshot until that refresh or
reset. Malformed/missing cmap tables cache a structural negative within the
snapshot; IO and table-allocation failures remain retryable. Cache-installation
allocation failures preserve the successfully computed coverage result.

With `required_codepoint`, catalog matching first checks the CSS best face for
coverage. If it misses, matching screens the remaining family faces and applies
CSS stretch, style, weight, and optical-size ranking to the covered set.
If no face covers the codepoint, it continues through the authored
family list or generic mapping's next concrete family, including fonts in
user-supplied roots. A PostScript query checks only its exact face. Queries
without a codepoint keep their existing metadata-only choice. The provider
still chooses one best catalog face; `max_candidates` semantics are unchanged.
Script hints are tried after the authored stack, so CJK hints cannot replace
user generic mappings or a later authored family. If a CSS-matched set has no
optical-size metadata, an `opsz` request retains its first face; faces with
optical-size ranges continue to rank ahead of static faces.

When the best face covers the codepoint, only its cmap is read. Otherwise,
coverage matching can read additional cmap tables on a first miss, and reuses
the existing table cache across later descriptors and named instances. Catalog
screening and candidate copies retain the same read lease and epoch. Allocation
failures during screening propagate as `OutOfMemory`, allowing a later query to
retry without a cached negative. Exact query hits remain allocation and IO free.

`Discovery.stats()` includes cumulative `coverage_cache_hits`,
`coverage_cache_misses`, `coverage_file_opens`, `coverage_read_calls`, and
`coverage_bytes_read`, plus current `coverage_cache_entries` and
`coverage_cache_bytes`. These file counts describe coverage loading, separately
from metadata indexing. The [counted IO workload](docs/benchmarks/system-font-coverage.md)
compares 128 distinct descriptors with the former per-query reads.

## Missing glyphs

`Discovery.reportMissingGlyph` forwards an unresolved cluster to the installed
`MissingGlyphSink`. `MissingGlyph` includes an advisory `FallbackFontClass`
(proportional or monospace) and the discovery generation at report time, so a
host can resolve/install a system face, drop stale reports, and retry shaping
in Cangjie.

## Metadata index

`metadata_index` supports family and PostScript lookup, localized family names,
family-name enumeration, user font directories, symlinked font files, and TTC
face index resolution:

```zig
const face = fontz.metadata_index.findFace(
    io,
    .{ .family = "\"M PLUS 1p\", sans-serif", .weight = 400 },
    .{},
);

const location = try fontz.metadata_index.findFaceLocationByPostScript(
    io,
    face.?.path,
    "MPLUS1p-Regular",
);
// location.?.face_index is the original sfnt/TTC index.
// location.?.named_instance is 0 for the default, or fvar record index + 1.
```

The direct path + PostScript helper checks both the face's base PostScript name
and its `fvar` named instances. For a variable face whose base name is Medium,
a Regular instance resolves to the same collection face with its own
`named_instance`. Names use the same ASCII case-insensitive comparison as the
catalog; a duplicate base/instance name selects the default face first. The
returned `FaceLocation` is an owned value with no borrowed font bytes.

The legacy `findFaceIndexByPostScript` delegates to this helper and returns
only `face_index`. When earlier or interior TTC faces have invalid metadata,
they are skipped without renumbering surviving faces. Catalog matches, direct
PostScript locations and the version-3 disk cache preserve those original
indexes.

The process-wide index is bounded by file/face/table budgets and is built
outside its global mutex, with cold builds serialized separately. Call
`metadata_index.reset(io)` to change roots or budgets; the first successful
build after reset fixes the process-wide `Options`. Raw borrowed `Face` APIs
require callers to quiesce reset while using their pointers. Direct readers
that need to overlap reset can use `metadata_index.acquireRead(io, options)`
and keep its `ReadLease` alive through lookup/copying.

`zig build test-concurrency` runs the deterministic native lifecycle, epoch,
exclusive-cache-writer, retained-resolution, and allocation-failure regressions.

`zig build test-coverage-matching` runs synthetic cmap/TTC regressions for
covering sibling faces, subsequent families/generic mappings, CSS ranking,
PostScript identity, lease epochs, refresh, allocation failures, and query hits.
The [qualification record](docs/benchmarks/coverage-aware-matching.md) includes
strict red/green evidence, owner checks, and allocation/IO controls.

## Boundary

`fontz` must not depend on Cangjie, Zui, Zsvg, Pdfz, or Iris. Consumers install
the returned faces into their own font database or renderer. Cangjie remains
the only font parser/shaping engine.

See [docs/architecture.md](docs/architecture.md) for matching rules, fallback
semantics, coverage checks, and ecosystem boundaries.

## Tests

```sh
zig build test    # pure provider tests plus CoreText oracle on macOS
zig build check   # cross-compile the pure provider for Windows and macOS
```

The published package includes `tests/` so macOS consumers can run
`zig build test-macos-coretext` after `zig fetch`. CoreText/CoreFoundation are
linked only by this native differential test; the production provider remains
pure Zig and links no native font libraries.

Verify the actual exported archive and its literal build inputs:

```sh
python3 tools/verify_package_export.py --report zig-out/package-export.json
```

Optional `--configure --metadata-tests --check --concurrency-tests
--coverage-matching-tests` runs the focused package gates from the exported tree
with isolated caches. Matching verification checks the actual execution count
against the exported named tests and includes those counts in the JSON report.
`--macos-oracle` runs CoreText matching on macOS. The package workflow runs these
gates on Linux and macOS; a local success does not imply the hosted workflow has
already completed.

Retained scalar coverage now prepares ordered format12/13 groups once and uses
binary search over the owned cmap bytes. Malformed ordering retains historical
linear behavior; variation sequences keep their strict coverage path. Run
`zig build test-prepared-cmap test-coverage-matching test-variation-sequences -j1`
for the focused gates. See [the lookup measurements](docs/benchmarks/prepared-cmap-lookup.md)
for matched public-cache benchmarks, preparation costs, and resource accounting.
