---
status: in progress
priority: P1
complexity: 4
readiness: 80%
agent: Codex / GPT-6
---

# T19. Reduce checking resources and fix verified bugs

Find and fix reproducible bugs, refactor the responsible code, and target at least 30% lower peak memory and execution time against the unchanged ReleaseFast binary on identical workloads. Report the measured scope and any unmet target honestly.

## Execution plan

1. Establish unit and differential baselines and retain a baseline binary.
2. Inspect allocation and checking ownership; measure representative existing fixtures and a larger project when available.
3. Add regression coverage for confirmed bugs and apply focused fixes and allocation refactoring.
4. Run unit, differential and available TS7 regression checks; compare interleaved timings, memory, and diagnostics.

## Current result

The verified fixes and resource improvements are recorded in `report.md`. The creator selected the existing fixtures and `stator/packages/compiler` as the benchmark workloads. Peak RSS falls 14.4%, wall time 10.0%, and CPU time 17.1% on the compiler workload; the small fixtures change little. The 30% memory and time acceptance target remains unmet, so this task remains open.

## Follow-up execution plan

Continue from merged commit `69986bf` as the new baseline. Keep the earlier report intact. Inspect allocation and filesystem profiles on the selected workloads; prioritize duplicated work and ownership bugs. Keep the parallel T20 library-API work isolated. Record regressions before fixes, compare identical commands against a retained baseline, and run unit, differential and TS7 checks before reporting the new measurements.

The follow-up fixes directory-cycle traversal, prunes excluded subtrees, and diagnoses private names in type queries. Its measurements and verification are in `followup-report.md`: the additional excluded-output stress case improves RSS by 41.2% and wall time by 80.1%, while the selected original workloads are essentially unchanged. The original acceptance target remains open.

## Allocation-profile iteration

Use `5d04486` as the baseline for another comparison on the same original workloads. Profile allocation sites inside each checking run, distinguish retained types from temporary lists, and reuse existing standard-library allocation helpers where they fit. Investigate the two remaining diagnostic misses without weakening the no-false-positive rule. Keep temporary instrumentation out of the final patch; validate ownership changes with unit tests, differential checks, the TS7 ratchet, and alternating resource measurements.

The verified changes and raw samples are in `allocation-report.md` and `allocation-benchmark.json`. Two generic-constraint property diagnostics are now reported, depth limits mark provisional answers, and temporary binder/type-analysis storage is released earlier. Peak RSS measured 2.5–2.9% lower; wall-time results are inconclusive on the loaded host. The 30% target remains unmet and the task stays open.

## Follow-up: remaining diagnostics and allocation cost

Baseline: `8ed59fd` (PR #8). Reproduce remaining differential misses and inspect the responsible generic-constraint/indexed-access paths. Fix only demonstrated bugs, preserving conservative handling of unsupported types. Profile repeated type/checker allocation work on the existing fixtures and `stator/packages/compiler`; reuse existing helpers or Zig standard-library facilities. Retain optimizations only with output-equivalence checks and measured resource evidence. Run focused and full differential tests, unit tests, and the TS7 ratchet. Record all measurements and limitations, then commit, push, create and merge the PR under the existing authorization. The original 30% RAM/time target remains open.

The narrowed indexed-access fix and mapper refactor are verified in `narrowing-report.md`, with raw samples in `narrowing-benchmark.json`. The differential suite now has one remaining miss and no false positives; TS7 loses no passing tests. Temporary mapper allocations are removed, but final measurements do not establish lower peak RAM or elapsed time. A larger-batch experiment was rejected because its timing result worsened. The 30% acceptance target remains unmet.

## Instruction-count iteration

The creator now prioritizes fewer retired machine instructions for compiling the existing test projects. Use `574ab7a` as baseline. Measure identical ReleaseFast commands with the existing benchmark harness, then investigate repeated import-resolution probes and repeated checker initialization between batches. Prefer removing duplicate work with existing resolver/cache/scheduling facilities. Compare instruction counts first and retain wall-time/RSS tradeoffs in the report. Preserve diagnostic output and module resolution order; verify unit tests, differential fixtures, and the TS7 ratchet before committing, publishing, and merging under the existing authorization.

The new instruction objective is achieved using the existing PGO build path and a small resolver optimization: compiler `build` retires 18.8% fewer instructions, with identical bytes in all 64 emitted files. The two fixture checks improve by 11.5% and 14.4%. Full differential and TS7 checks pass their regression gates. `instructions-report.md` and `instructions-benchmark.json` retain the methods and tradeoffs: compiler-build wall time falls 13.9%, while RSS increases 2.2%, so the original RAM/time target remains open.
