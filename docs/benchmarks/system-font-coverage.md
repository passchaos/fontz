# System-font coverage table reuse

`pure_discovery.resolveUncached` previously called `cmap.coversCodepoint` on
every exact-query cache miss. The query cache includes family, PostScript name,
codepoint, weight, style, stretch, optical size, language, and candidate limit,
so different descriptors for one face repeatedly opened its font and read the
sfnt/TTC directory plus the whole cmap. The process-wide metadata index stores
face metadata and intentionally does not read cmap.

The provider now keeps a separate LRU keyed by owned path and TTC face index.
It retains up to 64 entries and 16 MiB of cmap and path bytes per `Discovery`.
The existing reader cap remains 16 MiB per table; a miss can temporarily hold
that much additional table data alongside retained cache data. Entry storage
is a fixed maximum of 64 records. A table or path that cannot fit the retained
budget still produces the same coverage result and is freed after querying.
Cache hits do no font-file IO. The outer public fallback path uses this cache
too, including structural negatives already checked by the provider.

Generation changes drop all table entries, and `refresh` also clears them
explicitly. The caller must refresh/reset after font-file changes, matching
the metadata/query cache snapshot contract. Malformed or missing cmap tables
are structural negatives. IO and table-allocation errors are retried instead
of cached. Failed key/entry allocation leaves the successful coverage result
intact. No cached table pointers are returned through `Resolution`.

Run the smallest deterministic verification from the Fontz repository:

```sh
zig test src/root.zig --test-filter coverage --test-filter cmap
```

`coverage workload reuses font IO across 128 distinct descriptors` builds a
synthetic face covering A–Z. It executes 128 descriptors with different weights,
alternating languages, and covered/uncovered codepoints. PostScript selection
keeps the workload independent of installed fallback fonts. Its independently
known outcomes are 96 positive and 32 negative resolutions. For each descriptor
it also executes the former table-read path and compares its coverage with the
fixture's expected result. Production reader counters record actual successful
opens, positional read calls, and bytes returned, rather than an estimate.

Measured on 2026-11-24 with Zig 0.16.0 on macOS ARM64 in the default Debug
configuration. The command above passed all 15 selected tests; the guarded
compiler tree peaked at 261 MiB. The workload reported:

| Font-file work | Former per-query load | Coverage cache |
| --- | ---: | ---: |
| Successful opens | 128 | 1 |
| Positional read calls | 512 | 4 |
| Bytes read | 16,384 | 128 |
| Coverage cache hits | — | 127 |
| Coverage cache misses | — | 1 |
| Positive / negative results | 96 / 32 | 96 / 32 |

All 128 descriptor queries missed the exact-query cache, so its reuse did not
contribute to this reduction. Font opens, reader calls, and bytes each fell by
99.2%. These counts isolate coverage work after metadata prewarm and do not
claim a wall-clock speedup or a reduction in the initial metadata scan.

The focused suite also verifies distinct TTC faces (formats 12 and 13), invalid
face indexes, structural negatives, IO retry, LRU eviction, total-byte eviction,
uncached oversized tables, allocation failures, generation invalidation, named
instance sharing, and retained Resolution lifetime across eviction, refresh,
and Discovery destruction. Malformed cmap offsets and glyph arithmetic fail
closed without integer overflow.
