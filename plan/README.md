# stator-ts

https://github.com/pyrlyn/stator-ts

Standalone TypeScript compiler in Zig 0.17 that emits JavaScript, aims for `tsc` compatibility, scans projects in parallel and runs tests on Node or Bun.

## Decisions

- Standalone project. It shares no code with `apps/stator`, whose frontend is the TypeScript compiler API.
- Output is JavaScript. Target is ES2022 or newer, modules are ESM; downleveling and CommonJS are on the roadmap.
- `lib.*.d.ts` files are found at run time (`--lib-dir`, `STATOR_TS_LIB`, then `node_modules/typescript/lib`), so they always match the project's TypeScript version.
- The emitter applies edits to source text, so comments and formatting survive.
- `tsc` compatibility is the goal and is measured by the differential suite; full parity is far larger than one task.
- Tests run on Node or Bun in a process pool, one process per test file.
- Each parallel pass spawns its own big-stack workers through `coroutines.state_machine.runParallel` and joins them; the caller only waits. Files are cut by path into runs, a free worker takes the next run and builds a fresh checker for it in its own arena, so memory follows the runs in flight and not the files checked so far. Results are byte-identical across runs at a fixed `-j`.
- `check` leaves function bodies out of the shared tree: a run parses and binds the ones it needs. `build` and `test` parse everything for the emitter, and a body that does not parse sends `check` back to a full load before anything is printed.
- `check` and `build` follow the tsc command line: semantic errors stay hidden while syntax errors exist. `--all-diagnostics` shows both, as tsc's test harness does.
- TypeScript 7's tests are fetched by script and never vendored.

## Findings

Reference: VS Code commit c198526d8e64ba6f9944e9f7bcc079ed1f6d7fcc, `src/tsconfig.json`; TypeScript 7.0.2 (npm) with its bundled libs; 16 threads, ReleaseFast.

| Compiler | Wall | User + sys | Peak RSS | Errors | Extra | Missed |
| --- | --- | --- | --- | --- | --- | --- |
| stator-ts `check` | 2.15-2.45 s | 22-24 s | 2.13-2.20 GB | 291 | 0 | 0 |
| tsrs 0.20.1 `--fast` | 1.47-1.55 s | 15-16 s | 2.52-2.53 GB | 302 | 11 | 0 |
| tsrs 0.20.1 | 3.38-3.50 s | 13 s | 3.17-3.18 GB | 302 | 11 | 0 |
| tsc-rs 0.8.0 `--fast` | 3.23-3.93 s | 24-26 s | 7.75-7.77 GB | 302 | 11 | 0 |
| tsc-rs 0.8.0 | 5.55-5.66 s | 19-20 s | 6.91-6.93 GB | 302 | 11 | 0 |
| tsc 7.1.0-beta | 8.62-8.79 s | 38-42 s | 7.30-7.43 GB | 302 | 11 | 0 |
| tsc 7.0.2 | 11.06-11.60 s | 52-60 s | 9.92-10.57 GB | 291 | 0 | 0 |
| tsc 6.0.2 (JS) | 133.91 s | | 11.29 GB | | | |

The rows down to tsc 7.0.2 come from five interleaved rounds of the finished T13 build, 2^30 bytes to the GB; tsc 6.0.2 from an earlier sitting. On a quiet machine, alternating only stator-ts and tsrs `--fast`, they took 1.89-2.03 s and 1.29-1.41 s. Extra and Missed compare file, line and code against tsc 7.0.2, npm's `latest`. tsrs comes from npm, source https://github.com/oxc-project/tsrs (0.20.1-ts7.1.0-beta, checked 2026-11-01); tsc-rs from npm, source https://github.com/pingdotgg/ts-rust; both ran with their defaults on the same machine.

The 11 extra errors are not false positives, as this table said until T13: tsrs and tsc-rs report exactly what tsc 7.1.0-beta reports, all 302. tsrs is pinned to 7.1.0-beta and tsc-rs 0.8.0 prints `Version 7.1.0-dev`. All 11 sit around `IConfigurationResolverService`: nine name it in their first line and two name the class that implements it. The elaboration at `variableResolver.ts:83` ends with 7.1 refusing a distributed `T` against a non-distributed one. stator-ts follows 7.0.2 and misses them against 7.1.

