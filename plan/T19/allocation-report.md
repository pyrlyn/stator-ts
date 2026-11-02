# T19 allocation-profile iteration

The requested 30% reduction in both peak RAM and time is still **not achieved**. This iteration fixes missed property diagnostics and constraint-depth bookkeeping, then reduces the lifetime of temporary binding and type-analysis allocations. Measured peak RSS is 2.5–2.9% lower on the original workloads. Wall-time measurements are inconclusive under substantial unrelated host load; no execution-time improvement is claimed.

## Correctness fixes

`isOpen` treated any generic constraint containing a type variable as open to arbitrary properties. For `U extends readonly T[]` and `U extends { value: T }`, this suppressed real TS2339 errors on `value.missing`. The new `generic-constraint-missing-property` fixture produces exactly the same two diagnostics and columns as TypeScript 7.0.2; the baseline missed both. Existing properties and string-indexed constraints remain valid. Nullable generic constraints retain their conservative handling because their indexed-access flow facts are not fully modeled. An initial broader change produced a false diagnostic and was narrowed before acceptance.

`baseConstraintDepth` now calls the existing `metCycle` mechanism at its depth limit. A depth-limited stand-in must mark dependent answers as provisional. A unit test covers the limit and a shorter chain that still resolves to `number`.

## Allocation changes

- Binder construction labels and their growing edge lists live in a temporary arena. Only completed graph edges are copied into the persistent allocator. Ordinary function returns no longer build an unused return join; immediately invoked functions and `finally` reductions retain their required joins. Branch nodes are allocated only when needed; loop nodes retain their identity before back edges exist.
- Intersection calculation uses the standard library's `BufferFirstAllocator` for temporary lists, freeing fallback allocations when done. An interned intersection owns a copy of its final members. Tests exercise both the small buffer and heap fallback, including repeated calls and preserved member order.
- Discriminant filtering uses the existing `smallList` helper and releases its fallback buffer after constructing the union.
- The first lazily requested property reserves two entries through the existing `reserveProps` helper instead of the collection's larger default allocation.

The new binder lifetime test reuses released allocation space before walking loop and `finally` edges. This checks that the graph does not retain pointers into construction scratch storage. AST/symbol ownership, public walking APIs, worker configuration, and dependencies remain unchanged. Existing `Bump`, `smallList`, `reserveProps`, and standard-library allocators were reused; the shared package inventory had no applicable Zig allocation helper.

## Verification

- `zig build test` passes, including constraint-depth, intersection ownership, loop identity, and graph-lifetime regressions.
- Full differential suite: **1200/1202 diagnostics matched, zero false positives, two pre-existing misses**; exact columns match on 1196 diagnostics. The remaining misses are `constraint-position-narrowing` and `mapped-known-keys-generic-index`.
- Full TS7 suite: **8249 pass, 5488 fail, zero crashes or timeouts**, with no lost passing tests and no ratchet changes.
- ReleaseSafe matches all **48 diagnostics and columns** across the new fixture, `settled-visits`, `intersection-halved`, `truthiness-on-intersections`, and `function-body-across-files`.
- `git diff --check` passes. Temporary allocation instrumentation and rejected experiments are absent from the patch.

## Measurements and limits

Baseline: `5d04486a9fcb09c9bacb71c57ac82dff9d09de9e`. Both binaries use Zig 0.17.0, ReleaseFast, no PGO, and `-j 16`. Each workload has three warmup pairs followed by 50 measured pairs in alternating order. Every run preserved its stdout hash and exit status. MB means decimal megabytes. CPU counters have 10 ms resolution.

| Workload | Peak RSS before → after | Wall before → after |
| --- | --- | --- |
| `stator/packages/compiler` | 115.20 → 112.28 MB (−2.54%) | 219.32 → 217.61 ms |
| `function-body-across-files` | 23.28 → 22.61 MB (−2.89%) | 50.99 → 53.98 ms |
| `settled-visits` | 24.43 → 23.77 MB (−2.68%) | 69.03 → 68.65 ms |

The machine was heavily loaded: one snapshot showed 0% idle CPU, load average 34.50, 62 GB physical memory in use, and about 3.5 GB compressed memory. Even the unchanged compiler baseline ranged from 109.75 to 305.13 ms within its measured series. These conditions limit timing conclusions and the generality of RSS results.

The first small-fixture comparison was 5.86% slower. A separate 50-pair control compared the allocation changes against a binary containing only the correctness fixes: medians were 105.59 → 99.88 ms, while the paired median difference was −0.57 ms with a bootstrap interval spanning −11.66 to +9.65 ms. Thus the control did not reproduce a stable slowdown, but it also did not establish a speedup. Both measurements are retained, rather than selecting the favorable one.

[allocation-benchmark.json](allocation-benchmark.json) contains commands, binary hashes, corpus identity, raw samples, medians, and the control comparison. Reproduce with:

```sh
node scripts/benchmark.mjs /path/to/baseline /path/to/candidate --rounds 50 -- \
  check -p /path/to/stator/packages/compiler \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16
```

Profiling found temporary allocation traffic and substantial filesystem work. Directory-handle reuse, persistent worker threads, caching composite properties, larger checking batches with fewer loading workers, and eagerly releasing completed workers' final chunks were tested and rejected because they slowed execution or offered no clear benefit. No benchmark-specific diagnostic suppression, changed checking options, or replacement workload was introduced.

The earlier reports remain historical measurements against their own baselines. Their percentages must not be added to this iteration. T19 remains open until the original 30% RAM and time acceptance target is demonstrated.
