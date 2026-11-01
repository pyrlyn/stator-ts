---
status: in progress
priority: P0
complexity: 5
readiness: 5%
agent: Claude Code / claude-opus-5-5
---

# T11. Cut the checker's cost per expression

On VS Code the checker spends 51-56 s of CPU and 21-28 GB, where tsc-rs spends 20 s and 7 GB and reports the right errors. The gap is the cost of each expression, not scheduling, so `plan/README.md`'s table will not close through more threads.

Done means `check` on VS Code is faster than tsc-rs's default mode on the same machine, at the same or better diagnostics.

Execution plan: profile `-j 1` with `sample`, then take the largest costs one at a time, keeping a before and after number for each in `done.md`. Temporary lists first, about 5.7 GB of 22.2 GB tracked. Files: `src/expr.zig`, `src/relate.zig`, `src/types.zig`, `src/decls.zig`.

Check: `tests/differential.sh` and `tests/ts7/run.mjs` lose nothing, and VS Code diagnostics stay identical unless a change is a compatibility fix.
