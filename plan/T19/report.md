# T19 verification and measurements

The bug fixes and optimizations are verified locally. The requested 30% reduction in both peak memory and execution time is **not achieved**. This is a progress report, not a completion claim.

## Changes

- `src/bump.zig`: preserve free suffixes when splitting a recycled block or shrinking an earlier allocation; find larger free size classes with a bitset and split aligned allocations; retain one warm 4 MiB chunk per worker instead of four. A failed chunk mapping no longer publishes the still-active allocation window as free memory, which previously allowed later allocations to overlap. Four additional allocator regression tests cover these cases.
- `src/project.zig`: reuse the existing sharded filesystem cache for immutable package manifest bytes. Different subpath imports still resolve separately, but no longer reread the same manifest. Concurrent directory-cache misses now produce one shared listing instead of allocating and retaining duplicates. The new test checks manifest snapshots, cached misses, fresh-cache visibility, and simultaneous directory reads.
- `src/types.zig`, `src/decls.zig`, `src/expr.zig`: make `internRef` accept a borrowed, read-only argument slice. Its existing cache already copies on a miss; two callers no longer allocate an unnecessary first copy.
- `src/expr.zig`: with `noImplicitThis: false`, an unannotated TypeScript object method uses `any` for `this`. Explicit and contextual `this` parameters, class methods, and checked JavaScript keep their existing behavior. The fixture previously produced five false TS2339 diagnostics.
- `src/parser.zig`, `src/binder.zig`, `src/checker.zig`: diagnose computed enum names with TS1164, bind their expressions, and check those expressions under `--all-diagnostics`. An immediately invoked function in such a name previously reached lazy-body binding without its initial flow and crashed. The default command correctly suppresses semantic diagnostics after a syntax error.
- `tests/differential.sh`: remove an illegal top-level `return` from the Node snippet used when `TSC` is specified. This failed on the installed Node 26 before a comparison could run.
- `scripts/benchmark.mjs`: a macOS benchmark wrapper around the existing Node runtime and `/usr/bin/time -l`. It alternates binaries, warms them up, records raw samples, and rejects changed stdout or exit statuses. No new dependencies were introduced.

Existing `Bump`, `FsCache`, `readFile`, `internRef`, `inJs`, and differential/TS7 harnesses were reused. The shared package inventory contains no suitable Zig allocator or compiler-specific filesystem cache to extract or adopt. General allocator replacements would discard the existing run-scoped ownership model.

## Performance

Baseline: commit `1ef21f2673ff32cee89c17dd7ae4109e478f31af`. Both binaries use Zig 0.17.0, ReleaseFast, no PGO, and `-j 16`. Host: Mac15,9, macOS 27.0.1. Each workload has three warmup pairs and 30 measured pairs with alternating order. Wall time includes process launch. macOS reports CPU time at 10 ms precision, so CPU comparisons on the tiny fixtures are not informative.

The creator selected these existing workloads. Every measured run preserved its exit status and stdout SHA-256. The exact arguments, binary hashes, individual measurements, and medians are in [benchmark.json](benchmark.json).

| Workload | Wall before → after | Peak RSS before → after | Result |
| --- | --- | --- | --- |
| `stator/packages/compiler` | 123.59 → 111.23 ms | 136.31 → 116.73 MB | 10.0% less wall time, 14.4% less RSS |
| `function-body-across-files` | 22.71 → 22.93 ms | 23.36 → 23.25 MB | No meaningful timing improvement; 0.5% less RSS |
| `settled-visits` | 35.61 → 35.72 ms | 24.58 → 24.38 MB | No meaningful timing improvement; 0.8% less RSS |

On the compiler workload, median user + system CPU time is 410 → 340 ms (17.1% lower), and peak memory footprint is 127.64 → 108.09 MB (15.3% lower). MB means decimal megabytes; the raw artifact stores bytes. These measurements do not establish an improvement on every TypeScript project or other hardware.

Reproduce a comparison from this worktree:

```sh
node scripts/benchmark.mjs /path/to/baseline /path/to/candidate -- \
  check -p /path/to/stator/packages/compiler \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16
```

Experiments with retained per-worker scan arenas and 1 MiB bump chunks were discarded: they increased memory or failed to improve the measured workload. The final implementation retains the original scan allocation model and 4 MiB chunk size. Sampling the baseline with `samply` identified filesystem operations during import loading as a substantial CPU cost, motivating the cache changes.

## Correctness

- `zig build test` passes, including the allocator and filesystem-cache regressions.
- ReleaseSafe also passes the two new fixtures and `settled-visits` (26 exact diagnostics, no extras or misses), and checks `stator/packages/compiler` without a panic.
- `tests/differential.sh` against the installed pinned TypeScript 7.0.2: **1196 matched, zero false positives, three pre-existing misses** out of 1199 reference diagnostics. Exact columns match on 1192 of 1196. Before the new fixtures, the unchanged binary matched 1191 of 1194, also with zero false positives and three misses. Both new fixtures match exactly after the fixes.
- Both binaries ran the full 13,737-test TS7 suite. Baseline: 8233 pass, 5503 fail, one crash. Candidate: **8249 pass, 5488 fail, zero crashes**. No previously passing test regressed; 16 tests now pass. [ts7-comparison.json](ts7-comparison.json) lists them. These 16 were added to `tests/ts7/passing.txt`; existing failures were not relabeled or suppressed.
- `bash -n tests/differential.sh`, `node --check scripts/benchmark.mjs`, and `git diff --check` pass. The repository already has files that fail `zig fmt --check`; unrelated formatting was not rewritten.

Remaining acceptance work is the additional reduction needed to reach 30% on the selected workloads. No compatibility or performance result beyond the measured cases is claimed.
