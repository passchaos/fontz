# Concurrent font catalog snapshots

Fontz now pins an immutable catalog snapshot while copying selected face or
family data. A reset detaches the global reference and advances its epoch;
readers release their own lease before the retired arena is destroyed.
Provider operations serialize roots, mappings and allocator access through
the owner mutex. Cache hits retain existing resolution storage, while misses
and coverage use the epoch of the snapshot actually read.

Cold builders serialize outside the index mutex and reject results started
before reset. Accepted publication owns cache-origin diagnostics. Disk-cache
writers use their own exclusive temporary file, close it before rename and
clean up only their own temporary path. The version-3 record format is unchanged.

Raw borrowed Face pointers still require reset quiescence. Discovery destruction
requires callers to join active operations; returned owned resolutions and
family-name arrays may outlive their discovery.

## Scoped qualification

On macOS ARM64 with Zig 0.16.0, the actual dedicated concurrency root passed
14/14 tests (12 named concurrency/OOM cases plus two imported tests). Provider
and coverage checks passed 6/6; named-instance/cache checks passed 7/7. Synthetic
generic mappings and exact PostScript requests keep fixtures independent of
installed fallback fonts. The coverage workload remains 1 open, 4 reads, 128 bytes
and 127 hits for 128 descriptors.

The first gate definition selected only two unnamed root tests. Qualification
uses the corrected dedicated root `src/concurrency_tests.zig`; default
`zig build test` includes it too.

## Hot-query control

The benchmark uses 400,000 PingFangSC-Regular queries per round, three rounds
per invocation, shared candidate pointer identity, no misses and an allocator
configured to fail its next allocation after warmup. A/B/B/A control medians
were 10.193 ns/query before and 10.2755 ns/query after (ratio 1.0081), within the
control spread. There is no speed claim; lifetime safety preserves zero hot
allocations and the same candidate block.

Session evidence: `/tmp/fontz-query-abba-20261124.json`,
`/tmp/fontz-concurrency-fixed-20261124.log`,
`/tmp/fontz-pure-coverage-snapshots-fixed-20261124.log`, and
`/tmp/fontz-named-cache-snapshots-20261124.log`.

The real package export verifier accepts `--concurrency-tests` and the package
workflow runs the dedicated gate from exported source with isolated caches.
