# fontz architecture

`fontz` answers one question: **which installed face should be used for this
descriptor?** It returns a path, collection face index, PostScript identity and
advisory face attributes. It does not parse outlines, shape text, or rasterize
glyphs. Those remain in Cangjie and Iris.

`fontz` is pure Zig. It does not link fontconfig, CoreText, DirectWrite, or
libc.

## Layers

| Layer | Responsibility |
|---|---|
| `types` | `Query`, `Candidate`, `Resolution`, `Service`, missing-glyph types |
| `family` | CSS family-list tokenization, generic-family classification, width-class conversion, UTF-8-aware family comparison |
| `metadata/index` | bounded sfnt catalog, CSS-like matching, family/PostScript indexes, process-wide cache |
| `metadata/parse` | sfnt `name`/`OS/2`/`post` parsing |
| `metadata/fontconfig` | pure-Zig fontconfig XML configuration reader (`<dir>`, `<include>`, `<alias>`) |
| `metadata/cmap` | minimal `cmap` coverage reader (formats 0, 4, 6, 12, 13) |
| `fallback_paths` | deterministic path candidates, including CJK face indexes |
| `pure_discovery` | combines the above into `Discovery`, platform generic mappings, query cache |
| `root` | public API, fallback chain, service vtable, prewarm, family-name enumeration |

## Query semantics

`Query.family` is a CSS `font-family` list, not a single name. The provider
walks the list in order. Generic names (`serif`, `sans-serif`, `monospace`,
`cursive`, `fantasy`, `system-ui`, `ui-serif`, `ui-sans-serif`,
`ui-monospace`, `ui-emoji`, `ui-rounded`, `emoji`, `math`) are classified by
`family.genericFamily` and resolved through fontconfig aliases plus platform
defaults.

Units:

- `weight`: OpenType/CSS weight, 1..1000, default 400.
- `stretch`: CSS font-stretch percentage, 100 is normal, default 100.
- `style`: `normal`, `italic` or `oblique`.
- `required_codepoint`: Unicode scalar value. The pure provider verifies it
  against the candidate's `cmap`.

Face selection follows the CSS Fonts Level 3 order: stretch, then style, then
weight. The metadata index implements this directly.

## Discovery

`pure_discovery.Discovery`:

- loads fontconfig configuration on Linux (empty on other targets);
- uses configured fontconfig directories when present, otherwise
  `metadata_index.defaultRoots` (platform roots + user fonts + macOS
  `AssetsV2` + Windows per-user fonts);
- builds generic-family mappings from fontconfig aliases, filling missing
  generics with platform defaults;
- resolves the family/PostScript query through `metadata_index.findFace`;
- verifies `required_codepoint` with `metadata/cmap`;
- appends deterministic `fallback_paths` candidates up to `max_candidates`;
- caches resolutions through the shared reference-counted query cache.

Platform defaults:

- Linux: DejaVu/Noto/Liberation families, Noto CJK, Noto Color Emoji,
  Latin Modern Math.
- macOS: Helvetica/SF, Times/New York, Menlo/Monaco, Apple Chancery, Papyrus,
  Apple Color Emoji, STIX.
- Windows: Segoe UI, Times New Roman/Georgia/Cambria, Cascadia/Consolas,
  Segoe Script, Impact, Segoe UI Emoji, Cambria Math.

CJK roles select the language-specific family (JP/KR/SC/TC/HK) before falling
back to script paths.

## Coverage

`metadata/cmap.coversCodepoint` opens the face file, finds the `cmap` table,
selects the best Unicode subtable (format 12/13 over 4 over 6/0), and checks
the codepoint. This keeps coverage queries correct without parsing outlines or
linking a font engine.

The metadata index itself still reads only `name`/`OS/2`/`post`; `cmap` is read
on demand for the selected candidate.

## Fallback chain

`Discovery.resolveRole` and `resolveQuery` first ask the pure provider. If it
returns no candidates, `fallback_paths` supplies deterministic candidates:

- role and generic-family lists for UI, monospace, serif, math, cursive,
  fantasy, emoji and symbol;
- script-specific Noto lists for Arabic, Hebrew, Thai, Devanagari, Bengali,
  Tamil, Telugu, Kannada, Malayalam, Gujarati, Gurmukhi, Sinhala, Khmer, Lao,
  Myanmar, Georgian, Armenian and Ethiopic;