So stator-ts uses the least memory of all of them: 14% below tsrs `--fast`, 3.2 times below tsc-rs, 4.7 times below tsc 7.0.2. tsrs `--fast` is the fastest, 1.4 to 1.5 times ahead of stator-ts, which stays ahead of everything else: 1.6 times ahead of tsc-rs `--fast`, 2.5 times ahead of its default mode and 5 times ahead of tsc 7.0.2. Diagnostics are the same at `-j` 1, 2, 4, 8 and 16, and with one checker per file.

The load peaks at 1.10 GB of RSS and sixteen workers add about 1.1 GB. `-j 1` takes 1.72 GB of footprint and 17.76 s. T12 left a single checker at 8.7 GB, and T13 took 9.8 GB down to 2.2 GB through short-lived checkers and lazy function bodies.

### T15

After T15, alternating with tsrs under a load average of 8 to 14, so not a quiet machine: `-j 16` 1.61-2.09 s, median 1.68 s, 155-157 G instructions, 2.43-2.56 GB; tsrs `--fast` 1.33-2.22 s, median 1.71 s, 111-113 G, 2.71-2.74 GB. `-j 1` 14.26-14.35 s, 131.9 G, 48.6 G cycles; tsrs `--singleThreaded --fast` 11.89-12.17 s, 99.9 G, 42.6 G cycles. T13 was 18.72 s and 188.6 G at `-j 1`, 215 G at `-j 16`. The numbers and how they were got are in `plan/T15/done.md`; the tables above and below are from T13.

What is left is spread evenly over `openat`, `relate.cached`, property lookup, the lexer and the arena. At `-j 16` the extra is checkers repeating each other, 156 G against 132 G, and file reads, which stop scaling at 4 threads and about 300 ms on this machine.

### T17

Alternating with the T15 build under a load average of 10 to 27, so not a quiet machine. Cycles and instructions are the working measure; the load moved wall by a second between rounds.

| Build | Wall | Instructions | Cycles | Peak footprint | Peak RSS |
| --- | --- | --- | --- | --- | --- |
| T15 `-j 16` | 1.74-2.37 s | 154-156 G | 58-64 G | 2.35-2.48 GB | 2.34 GB |
| T17 `-j 16` | 1.61-2.26 s | 152-154 G | 55-58 G | 1.19-1.25 GB | 1.39 GB |
| T15 `-j 1` | 14.14 s | 131.7 G | 46.2 G | 1.88 GB | |
| T17 `-j 1` | 12.05 s | 125 G | 40.9 G | 1.02 GB | |
| T17 with PGO `-j 16` | 1.39-1.67 s | 115 G | 47-50 G | 1.20-1.24 GB | |
| T17 with PGO `-j 1` | 10.50-11.22 s | 96-97 G | 35 G | 1.02 GB | |

Peak footprint halved. Files of 16 KiB and up are mapped, so they count in RSS and not in footprint, which is why RSS fell by 41%. Before the last changes the peak read 1.33-1.50 GB in quieter rounds and 1.19 GB in busy ones: it depends on how many workers top out together. Busy rounds are all the last build was measured in.

Without PGO, wall at `-j 16` fell by 7 to 10%. With PGO, ten interleaved rounds at a load average near 30 went from 1.74-2.06 s to 1.47-1.67 s, and eight at a load near 40 from 2.27-2.46 s to 1.83-2.02 s: 16 to 19%, not 30%. At `-j 1` the best round went from 14.12 s to 10.50 s, 26%. What holds it:

- `open` costs 89-128 us here against 2.5 us for `stat`, and throughput stops growing at 6 threads: 11214 files take 270-310 ms however many threads open them, and reading adds nothing. Relative `openat` from a directory fd is worse. Directory listings go through the same gate. A C program sees the same floor, so it is this machine and outside the compiler.
- Own time per visit in `check`: repeats are 14% and work for another file 5%, so no structural waste is left of a size that matters. Self time is flat: no function above 5%.
- Runs trade time for memory directly: memory follows run size at about 45 bytes per source byte, and every extra run rebuilds lib types. 24 runs per worker cost 2% of cycles over 16, and the peak needs them.

Tried without gain: fast hash contexts for the maps still on wyhash (same cycles, 0.7% more instructions), and keeping 6 or 8 chunks per worker instead of 4 (same wall, 100-200 MB more).

PGO is `scripts/pgo.sh`, because Zig has none: clang 23 compiles the bitcode Zig 0.17 writes before optimizing, with a profile of one check. It takes 150 s here, of which the check is 60 s.

