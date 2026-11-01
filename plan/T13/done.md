# T13. Closing report

Done: peak RSS on VS Code at `-j 16` fell from 9.8 GB to 2.13-2.20 GB, 3.2 times below tsc-rs's 6.93 GB, and the run got faster, from 2.32-2.71 s to 2.15-2.45 s in the race and 1.89-2.03 s on a quiet machine.

Commit: the commit that adds this report.

## Before and after

VS Code at `-j 16`, ReleaseFast, peak memory footprint from `/usr/bin/time -l`. Every row kept 291 of 291 with none extra. RSS runs a little below footprint: 10.51 GB was 9.78 GB of RSS, 2.39 GB is 2.13-2.20 GB.

| Step | Peak | Wall |
| --- | --- | --- |
| T12 | 10.51 GB | 2.24-2.70 s |
| A fresh checker per run of neighbouring files, 8 runs per worker | 4.90-4.96 GB | 1.96-2.22 s |
| Function bodies out of the shared tree | 3.09-3.19 GB | 1.76-2.12 s |
| 24 runs per worker | 2.33-2.38 GB | 1.78-1.84 s |

Runs per worker on the final code, wall and footprint: 8, 1.77 s, 3.2 GB; 12, 1.77-1.87 s, 2.75-2.95 GB; 16, 1.74-1.77 s, 2.53-2.61 GB; 24, 1.78-1.84 s, 2.33-2.38 GB; 32, 1.84-1.86 s, 2.21-2.36 GB; 64, 1.88-1.90 s, 2.14-2.25 GB. One checker per file gives 1.94 GB, with 25 s of CPU. 24 is where memory stops paying for itself.

At each job count, final build:

| `-j` | Wall | Footprint | Match of 291 |
| --- | --- | --- | --- |
| 1 | 17.76 s | 1.72 GB | 291, none extra |
| 2 | 8.97 s | 1.79 GB | 291, none extra |
| 4 | 4.66 s | 1.92 GB | 291, none extra |
| 8 | 2.64 s | 2.20 GB | 291, none extra |
| 16 | 1.98 s | 2.39 GB | 291, none extra |

`-j 1` was 8.72 GB at T12. A small project is not slower: a two-file fixture takes 20.8 ms against 25.9 ms, and `vs/base/common` with its tests takes the same 0.04-0.05 s in 0.13 GB against 0.17 GB.

## What changed

- `src/pool/schedule.zig`, `src/checker.zig`: workers no longer own a share of the files. Files are cut by path into runs, a free worker takes the next one and builds a fresh checker in its arena, and the arena comes back whole when the run ends. Workers on E-cores no longer hold the end of the run back, which is where the time went.
- `src/parser.zig`, `src/binder.zig`, `src/decls.zig`: 84% of AST nodes are in function bodies. `check` finds where a body ends from its tokens and leaves a stub with the modules the body names. A run parses and binds a body into its own arena the first time it asks, through `decls.bodyOf`.
- `src/driver.zig`: `build` and `test` parse everything, since the emitter needs it. A body with a syntax error, or one that ends elsewhere than the skip found, makes the driver load the program again in full before printing anything, so `tsc`'s rule of listing every syntax error at once holds.
- `src/expr.zig`: `markAssignments` walks the outermost function of a binding, not its file, so a foreign local does not read every body in that file.

## A bug this found

With 48 or more runs per worker VS Code reported 7 false errors in `artifactIntegrations.test.ts`. A lambda under a union of functions took its return context from the first member only, and members sort by type id, which depends on what was checked before. tsc combines the returns. `contextual-union-return` fails on the T12 binary and passes now. T12 had the bug too, and only the partition hid it.

After the fix, one checker per file over all of VS Code still gives 291 of 291 with none extra, which is the strongest evidence yet that a result does not depend on what ran before it.

## How it was checked

- `zig build test`, with new tests for the skip, its failures, the stub's module list, and a body that redeclares a parameter.
- `tests/differential.sh`: 911 of 914 with none extra, the same three missed as T12, exact column on 907 of 911. The rise from 876 is the eight new fixtures: seven `function-body-*` and `contextual-union-return`.
- `tests/ts7/run.mjs`: 8136 known passing, 0 lost, 0 gained.
- VS Code and the fixtures on a ReleaseSafe build: no assertion or safety panic.
- Nothing outlives a run: a throwaway build with a page allocator that unmaps every arena after each run, one checker per file, over VS Code, the fixtures and the TS7 suite. Any read of a dropped checker's memory would crash it, and none did.
- The seven `tests/fixtures/function-body-*` fixtures give the same result on the T12 binary, which parses everything, and match `tsc`.
- Five interleaved rounds against tsrs, tsc-rs and TypeScript 7.0.2 and 7.1 beta: `plan/README.md`.

## What stopped it

T10 stays open and is worth less than before: sixteen workers now cost 0.7 GB more than one.

The load peaks at 1.10 GB of RSS and the sixteen workers add about 1.1 GB, so more runs have little left to win: one checker per file still needs 1.94 GB of footprint. tsrs `--fast` is still 1.4-1.5 times faster, and the gap is the same on one thread, so it lies in the check phase and not in scheduling: `plan/README.md` has the analysis and `ideas.md` the next steps.
