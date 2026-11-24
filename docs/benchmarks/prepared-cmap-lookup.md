# Prepared retained scalar cmap lookup

The coverage cache now retains an inline plan for its chosen format12/13
subtable. It validates `start <= end` and strictly sorted, disjoint ranges once,
then searches the existing owned table bytes by binary search. It does not copy
groups or add warm allocations/IO. Unsorted, overlapping, reversed, unsupported,
and structurally incomplete tables use the historical linear lookup.

Nominal compatibility includes ignored declared subtable lengths, zero glyph
handling, the first matching overlapping group, format13 constant glyphs, and
format12 max-u32 glyph success at the group's first codepoint followed by overflow
failure. UVS/default eligibility continues using its separate strict nominal
path. A UVS-first entry prepares its scalar plan lazily on the first scalar query;
maxp loading remains independently lazy.

## Verification

The actual 32768-group red measured first/middle/tail/gap/miss group visits of
`1 / 16385 / 32768 / 32768 / 32768`; the retained ordered plan measures
`16 / 1 / 15 / 15 / 15`. Opt-in work counters use a separate comptime specialization;
normal production cache lookups contain no counter branches.

`test-prepared-cmap` executes eight named tests plus one imported declaration
check. They cover ordered and malformed lookup equivalence, glyph arithmetic,
length/record corruption, warm work, LRU/limits/disabled/oversized caches,
allocation failure/retry, epochs/TTC indexes, and UVS/maxp separation.
`test-coverage-matching` and `test-variation-sequences` retain their 28 and 17
checks, including the 1-open/4-read/128-byte cold scalar control.

## Matched measurements

Baseline is `a3e3bf0573fb5ec46904525d2121a615007d7110` with tracked product files
unchanged. Both worktrees use the identical `src/cmap_bench.zig` driver and
`tools/run_cmap_abba.py`; driver SHA256:
`ce3ee96089e7abbd981013678d79b048b7071d6c2d43d3d3dc91e83d37bd9512`.
Both binaries use ReleaseFast. The entire A/B/B/A Python parent holds one shared
Zig-tree-guard slot; its children run directly within that slot. The 20 recorded
samples contain two A and two B samples for each of five workloads. macOS has no
`taskset`, so affinity is recorded as unavailable; no fixed-core result is claimed.

Timed calls use the existing public `Cache.coversCodepoint` production
specialization, after cache warmup, with 131072 queries per sample and consumed,
matched checksums. The synthetic set contains 12289 distinct scalars; the host
sets contain 8555-10339. The exact Query cache is not used. Counter probes and
standalone preparation timing occur outside the warm timing interval.

| Source | Groups | Baseline ns/query | Prepared ns/query | Baseline/prepared ratio |
| --- | ---: | ---: | ---: | ---: |
| Synthetic 12 | 32768 | 6948.62 | 51.93 | 133.80 |
| Synthetic 13 | 32768 | 6893.48 | 51.66 | 133.45 |
| PingFangHK-Regular | 31864 | 5700.12 | 49.32 | 115.57 |
| PingFangSC-Regular | 34466 | 6156.30 | 50.58 | 121.72 |
| PingFangTC-Regular | 31087 | 5546.51 | 49.34 | 112.42 |

These are same-host Fontz cached-linear versus prepared lookup measurements.
They do not compare shaping, complete discovery, rendering, or external frameworks.
Two samples per side are reported with raw values in the external artifact;
these averages do not establish a latency distribution.

## Cold and preparation costs

Cache-cold timing includes font reads, cache installation, initial scalar lookup,
and preparation. It is not cold-disk timing: metadata/table reads and the font
SHA verification occur before it on both sides. Standalone preparation is timed
separately; the baseline does not prepare a plan.

| Source | Baseline cache-cold us (A/A) | Prepared cache-cold us (B/B) | Standalone preparation us (B/B) |
| --- | --- | --- | --- |
| Synthetic 12 | 110.79, 91.29 | 101.50, 91.25 | 8.88, 9.04 |
| Synthetic 13 | 70.12, 70.38 | 82.33, 84.75 | 11.42, 11.46 |
| PingFangHK-Regular | 97.46, 95.54 | 95.25, 102.75 | 8.79, 8.67 |
| PingFangSC-Regular | 156.12, 106.00 | 121.67, 125.71 | 16.50, 9.38 |
| PingFangTC-Regular | 118.92, 89.79 | 104.54, 97.92 | 11.00, 8.71 |

Every warm sample records zero additional opens, reads, and allocations. Cold
allocation count remains three. Entry size grows from 56 to 64 bytes: the default
64-entry backing array adds 512 bytes. Retained cmap/path byte accounting is
unchanged, with no group copy and no additional warm storage.

The host inputs come from CoreText font URLs and exact PostScript names, matched
independently against SFNT names and original fvar ordinals. The current driver
verifies each file SHA and group count before measuring. PingFangUI SC/TC/HK use
original TTC faces 20/21/22, each named instance 1. Font file SHA256 is
`13b201d63324db59de86956c11c46d1f0ad9ac0aeaa0b9d035c012a794062db7`
(61080840 bytes). No host font path is hardcoded in production code.

## Reproduce

Build matched binaries from each worktree's identical driver:

```sh
zig build-exe src/cmap_bench.zig -O ReleaseFast -femit-bin=/tmp/cmap-bench-A -j1
```

Use distinct A/B executable names and invoke the runner under one shared tree
guard with `--baseline`, `--after`, `--baseline-repo`, `--after-repo`, and an
external `--report` path. `--host-proof` accepts the metadata proof JSON;
without it the mandatory synthetic format12/13 workloads run. `bench-cmap`
also builds the package's benchmark executable. Reports/logs remain outside
published paths so final package identity does not include a report of itself.

This run's authoritative artifacts are `/tmp/fontz-cmap-abba-20261125.json` and
`/tmp/fontz-cmap-abba-20261125.log`. The earlier per-child-guard run is quarantined
under the `-partial-per-child-guard` suffix and is excluded from these results.
