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
zig test src/pure_discovery.zig --test-filter coverage --test-filter 'pure provider'
zig build test-coverage-matching -j1
```

`coverage workload reuses font IO across 128 distinct descriptors` builds a
synthetic face covering A–Z. It executes 128 descriptors with different weights,
alternating languages, and covered/uncovered codepoints. PostScript selection
keeps the workload independent of installed fallback fonts. Its independently
known outcomes are 96 positive and 32 negative resolutions. For each descriptor
it also executes the former table-read path and compares its coverage with the
fixture's expected result. Production reader counters record actual successful
opens, positional read calls, and bytes returned, rather than an estimate.

The prior cache-reuse qualification was measured on 2026-11-24 with Zig 0.16.0
on macOS ARM64 in the default Debug configuration. Its recorded gate passed
15 selected tests; the guarded compiler tree peaked at 261 MiB. The workload
reported:

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

Coverage-aware catalog selection first proves the CSS best face. If it misses,
the selector screens the remaining family and applies CSS ranking, continuing
to later authored/generic families if needed. This can load more than one
physical face's cmap on a first query miss; the synthetic sibling regression
reads two fonts to find the covering sibling. When both physical fonts cover
the codepoint, the cold control reads only the best face: 1 open, 4 reads,
128 bytes.
Named instances still share coverage by path and original TTC face index.
The 128-descriptor workload uses exact PostScript selection and therefore
continues to check one physical face per query. The new query-hit regression
blocks both owner and output allocators after warmup, retains the same shared
candidate block, and performs no additional font IO. These are deterministic
allocation/IO checks, not a timing speedup claim.

The 2026-11-25 coverage-aware matching qualification reran the provider/coverage
gate (11/11) and recorded the same workload counts above. Its separate matching
gate initially passed 17/17, then 18/18 with the cold IO control. See
[the qualification record](coverage-aware-matching.md)
for commands and retained logs.
