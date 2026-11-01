# stator-ts

Standalone TypeScript compiler in Zig 0.16 that emits JavaScript, aims for `tsc` compatibility, scans projects in parallel and runs tests on Node or Bun.

## Decisions

- Standalone project. It shares no code with `apps/stator`, whose frontend is the TypeScript compiler API.
- Output is JavaScript. Target is ES2022 or newer, modules are ESM; downleveling and CommonJS are on the roadmap.
- `lib.*.d.ts` files are found at run time (`--lib-dir`, `STATOR_TS_LIB`, then `node_modules/typescript/lib`), so they always match the project's TypeScript version.
- The emitter applies edits to source text, so comments and formatting survive.
- `tsc` compatibility is the goal and is measured by the differential suite; full parity is far larger than one task.
- Tests run on Node or Bun in a process pool, one process per test file.
- One persistent thread pool per process. Files are cut by path into runs, a free worker takes the next run and builds a fresh checker for it in its own arena, so memory follows the runs in flight and not the files checked so far. Results are byte-identical across runs at a fixed `-j`.
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

TS7 suite (`microsoft/TypeScript` at 6161772c1370bdd4a82f808e6823bd755eb1870d, `tsc/testdata`): 13,737 tests, 8,136 pass (59.2%), 18,753 expected diagnostics missed, 9,949 extra. The largest gaps are unimplemented features: JS checking, JSX, node16 resolution modes, unused-symbol reports. A failing test often differs in one diagnostic, so the percentage understates the checker on ordinary code and says nothing about emit.

Facts from upstream at that commit: TS7's tests moved from the archived `microsoft/typescript-go` to `tsc/` in `microsoft/TypeScript`; `v7.0.2` has the older layout, which is why the pin is a commit. TS7 defaults differ from 5.9 (`strict`, `types: []`) and its messages put missing-property text on TS2345 and TS2344.