| Build, VS Code `-j 16` | Instructions | Cycles |
| --- | --- | --- |
| `zig build` | 152 G | 55-57 G |
| clang, no profile | 152 G | 55 G |
| Profile of a small project (`apps/stator/packages/compiler`) | 120 G | 48 G |
| Profile of VS Code | 115 G | 47-50 G |
| Profile of VS Code, then context-sensitive | 115 G | 49 G |

So clang alone changes nothing, the gain comes from the profile, and most of it carries over to code it was not trained on. The context-sensitive second pass adds nothing and is not in the script. Small project, 3.29 G to 2.69 G instructions either way, wall still 0.1 s. The same bytes come out as from `zig build` at `-j` 4 and 16 on VS Code and on the small project.

### tsrs

Facts about tsrs's design come from https://github.com/oxc-project/tsrs at commit e18fb617ee516917342dcda27063ab67acc79e49, checked 2026-11-01; paths are from that tree. Numbers marked "here" were measured on this machine with the builds in the table above.

The gap is per thread, not in scheduling. One thread, three interleaved rounds, here:

| Compiler | Wall | User | Sys | Peak RSS |
| --- | --- | --- | --- | --- |
| stator-ts `-j 1` | 16.89-17.00 s | 15.1 s | 1.2 s | 1.60 GB |
| tsrs `--singleThreaded --fast` | 11.40-11.50 s | 9.8 s | 1.4-2.4 s | 2.04-2.05 GB |
| tsrs `--singleThreaded` | 11.78-11.86 s | 10.3 s | 2.1-2.2 s | 2.87-2.90 GB |

stator-ts is 1.48 times behind on one thread and 1.4-1.5 times behind on sixteen, and both scale about 8.5 times from one to sixteen. So tsrs's directory locality, work stealing, heavy-first order and file splitting (`docs/DEBUGGING.md`) are not what stator-ts lacks: free runs reach the same scaling.

`--fast` is not the source either. On one thread it saves 0.4 s of 11.8 s. With more checkers it buys wall time with instructions: VS Code goes from 121 G at 4 checkers to 133 G at 16 (`notes/perf-checker-stealing.md`), and `docs/USAGE.md` warns that extra checkers and caches can offset its savings. The lead is in the base compiler.

Where the time goes, here. tsrs on one thread spends 2.18 s parsing, 0.46 s binding and 8.40 s checking. stator-ts spends about 3 s loading and about 14 s checking, so loading is level and checking takes about 1.65 times as long. A 12 s `sample` of `-j 1`, 1782 busy samples: checker code 29%, hash maps 19%, relation 14%, file opens 11%, lexer 10%, flow 5%, allocator 5%. The window holds all of the load and about two thirds of the check, so file opens and the lexer weigh more than over a whole run. `relate.cached` is the largest single function at 9%. Parsing bodies on demand is about 6%, so T13's lazy bodies are not the gap.

What tsrs has that stator-ts has not:

- Smaller records in both modes: `Node` 24 bytes with its data in the same allocation, `Symbol` 32, `FlowNode` 16 (`docs/AST.md`), `Type` 24, `TypeMapper` 16 (`docs/CHECKER.md`). Ours: `Node` 80, `Type` 64, `Mapper` 32.
- Rounds of work on the checker that change representation only, the first worth -9.5% instructions (`notes/perf-checker-cpu2.md`).
- PGO, -13.5% instructions, and mimalloc, 3-14% of wall over the other allocators tried (`docs/RUST.md`, citing `notes/perf-pgo.md` and `notes/perf-build-level.md`).
- Memos: flow, -3.1% of check-phase instructions (`notes/flow-memo.md`); inference walk, -7.15% of VS Code's instructions (`notes/perf-heavy-files-infer-memo.md`); union front cache, -0.5% to -1.1% (`notes/perf-union-inference.md`). The last two are fast mode only (`docs/USAGE.md`).
- Lazy members, fast mode only. On a 37,942-file monorepo on one thread, symbols fall from 25,973,354 to 15,331,397, check from 26.32 s to 22.90 s, and peak from 15.34 GB to 11.77 GB (`notes/lazy-members.md`). Its counters on VS Code, here: 73,116 of 386,675 member tables resolved in full, 1,287,137 of 8,810,354 declared members instantiated.

What it costs: fast mode can add or remove diagnostics, move them, change their text and change the exit status (`docs/USAGE.md`), and work stealing varies placement between identical runs (`docs/DEBUGGING.md`). TanStack router gives 5, 7, 7 and 7 errors at 1, 4, 8 and 16 checkers against 5 at each for the Go port (`notes/open-history-dependence.md`). Over 19 projects diagnostics match by file, position and code; message text is outside that comparison (`bench/RESULTS.md`). stator-ts gives the same diagnostics at every `-j` and with one checker per file, and anything taken from tsrs has to keep that.

