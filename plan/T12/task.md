---
status: in progress
priority: P1
complexity: 4
readiness: 5%
agent: Claude Code / claude-opus-5-5
---

# T12. Lower peak memory on VS Code

On VS Code the checker reaches 16.8 GB at the default parallelism and about 13.4 GB with one worker, while tsc-rs stays under 8 GB. Sharing types between checkers (T10) cannot close that gap: 16 checkers add only about 2.3 GB to one. The cost sits in what a single checker allocates and keeps to the end.

Done means peak memory on VS Code is measurably lower, every step keeps its before and after numbers, and the checks below still hold.

Check: VS Code stays at 291 of 291 with tsc 7 and none extra at `-j` 1, 2, 4, 8 and 16; `tests/differential.sh` keeps 876 of 879 with none extra; `tests/ts7/run.mjs` loses none of the 8136; speed stays ahead of tsc-rs `--fast`.

## Execution plan

1. Measure: a throwaway copy with a sampling allocator wrapper attributes bytes to call sites on `-j 1`.
2. Cut the largest sources first, one concern per commit: scratch lists that die with the expression, then duplicated long-lived data.
3. Keep the code simple: stop when the next cut needs a new subsystem rather than a local change.
4. After each step: VS Code diagnostics and peak memory, unit tests. At the end the full check above and interleaved runs against tsc-rs and tsc 7.

Files: `src/types.zig`, `checker.zig`, `expr.zig`, `decls.zig`, `relate.zig`, `flow.zig`, `print.zig`, `pool.zig`.
