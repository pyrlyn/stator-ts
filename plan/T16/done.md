# T16. Done

stator-ts builds on Zig 0.17.0, pinned in `mise.toml` and `build.zig.zon`. The standard library's changes only reached `b.args`, the `**` array repeat and the reflection in `src/ast.zig`, `src/lexer.zig` and `src/project.zig`.

`coroutines` comes through `build.zig.zon`, and every parallel pass runs through `state_machine.runParallel`. `src/pool/threads.zig` lost its threads, `schedule.Cursor` is gone, and `ThreadPool` only holds the width, capped at the library's 64. A nested call now runs on its own worker's index, not on 0.

What the package lacked went in by https://github.com/pyrlyn/coroutines/pull/5: `stack_size`, `caller_works` and `currentWorker()`. `schedule.Cursor` moved there by https://github.com/pyrlyn/coroutines/pull/6, which also stops a `chunk` near the top of `usize` from wrapping the cursor and running tasks twice. Both are merged with CI passing on Linux, Windows and macOS; the library has 17 tests, seven of them new. With `stack_size` ignored the stack test dies with SIGBUS, and without the upper clamp the chunk test fails. `build.zig.zon` pins library `main`, 8b175b24723c352944811b3bf05fe0853bbca64e.

## Checks

All on the ReleaseFast build of this tree.

- `zig build test` passes. `zig-pkg/`, where Zig 0.17 keeps fetched packages, is git-ignored.
- VS Code: 291 of 291, none extra, at `-j` 1, 2, 4, 8 and 16; output byte-identical to T13's over five rounds at `-j 16`.
- `tests/differential.sh`: `overall 914 911 911 0 3`, exact column on 907 of 911.
- `tests/ts7/run.mjs`: 8136 known passing, 0 lost, 0 gained, `compiler/binderBinaryExpressionStress` included.

| Measure | T13 | T16 |
| --- | --- | --- |
| VS Code `-j 16`, wall | 2.49-2.96 s | 2.50-3.02 s |
| User | 21.1-21.5 s | 20.7-21.4 s |
| Peak RSS | 2.14-2.19 GB | 2.14-2.23 GB |
| Two-file fixture, median | 19.3 ms | 19.7 ms |
| Same, fastest | 17.2 ms | 17.1 ms |

Five interleaved rounds for VS Code and 150 for the fixture, with other sessions keeping the load average near 20, so the gaps are within noise. An earlier sitting, before PR 6, gave 2.39-2.77 s against 2.28-2.58 s, and at most 2.26 GB against 2.36 GB. Zig 0.17 alone, also in an earlier sitting, changes nothing measurable: 23.2-23.5 s user against 23.6-24.0 s on VS Code, 19.6 ms against 19.5 ms on the fixture.

No speed was expected from this: see the coroutines section in `plan/README.md`.
