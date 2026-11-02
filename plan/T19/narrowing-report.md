# T19 narrowed indexed access and temporary mappers

Baseline: `8ed59fd` (PR #8), Zig 0.17.0, TypeScript 7.0.2. This iteration fixes missing-property diagnostics after generic indexed-access narrowing and removes temporary mapper allocations. **No reproducible reduction in peak RAM or elapsed time is established. The original 30% target remains unmet.**

## Correctness

`isOpen` inspected each intersection constituent independently. For a nullable generic indexed access intersected with `{}`, it still considered the original nullable constraint open, even though the intersection removed that nullable part. It therefore suppressed real TS2339 diagnostics after a non-null assertion or optional chain.

The checker now examines the apparent intersection before deciding whether it is open. The extended [mapped-known-keys fixture](../../tests/fixtures/mapped-known-keys-generic-index/a.ts) has three missing-property errors: the baseline reported only the local-variable case, while the candidate matches all three diagnostics and columns from TypeScript. Valid `length`, `push`, and `indexOf` accesses remain valid. No generalized TS2536 rule was guessed for the remaining unsupported generic-index case.

## Allocation refactor

Anonymous and conditional type instantiations created composite mappers just to calculate the argument list used as an interning key. The mapper was then discarded, including on cache hits. `mapComposed` reuses the existing composition algorithm directly; persistent composition remains where alias arguments need it. Both instantiation paths release temporary argument buffers larger than the existing 16-element stack buffer after the persistent result has copied its arguments.

The [17-parameter regression fixture](../../tests/fixtures/mapper-composition-storage/a.ts) exercises anonymous objects, conditional aliases, repeated substitutions, and homomorphic tuple mapping. Both baseline and candidate match TypeScript's three deliberate assignment errors. The implementation reuses the project's mapper and `smallList` facilities; no dependency or shared-package addition was needed.

## Verification

- `zig build test` passes.
- Full existing-fixture differential: 1203/1204 diagnostics matched, zero false positives, one remaining miss (`constraint-position-narrowing`, TS2536). Exact columns match on 1199 diagnostics.
- The subsequently added mapper fixture matches all three diagnostics and columns separately. Combined coverage is 1206/1207 diagnostics, with the same single miss.
- Full TS7 run: 13,737 tests, 8,249 pass, 5,488 fail, zero crashes or timeouts, zero lost passing tests. The ratchet file is unchanged.
- ReleaseSafe: all 41 diagnostics and columns match across the mapper fixture, mapped indexed access, object literal instantiation, recursive conditional inference, settled visits, and cross-file function bodies.
- `git diff --check` passes.

## Measurements

[Raw samples and identities](narrowing-benchmark.json) include the baseline and candidate binary hashes, corpus identity, and rejected experiment. Final comparisons use three warmup pairs and 30 alternating measured pairs, identical `check` arguments, and `-j 16`. Every run preserves stdout SHA-256 and exit status. No task-owned builds or tests ran concurrently with these final comparisons.

| Existing workload | Median peak RSS, before → after | Median wall time, before → after |
| --- | --- | --- |
| `stator/packages/compiler` | 112.214 → 112.222 MB | 255.02 → 234.99 ms |
| `function-body-across-files` | 22.643 → 22.643 MB | 44.27 → 44.13 ms |
| `settled-visits` | 23.806 → 23.798 MB | 50.93 → 48.57 ms |

MB is decimal. The host remained heavily loaded: a snapshot showed load averages 44.00/49.43/39.15, 0.5% idle CPU, and 13 GB compressed memory. Median paired wall-time differences were −1.71, −2.07, and −0.33 ms respectively. Their 95% percentile bootstrap intervals all include zero: [−19.12, +13.22], [−5.81, +1.92], and [−2.90, +1.62] ms (10,000 resamples, seed 19). The favorable differences between aggregate medians are insufficient evidence of a speedup. RSS is essentially unchanged.

An earlier correctness-only versus allocation-refactor comparison showed 0.29% lower compiler RSS, which did not reproduce in the final baseline comparison. Both sets of samples are retained. A separate 20-pair experiment increased only the minimum checking batch from 256 to 512 KiB: RSS fell 3.24%, but median wall time rose 6.59%. That scheduling change was rejected and is absent from the patch.

Reproduce a comparison from the repository root:

```sh
node scripts/benchmark.mjs /path/to/baseline /path/to/candidate --rounds 30 -- \
  check -p /path/to/stator/packages/compiler \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16
```

The earlier reports use different baselines and must not be added to these percentages. T19 remains open.