Not worth taking:

- Long-lived checkers. A tsrs checker never frees what it made for finished files, and the opt-in `--maxMemory 8G` turns 18.0 GB into 8.7 GB for 35% more instructions (`notes/mem-recycle-checkers.md`). T13's runs cost 0.2 s of CPU per worker.
- Lazy `.d.ts` member lists: 0 on VS Code (`notes/mem-lazy-dts-members.md`).
- Freeing finished leaf files: 321 MB of parse and bind output on VS Code (`notes/mem-free-leaf-files.md`), much of it function bodies that `check` no longer keeps in the shared tree.
- Types shared between checkers: tsrs's design note ends with no design meeting both constraints (`notes/design-shared-type-layer.md`), which agrees with T10 being worth little.

### pyrlyn/coroutines

Facts come from https://github.com/pyrlyn/coroutines at commit 65b74e7bf9617c7d4966542f923055c27f95565b, checked 2026-11-01. It is a coroutine library for Zig 0.17.0 under GPL-3.0-or-later (`LICENSE`), not a TypeScript compiler, so it has no row in the first table. Since T16 stator-ts's parallel passes run on it.

- `state_machine.runParallel` (`src/state_machine.zig`) hands out work with one atomic cursor and spawns and joins its threads for each call. Before https://github.com/pyrlyn/coroutines/pull/5 stacks were 1 MiB, the caller worked too and a task was not told its worker index, and stator-ts could live with none of the three. That pull adds `stack_size`, `caller_works` and `currentWorker()`. Since https://github.com/pyrlyn/coroutines/pull/7 a call spawns no more threads than it has chunks, so a pass over few items gets fewer workers than `-j`; the worker indices stay below `-j`. Since https://github.com/pyrlyn/coroutines/pull/9 a chunk shrinks towards 1 as the queue drains. Neither changes the order a chunk of 1 is handed out in, which `spreadTurns` depends on. https://github.com/pyrlyn/coroutines/pull/10 leaves tasks over two words in place; stator-ts's task is two words, a pointer and an index, so that path does not run.
- `state_machine.Cursor` is that queue on its own, moved there from stator-ts's `schedule.Cursor` by https://github.com/pyrlyn/coroutines/pull/6. stator-ts reaches it only through `runParallel`.
- `io.spawnEach` (`src/io.zig`) splits the items into `4 * CPU count` contiguous blocks and calls `std.Io.Group.async` once per block, since https://github.com/pyrlyn/coroutines/pull/11. stator-ts does not use it.

VS Code at `-j 16`, five interleaved rounds here, with other sessions keeping the load average near 20. Both builds printed the same bytes.

| Build | Wall | User | Sys | Peak RSS |
| --- | --- | --- | --- | --- |
| T13, persistent pool, Zig 0.16 | 2.49-2.96 s | 21.1-21.5 s | 2.4-2.5 s | 2.14-2.19 GB |
| T16, `runParallel`, Zig 0.17 | 2.50-3.02 s | 20.7-21.4 s | 2.3-2.6 s | 2.14-2.23 GB |

A two-file fixture, 150 alternating rounds here, takes a median of 19.3 ms on T13 and 19.7 ms with `runParallel`; the fastest rounds are 17.2 ms and 17.1 ms. So threads per pass cost a tiny project under 1 ms, and a persistent pool was not worth keeping.

The bump from 8b175b2 to 65b74e7 pays off only where a pass has fewer chunks than `-j`. Medians at `-j 16`, interleaved on the same machine, load average 5 to 10, printing the same bytes:

| Project | Rounds, wall / counters | Wall | Cycles | Instructions |
| --- | --- | --- | --- | --- |
| `tests/fixtures/function-body-across-files` | 150 / 30 | 18.66 → 17.83 ms | 85.2 → 71.9 M | 201.2 → 186.2 M |
| `apps/stator/packages/std` | 50 / 15 | 13.18 → 12.44 ms | 67.3 → 52.4 M | 120.8 → 104.3 M |
| VS Code | 7 / 5 | 1.435 → 1.419 s | 54.4 → 55.3 G | 151.8 → 152.1 G |

The fixture at `-j 4` stays level, 17.71 and 17.82 ms, as it should with few threads to save. On VS Code the wall ranges overlap, so that row is noise.

