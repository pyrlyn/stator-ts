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
