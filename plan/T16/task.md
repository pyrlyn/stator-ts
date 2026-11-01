---
status: in progress
priority: P2
complexity: 3
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T16. Zig 0.17 and the coroutines package

The creator asked for `pyrlyn/coroutines` in the build and in use, and for Zig to go up to 0.17, which the package requires. T13's comparison in `plan/README.md` found nothing to gain from it on speed, so this task is about keeping what stator-ts has while the parallel passes move onto the package.

Done means stator-ts builds on Zig 0.17.0, the package comes through `build.zig.zon`, `src/pool` runs its passes through `coroutines.state_machine.runParallel`, and what the package lacks reached it by PR.

Check: `zig build test` passes; VS Code stays at 291 of 291 with none extra at `-j` 1, 2, 4, 8 and 16; `tests/differential.sh` keeps 911 of 914 with none extra; `tests/ts7/run.mjs` loses none of the 8136, `compiler/binderBinaryExpressionStress` included; peak memory and wall time on VS Code, and a small project's wall time, are reported against T13.

## Execution plan

1. Pin Zig 0.17.0 for the project in `mise.toml`, `build.zig.zon`, `toolchain.md`, `AGENTS.md`. Fix what the new standard library breaks, with no change in behaviour, and benchmark before going further.
2. `zig fetch --save git+https://github.com/pyrlyn/coroutines`, then import the `coroutines` module in `build.zig`.
3. Send the package what stator-ts cannot do without, by PR:
   - a stack size for workers: the fixed 1 MiB crashes on `binderBinaryExpressionStress`;
   - the worker's index: each worker owns an arena and tasks must find it;
   - a caller that only waits: the caller works too, and the main stack is too small for a checker.
4. Point the dependency at the commit that has both.
5. Replace the thread pool in `src/pool/threads.zig` and `dispatch` in `src/pool.zig` with `runParallel`, one task per index, with `caller_works = false`. Nested calls keep running inline, now on their own worker's index. Remove `schedule.Cursor`, since the package's cursor replaces it.
6. Run the full check and race the result against T13's build.
7. Update `toolchain.md`, the coroutines section and the Zig versions in `plan/README.md`, and write `done.md`.

Files: `mise.toml`, `build.zig`, `build.zig.zon`, `src/pool.zig`, `src/pool/threads.zig`, `src/pool/schedule.zig`, `src/main.zig`, `src/project.zig`, whatever Zig 0.17 breaks, `AGENTS.md`, `README.md`, `toolchain.md`, `plan/README.md`.