The rows below come from before T16: they reproduce the library's two schemes with stator-ts's own code and `std.Io` on Zig 0.16, built from T13's commit, and the library itself was not run. Same corpus and same `-j`, with another session loading the machine.

| Build | Wall | User | Sys | Peak RSS |
| --- | --- | --- | --- | --- |
| stator-ts, persistent pool | 2.12-2.79 s, one round 4.50 s | 19.4-19.9 s | 2.6-3.5 s | 2.16-2.22 GB |
| Threads per pass, 256 MiB stacks | 2.04-2.62 s | 19.4-19.9 s | 2.5-2.8 s | 2.11-2.18 GB |
| Threads per pass, 1 MiB stacks | 2.06-2.73 s | 19.3-19.9 s | 2.6-3.5 s | 2.09-2.21 GB |
| One `std.Io.Group` task per item | 2.74-3.62 s | 18.6-19.3 s | 3.2-7.1 s | 2.12-2.19 GB |

`check` makes 21 passes over VS Code, and a pass costs 0.03-0.04 ms on the pool against 0.21-0.23 ms spawning sixteen threads, about 4 ms a run. One `Group` task per item loses on wall and not on CPU. Once `async_limit` is reached, `Group.async` runs the task on the thread that spawns it (`std/Io/Threaded.zig`, Zig 0.16), so a slow run there stops work being handed out. That build also needs a big-stack thread to spawn from.

1 MiB is not enough. It passes VS Code and all 914 fixtures, but `compiler/binderBinaryExpressionStress` dies with SIGBUS, which costs one of the 8136 TS7 tests. It passes at 256 MiB.

On the library's own workload, 10,000 tasks of 4 times 256 xorshift64 rounds on 16 threads, medians of 25 in three processes here: sequential 16.8-17.8 ms, pool 1.7-2.4 ms, threads per pass 2.1-2.3 ms at 1 MiB and 2.5-2.6 ms at 256 MiB, `std.Io.Group` 13.3-15.7 ms. Its `README.md` publishes 17.3 ms sequential, 1.5 ms for `sm-parallel` and 30.2-32.6 ms for `io-group` on an M3 Max with Zig 0.17. That is another sitting and another compiler, so it shows only the same order.

The move buys no speed, and none was expected. Scheduling is not where stator-ts loses time to tsrs. A checker recurses, so it cannot yield in the middle of a file: a `step` is a whole pass item, and stackless coroutines have nothing to switch. `-j` now stops at the library's `max_threads`, 64.

TS7 suite (`microsoft/TypeScript` at 6161772c1370bdd4a82f808e6823bd755eb1870d, `tsc/testdata`): 13,737 tests, 8,136 pass (59.2%), 18,753 expected diagnostics missed, 9,949 extra. The largest gaps are unimplemented features: JS checking, JSX, node16 resolution modes, unused-symbol reports. A failing test often differs in one diagnostic, so the percentage understates the checker on ordinary code and says nothing about emit.

Facts from upstream at that commit: TS7's tests moved from the archived `microsoft/typescript-go` to `tsc/` in `microsoft/TypeScript`; `v7.0.2` has the older layout, which is why the pin is a commit. TS7 defaults differ from 5.9 (`strict`, `types: []`) and its messages put missing-property text on TS2345 and TS2344.


### T21

After the first T21 iteration the TS7 suite at the same commit passes 8,532 of 13,737 (62.1%), with no crashes; the task started at 8,233. The gains come from tsc's JavaScript rules (plain JS keeps only tsgo's `plainJSErrors`, `// @ts-check` and `// @ts-nocheck` decide the rest), tsc's `tryAddingExtensions` table in module resolution, JSDoc-typed parameters not reporting TS7006, and the binder's strict-mode checks (TS1100, TS1101, TS1102, TS1210, TS1212-TS1215, TS1262, TS1344).

`conformance/nodeAllowJsPackageSelfName` (4 variants) left `passing.txt`. tsc's harness runs it without a config file, so tsc reports TS2209 ("project root is ambiguous") next to TS2307, while `run.mjs` always writes `tsconfig.stator.json`. The gap is in the runner, not the checker.

Largest gaps left: `.js` files picked up by `include` under `allowJs`, the untyped-JS fallback (TS7016), ESM-mode and node16 resolution, import attributes on `declare module ... with {}`, top-level `await` followed by a newline in modules, JSDoc types and CommonJS checking, and a long tail of extra TS2339 and TS2304.
