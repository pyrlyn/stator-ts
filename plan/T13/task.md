---
status: in progress
priority: P1
complexity: 3
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T13. Peak memory below tsc-rs

T12 left VS Code at 9.8 GB of RSS against 6.93 GB for tsc-rs, and found no single allocation site worth cutting. The numbers point elsewhere: sixteen checkers cost only about 1.1 GB more than one, so a checker's memory is mostly what it built for the files it checked, and the next files barely reuse it. Keeping all of it until the end of the run is what costs.

Done means peak RSS on VS Code at `-j 16` is several times below tsc-rs's 6.93 GB, at least 2.5 times, and the run is faster than T12's 2.32-2.71 s.

Check: VS Code stays at 291 of 291 with tsc 7 and none extra at `-j` 1, 2, 4, 8 and 16; `tests/differential.sh` keeps 876 of 879 with none extra; `tests/ts7/run.mjs` loses none of the 8136; a small project is not slower; nothing reads a dropped checker's memory.

## Execution plan

1. Baseline: T12's closing numbers, 10.51 GB of footprint and 9.8 GB of RSS at `-j 16`, re-raced against tsc-rs at the end.
2. Replace the per-worker file groups with runs of neighbouring files, each with its own checker. Workers take the next free run and reuse one arena, so memory is bounded by the runs in flight, not the files checked so far. Messages are copied out of the arena when a run ends.
3. Keep a floor on run size so a small project does not rebuild lib types for every file.
4. Prove nothing outlives a run: a throwaway build that unmaps the arena after each run, over VS Code, the fixtures and the TS7 suite.
5. Keep function blocks out of the shared tree: they hold 84% of the AST, and a run needs only its own files' and the few foreign ones it infers from.
   - The parser finds where a block ends from its tokens and leaves a stub with the modules the block names.
   - A run parses and binds a block into its own arena the first time it asks, so the shared tree stays read-only.
   - `check` only. `build` and `test` parse everything, since the emitter needs it.
   - Anything unusual falls back to the old way: a file whose skip failed is parsed in full, and a program where a block has a syntax error, or ends elsewhere than the skip found, is loaded again in full before anything is printed.
6. Prove the skip against templates, regexes, strings, comments, division, dynamic import and `import.meta`, and prove a body that redeclares a parameter leaves the shared symbol alone. Fixtures for what moved: a syntax error in a body, `var` merged with a parameter, imports in a body, closure narrowing, an immediately called function's flow, and unannotated returns and constructor-typed properties across files.
7. Measure at each job count, tune the run size, run the full check, race tsc-rs and tsc 7.

Files: `src/ast.zig`, `src/parser.zig`, `src/binder.zig`, `src/types.zig`, `src/decls.zig`, `src/checker.zig`, `src/expr.zig`, `src/project.zig`, `src/driver.zig`, `src/pool/schedule.zig`, `tests/fixtures/`, `AGENTS.md`, `README.md`, `plan/README.md`, `ideas.md`.