- CJK candidates with the correct Noto CJK TTC face index:
  JP=0, KR=1, SC=2, TC=3, HK=4;
- bold/italic path variants where the platform ships them as separate files.

Candidates are filtered by file existence. Unknown concrete families return an
empty list, so a missing authored font is never silently replaced by a UI font.
An uncovered `required_codepoint` also returns empty.

## Metadata index

`metadata_index` reads only sfnt headers plus `name`, `OS/2` and `post`
tables. It never rasterizes and never installs a face.

It stores:

- all localized family names (typographic family preferred, legacy family as
  fallback);
- PostScript name, full name, subfamily;
- weight, CSS stretch, width class, style, italic and monospaced;
- path and TTC face index.

Matching uses a normalized family index and a PostScript index. Family
comparison is UTF-8 aware: ASCII separators are ignored and non-ASCII
codepoints are significant, so `宋体` never matches `黑体`.

The process-wide index:

- is built outside the global mutex;
- uses a persistent arena for decoded metadata and a per-file scratch arena for
  raw table bytes;
- is bounded by file, face, per-name-table and total metadata budgets;
- includes user font roots (`~/.local/share/fonts`, `~/.fonts`,
  `~/Library/Fonts`, Windows per-user fonts, macOS `AssetsV2` downloads);
- follows symlinked font files while walking roots;
- keeps `Options` fixed after the first successful build. Call `reset` to
  change roots or budgets; callers must not hold `Face` pointers across it.

`findFamily` keeps the historical width-class (1..9) parameter for
compatibility. New code should use `findFace` and pass a CSS `stretch`.

## Fontconfig configuration

`metadata/fontconfig` parses a subset of fontconfig XML:

- `FONTCONFIG_FILE`, `FONTCONFIG_PATH`, XDG `fontconfig/fonts.conf`,
  `/etc/fonts/local.conf`, `/etc/fonts/fonts.conf`;
- `<include>` with relative-path resolution and cycle protection;
- `<dir>` with `~`, `xdg` and `relative` prefixes;
- `<alias>` with `<prefer>`, `<accept>` and `<default>` family lists.

It intentionally does not implement fontconfig's full substitution engine,
binary cache, or hinting rules. Matching is handled by the metadata index.

## Resolution ownership

Provider query caches store reference-counted resolutions. A cache hit retains
the cached candidates instead of cloning every path/family/PostScript string.
`Resolution.deinit` releases one reference; the last release frees the
candidate block. Non-shared resolutions (fallback, tests, direct metadata-index
callers) keep the original owned semantics.

## Missing glyphs

`MissingGlyph` carries the unresolved cluster, optional language/script,
advisory `FallbackFontClass` (proportional or monospace), and the discovery
generation at report time. Hosts can drop stale reports after installing a
font. `Discovery.reportMissingGlyph` forwards the report to the installed
`MissingGlyphSink`.

## Ecosystem boundaries

- `fontz` must not depend on Cangjie, Zui, Zsvg, Pdfz, or Iris.
- Cangjie remains the only sfnt parser/shaping/fallback engine. fontz returns
  descriptors; Cangjie parses, installs and shapes them.
- Zui consumes `Discovery` for system UI/monospace/CJK/emoji/symbol roles and
  for on-demand family queries.
- Zsvg consumes `metadata_index` for authored concrete families and
  `Discovery` for coverage fallback.
- Cangjie's borrowed matcher uses the same CSS stretch -> style -> weight
  ordering so zui/zsvg verification and fontz discovery agree.
- Iris and Pdfz do not depend on fontz; they receive font bytes through
  Cangjie.

## Verification

```sh
zig build test    # pure Zig; no libc or native font libraries
zig build check   # cross-compile the pure provider for Windows and macOS
```

The cross-target `check` step emits objects only, so it works without a macOS
SDK or Windows runtime.

## Performance notes

Measured on a machine with 2636 installed font files:

- `metadata_index` warm scan: ~40 ms, cold disk ~1.3 s, peak RSS ~5 MB.
- The first query builds the index; later family lookups are hash-indexed.
- Reference-counted cache hits avoid candidate cloning entirely.
