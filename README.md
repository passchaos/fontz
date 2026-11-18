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
  matching and family listings.
- `metadata/fontconfig`: pure-Zig reader for fontconfig XML configuration
  (`<dir>`, `<include>`, `<alias>`), including XDG and `~` prefixes. Used on
  Linux to discover configured font directories and generic-family aliases.
- `metadata/cmap`: minimal pure-Zig `cmap` coverage reader (formats 0, 4, 6,
  12, 13) used to verify `required_codepoint`.
- `fallback_paths`: deterministic path candidates for roles, generic families,
  scripts and CJK TTC face indexes.
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

const index = try fontz.metadata_index.findFaceIndexByPostScript(
    io,
    face.?.path,
    "MPLUS1p-Regular",
);
```

The process-wide index is bounded by file/face/table budgets and is built
outside its global mutex. Call `metadata_index.reset(io)` to change roots or
budgets; do not hold `Face` pointers across it.

## Boundary

`fontz` must not depend on Cangjie, Zui, Zsvg, Pdfz, or Iris. Consumers install
the returned faces into their own font database or renderer. Cangjie remains
the only font parser/shaping engine.

See [docs/architecture.md](docs/architecture.md) for matching rules, fallback
semantics, coverage checks, and ecosystem boundaries.

## Tests

```sh
zig build test    # pure Zig, no libc or native font libraries
zig build check   # cross-compile the pure provider for Windows and macOS
```
 cross-compile the pure provider for Windows and macOS
```
