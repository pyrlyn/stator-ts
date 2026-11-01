---
status: in progress
priority: P1
complexity: 5
readiness: 85%
agent: Claude Code / claude-opus-5-5
---

# T17. Cut check time by 30% and peak memory by half

The creator asked for both. T15 left VS Code at 1.75 s, 155 G instructions and 2.46 GB on 16 threads. The goal is 1.23 s and 1.23 GB on the same corpus, with diagnostics that do not change.

Reference benchmark: VS Code commit c198526d8e64ba6f9944e9f7bcc079ed1f6d7fcc, `src/tsconfig.json`, TypeScript 7.0.2 libs, ReleaseFast, `-j 16`, `/usr/bin/time -l`. Instructions and peak footprint are the working measures, interleaved rounds settle wall time.

Where the memory goes, from a profile of allocations by call site:

- Loading asks for 968 MB: 181 MB of source, 5.2 million nodes at 80 bytes, 1 million symbols at 136 bytes, 128 MB of symbol tables.
- Checkers ask for 10.8 GB over 233 runs, 46 MB a run. A worker keeps its largest run. About 2.8 GB is property tables and `Prop` records of instantiated types, about 1.8 GB is hash tables growing inside an arena, which leaves every old table behind, and about 1.6 GB is parsed bodies.

Execution plan, measuring each step on its own:

1. Take the parser fix for a tuple inside `extends`, with a fixture checked against tsc. It stopped `check` on any project using `type-fest`.
2. Give back what a table leaves when it grows: an allocator over the worker's arena that reuses large freed blocks. Reserve property tables at their final size. Share load arenas per worker instead of one per file (`src/checker.zig`, `src/types.zig`, `src/project.zig`).
3. Look properties up without building the whole table of an interface or a reference (`src/decls.zig`).
4. Shrink `Node`, `Symbol`, `Prop`, `Type` and `Obj` (`src/ast.zig`, `src/binder.zig`, `src/types.zig`).
5. Map large source files instead of reading them (`src/project.zig`).
6. Tune `runs_per_worker` and the rest of the levers in `plan/README.md` against the new numbers: allocator, PGO, memos.

Check: VS Code at `-j` 1, 2, 4, 8, 16 gives tsc's 388 errors with none extra, `zig build test` passes, `tests/differential.sh` keeps its counts, `tests/ts7/run.mjs` loses nothing from its passing list, a small project is not slower, and interleaved rounds show the wall time and peak footprint against T15's.

Where it stands: peak footprint is at the goal. Wall at `-j 16` is not: 7 to 10% from `zig build`, 16 to 19% with `scripts/pgo.sh`. Numbers are in `plan/README.md` under T17. All of the Check line above passes on both builds, except `zig build test`, which does not apply to the PGO one. The task stays open until the creator decides whether the time goal stands.
