# Default-root metadata cache and discovery startup

The persistent metadata index cache was unreachable for the default system-font
catalog. `metadata_index.resolveCachePath` disabled the cache whenever
`Options.roots` was non-null, because explicit roots were assumed to be
synthetic test/embedder roots. `pure_discovery.Discovery.init` always resolves
the platform/fontconfig root list explicitly, so every process (and every app
launch) rescanned the font directories, parsed every face, and hashed every
font file. The cold path showed up as SHA-256, CFF/PNG table parsing, and
directory-walk samples in a startup profile.

`Options` now has `default_roots: bool = false`. `Discovery.init` sets it to
true for the platform/fontconfig catalog; `Discovery.initWithRoots` keeps it
false so synthetic roots still cannot write into the user's real cache
directory. The cache remains keyed by the root list, every font file's path,
size, and mtime, and the limits hash, so a font or fontconfig change still
invalidates it.

## Measurement

`zig build bench-discovery` runs `Discovery.init` plus `prewarm` and prints the
elapsed time, cache-hit flag, and family count. The step has side effects so it
executes on every invocation; run it twice, deleting the cache between runs to
reproduce the cold number.

Host: Intel i9-13900K, Linux 6.8, Zig 0.16.0, ReleaseFast bench artifact,
2026-11-28. Cache: `~/.cache/fontz/metadata-v1.bin`, 782,819 bytes.

| Run | from_cache | elapsed | family_count |
| --- | --- | ---: | ---: |
| cold (no cache file) | false | 46.9 ms | 398 |
| warm | true | 10.5 ms | 398 |

The warm path removes about 36 ms of startup work and returns the same catalog.
The cache stores parsed metadata only; font files are not copied.

## Verification

```sh
rm -rf ~/.cache/fontz
zig build bench-discovery   # cold
zig build bench-discovery   # warm
zig build test-concurrency  # catalog lifecycle, cache epoch, OOM
zig build check             # Windows/macOS provider compile
```

`zig build test` has one pre-existing failure on this host
(`variation_matching_tests.zig`: "coverage matching variation sequence query
cache isolates positive negative base selector and scalar", expected 0
candidates, found 1) that also reproduces with these changes stashed. The new
`default-root discovery opts into the persistent metadata cache` test passes.
