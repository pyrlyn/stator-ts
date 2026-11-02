# T19: fewer instructions per project compilation

The creator prioritized retired machine instructions. On the existing `stator/packages/compiler` workload, the verified PGO binary executes **18.8% fewer instructions for `build`**, with byte-identical JavaScript output. Median wall time falls 13.9%; peak RSS rises 2.2%. This meets the new instruction-reduction objective, but not the earlier 30% RAM/time objective.

## Changes and reuse

The main improvement comes from using the existing [PGO build script](../../scripts/pgo.sh), rather than introducing a new optimizer or dependency. It trains on one `check` of the compiler project, then optimizes Zig's IR with the already documented clang and llvm-profdata 23.1.4. Training cost is a one-time compiler build cost, not included in the per-project measurements. The binary uses `-mcpu=native` and targets the build machine. README now shows how to build and run this artifact.

The resolver additionally reuses one immutable `FsCache` directory listing across extension candidates and index candidates. Previously each candidate repeated directory hashing, shard locking, and lookup. File precedence and the stat fallback for unreadable listings remain intact. The regression test covers extension substitution, directory-versus-file entries, index precedence, trailing separators, and fallback stat calls. Existing cache and standard-library facilities were sufficient; no shared package or dependency was added.

## Measured results

Baseline: `574ab7a`, Zig 0.17.0 ReleaseFast without PGO. Candidate: the resolver change and the existing PGO path, trained only on the compiler project's `check`. The two fixtures and JavaScript emission were not training commands. All runs use `-j 16`, the same TypeScript library directory, three warmup pairs, and 30 alternating measured pairs. No task-owned tests or builds ran concurrently with measurement.

| Workload | Retired instructions, billions | Reduction | Wall time, ms | Peak RSS, MB |
| --- | --- | --- | --- | --- |
| compiler `build` | 3.166 → 2.570 | **18.8%** | 135.10 → 116.39 | 112.706 → 115.196 |
| compiler `check` | 3.290 → 2.678 | **18.6%** | 131.61 → 117.95 | 112.665 → 114.967 |
| `function-body-across-files` check | 0.214 → 0.189 | **11.5%** | 26.26 → 25.34 | 22.643 → 22.831 |
| `settled-visits` check | 0.405 → 0.347 | **14.4%** | 76.31 → 68.61 | 23.806 → 24.347 |

The paired instruction-reduction median for compiler `build` is 18.91%, with a 95% percentile bootstrap interval of 18.70–19.12% (10,000 resamples, seed 19). All four workload intervals exclude zero. These are observations on Mac15,9, arm64, macOS 27.0.1; unrelated host load varied substantially, so elapsed times should not be generalized to other machines or workloads. MB is decimal.

Two separate controls distinguish the changes: the resolver optimization alone reduces compiler-check instructions by about 0.40% (paired 95% interval 0.28–0.49%); PGO versus ReleaseFast on the same changed source reduces them by 19.48%. These controls ran at different times and must not be added to the main percentages. The previously rejected larger-batch scheduling change remains absent: PGO provides a much larger reduction while retaining the existing scheduling policy.

[instructions-benchmark.json](instructions-benchmark.json) contains every sample, binary hashes, training arguments, corpus identity, confidence calculations, and the emitted-file hashes. All benchmark runs preserved stdout SHA-256 and exit status. Both standalone `build` outputs and the final benchmark output contain the same 64 files with identical bytes.

## Verification

- `zig build test` passes, including the new resolver regression test.
- Full differential against TypeScript 7.0.2, using the PGO binary: 1206/1207 diagnostics matched, zero false positives, one existing TS2536 miss; 1202 exact columns.
- Full TS7 against the PGO binary: 13,737 tests, 8,249 pass, 5,488 fail, zero crashes/timeouts, zero lost passing tests. The ratchet is unchanged.
- Baseline and PGO `build` produce byte-identical output for all 64 JavaScript files.
- `git diff --check` passes.

## Reproduce and use

From the repository root, train and then run the generated executable:

```sh
mise exec conda:clang@23.1.4 conda:llvm-tools@23.1.4 -- \
  bash scripts/pgo.sh -p /path/to/stator/packages/compiler \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16
zig-out/bin/stator-ts-pgo build -p /path/to/project
```

For the measured `build` scenario, direct emitted files to a scratch directory:

```sh
node scripts/benchmark.mjs /path/to/baseline zig-out/bin/stator-ts-pgo --rounds 30 -- \
  build -p /path/to/stator/packages/compiler \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16 \
  --outDir /path/to/scratch-output
```

The measured PGO executable's SHA-256 is `57137b21bd4129e4d0973c99de2a27d2e7100f125e962bc2185834a8b3467be0`. Use `stator-ts-pgo` for these benefits; the ordinary build remains available. Retrain when rebuilding after source changes. The earlier RAM/time target stays open because PGO slightly increases peak RAM.
