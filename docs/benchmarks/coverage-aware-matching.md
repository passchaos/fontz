# Coverage-aware catalog matching qualification

Qualified on 2026-11-25 in `fontz-coverage-fallback-20261125`, branch
`fix/coverage-fallback-20261125`, base `84c99cc`, with Zig 0.16.0 Debug on macOS
ARM64. All compiler invocations used the shared Zig tree guard; build gates
used `-j1`.

Previously, the pure provider picked one metadata face and then checked cmap.
A missing glyph discarded that face and proceeded to platform paths, skipping
covered sibling faces and later authored/generic families in the catalog.
The new read-lease matcher first checks the CSS best face, then filters the
remaining family before CSS ranking if that face misses. It continues through
the full authored stack and then considers script hints. Exact PostScript
queries check only their named face. Cmap and query
cache ownership remain separate from catalog snapshots.

CSS ranking now initializes the first opsz candidate even when its score is
infinite. An all-static CSS-ranked set therefore remains selectable, and finite
range scores still take precedence. The same strict static-face and range
expectations run with and without a required codepoint.

## Deterministic reproduction and green gate

Fixtures use bounded synthetic cmap tables, explicit font roots, and TTCs with
malformed earlier faces. Assertions require the metadata provider, exact fixture
path and PostScript name, original collection index, and named-instance ID.
Installed LastResort or CJK fallback fonts cannot satisfy them.

| Reproduction | Red result | Final behavior |
| --- | --- | --- |
| Best weight misses, sibling covers | Platform fallback selected | Covered sibling selected at its own weight |
| First authored/generic family misses | Platform fallback selected | Next catalog family selected |
| Earlier TTC faces are invalid or miss coverage | Platform fallback selected | Original face index 3 and correct instance retained |
| Generic CJK mapping or later authored CJK family | Script hint discards user stack | User stack selected before script hints |
| All static faces, opsz request without codepoint | Zero candidates | First face at the matching CSS rank selected |
| CSS best face and sibling both cover the codepoint | Two physical cmap reads | Best face returns after 1 open, 4 reads, 128 bytes |

The final gate includes 16 named regressions plus two declaration checks:

```sh
zig build test-coverage-matching -j1 --summary all
```

It verifies CSS stretch/style/weight ordering after eligibility filtering,
optical-size ordering, exact PostScript negatives, no catalog match, unchanged
non-coverage choice, hot query references, refresh, reset during screening,
large eligibility-buffer cleanup, long-family allocation failures, and cmap
OOM retry. The original 15 named cases passed **17/17**, guard peak 265 MiB.
Adding the cold IO control produced **18/18 passed**, guard peak 268 MiB. The
fallback scan skips the already failed face; strict callback/cache-hit counts
also detect repeated acceptance checks.

## Existing owner checks

| Gate | Result | Guard peak |
| --- | ---: | ---: |
| `zig build test-concurrency -j1 --summary all` | 14/14 | 306 MiB |
| Pure provider, coverage cache/cmap, workload and retained resolutions | 11/11 | 244 MiB |
| CSS, opsz, localized families, fvar, TTC, PostScript and cache identities | 14/14 | 238 MiB |

The provider/coverage invocation was:

```sh
zig test src/pure_discovery.zig --test-filter coverage --test-filter 'pure provider'
```

The CSS/identity invocation was:

```sh
zig test src/metadata_index.zig --test-filter CSS --test-filter 'face selection' --test-filter opsz --test-filter fvar --test-filter 'metadata cache' --test-filter 'PostScript lookup' --test-filter 'TT collection' --test-filter 'localized family' --test-filter 'face location'
```

The query cache, coverage cache, snapshot helper, disk-cache records, and owned
candidate types are unchanged from base. Existing lifecycle checks still cover
lease epochs, cross-owner refresh, stale build rejection, concurrent temporary
writers, retained resolutions, and partial allocation cleanup.

## Allocation and IO control

The existing 128-descriptor exact-PostScript workload remains **96 positive /
32 negative**, with **1 successful font open, 4 positional reads, 128 bytes,
127 coverage-cache hits, and 1 coverage-cache miss**. All 128 descriptor queries
miss the exact query cache, so those counts come from cmap reuse.

Non-PostScript coverage matching may read additional physical faces while
screening a family; the sibling fixture asserts exactly two font opens. Tables
remain keyed by path and original TTC index, so named instances share proof.
The exact-query hit fixture blocks both owner and output allocators after
warmup, retains the same shared result, and asserts no additional opens/reads.
No timing speedup is inferred from these deterministic controls.

When two different physical fonts both cover the same codepoint, the cold
control asserts that the CSS best face alone incurs one open, four reads and
128 bytes. The first probe precedes allocation of a larger eligibility buffer,
so a successful best face avoids both sibling IO and fallback index storage.

## Published package verification

`tools/verify_package_export.py --coverage-matching-tests` invokes the literal
`test-coverage-matching` build step from the fetched/exported package with
isolated caches and `-j1`. It checks the actual passed/total summary against all
named matching tests declared in the exported source plus its two unnamed
declaration checks. A graph running only the unnamed checks is rejected.
The JSON report retains package identity, published file hashes and the named
test list/counts under `gate_results.catalog-coverage-matching`.

The Linux/macOS package workflow enables this gate alongside configure,
metadata, declaration and concurrency verification. Local qualification wraps
`/usr/bin/python3` and the explicit raw Zig executable in one parent guard.
Its external JSON report and complete command output are retained separately
so recording the package hash does not change the shipped package contents.

## Retained logs

All gate output remains under `/tmp`:

- `fontz-coverage-matching-red-20261125.log`: initial four strict failures.
- `fontz-coverage-matching-green-v1-20261125.log`: initial six-case gate.
- `fontz-coverage-matching-green-v2-20261125.log`: expanded fifteen-case gate.
- `fontz-coverage-matching-cjk-red-20261125.log`: both CJK stack failures.
- `fontz-static-opsz-red-20261125.log`: static opsz failure without a codepoint.
- `fontz-coverage-matching-green-final-20261125.log`: final 17/17 gate.
- `fontz-coverage-owner-concurrency-20261125.log`: existing 14/14 lifecycle gate.
- `fontz-coverage-owner-provider-20261125.log`: existing 11/11 coverage gate.
- `fontz-coverage-owner-css-identity-20261125.log`: existing 14/14 CSS/identity gate.
- `fontz-coverage-cold-io-red-20261125.log`: best face covered but two fonts opened.
- `fontz-coverage-cold-io-green-20261125.log`: final 18/18 cold IO gate.
- `fontz-package-matching-counter-check-20261125.log`: incomplete-count rejection checks.
- `fontz-package-matching-verifier-help-20261125.log`: exported matching CLI option.
- `fontz-package-coverage-matching-export-20261125.log`: real exported-package gate output.
- `fontz-package-coverage-matching-export-20261125.json`: package identity, file hashes and test counts.
