# fontz

Unified system-font discovery for Project-Z.

`fontz` answers one question: **which installed face should be used for this
descriptor?** It returns a path, collection face index, and PostScript identity.
It does not parse outlines, shape text, or rasterize glyphs. Those remain in
Cangjie and Iris.

## Backends

- Linux: runtime-loaded fontconfig (`libfontconfig.so.1`), with deterministic
  path fallbacks when fontconfig is unavailable.
- macOS: CoreText.
- Windows: DirectWrite.
- Other targets: deterministic fallback path candidates.
- `metadata_index`: opt-in bounded scan of platform font roots that reads only
  sfnt headers plus `name`/`OS/2` tables. Useful for family pickers and for
  callers that cannot use the native provider.

## API

```zig
const fontz = @import("fontz");

var discovery = fontz.Discovery.init(allocator);
defer discovery.deinit();

var resolution = try discovery.resolveQuery(allocator, .{
    .family = "Noto Sans",
    .weight = 500,
    .language = "ja-JP",
});
defer resolution.deinit();

for (resolution.candidates) |candidate| {
    // candidate.path, candidate.face_index, candidate.postscript_name
}
```

The runtime-injectable contract is `fontz.Service`:

```zig
var service = discovery.service();
var resolution = try service.resolve(allocator, query);
defer resolution.deinit();
```

`Service` also exposes `allFamilyNames`, `prewarm`, `setMissingGlyphSink`, and
`generation`. The native providers currently implement resolution and the
missing-glyph sink; full inventory enumeration is provider-specific and may be
added without changing the contract.

## Missing glyphs

`Discovery.reportMissingGlyph` forwards an unresolved cluster to the installed
`MissingGlyphSink`. A host can use that callback to resolve/install a system
face and retry shaping in Cangjie.

## Boundary

`fontz` must not depend on Cangjie, Zui, Zsvg, Pdfz, or Iris. Consumers install
the returned faces into their own font database or renderer. Cangjie remains
the only font parser/shaping engine.

## Tests

```sh
zig build test
```

Platform provider tests run only on their native target; unsupported targets
use the fallback-path provider.
