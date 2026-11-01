# stator-ts

Standalone TypeScript compiler in Zig 0.16 that emits JavaScript, aims for `tsc` compatibility, scans projects in parallel and runs tests on Node or Bun.

## Decisions

- Standalone project. It shares no code with `apps/stator`, whose frontend is the TypeScript compiler API.
- Output is JavaScript. Target is ES2022 or newer, modules are ESM; downleveling and CommonJS are on the roadmap.
- `lib.*.d.ts` files are found at run time (`--lib-dir`, `STATOR_TS_LIB`, then `node_modules/typescript/lib`), so they always match the project's TypeScript version.
- The emitter applies edits to source text, so comments and formatting survive.
- `tsc` compatibility is the goal and is measured by the differential suite; full parity is far larger than one task.
- Tests run on Node or Bun in a process pool, one process per test file.
- One persistent thread pool per process; N independent checkers over a static, path-sorted partition, so results are byte-identical across runs at a fixed `-j`.
- `check` and `build` follow the tsc command line: semantic errors stay hidden while syntax errors exist. `--all-diagnostics` shows both, as tsc's test harness does.
- TypeScript 7's tests are fetched by script and never vendored.

## Findings

Reference: VS Code commit c198526d8e64ba6f9944e9f7bcc079ed1f6d7fcc, `src/tsconfig.json`; TypeScript 7.0.2 (npm) with its bundled libs; 16 threads, ReleaseFast.

| Compiler | Wall | User + sys | Peak RSS | Match of 291 | False positives | Missed |
| --- | --- | --- | --- | --- | --- | --- |
| stator-ts `check` | 2.32-2.71 s | 22-23 s | 9.8 GB | 291 | 0 | 0 |
| tsc-rs 0.8.0 `--fast` | 3.0-3.5 s | 24-25 s | 7.8 GB | 291 | 11 | 0 |
| tsc-rs 0.8.0 | 5.2-5.6 s | 18-19 s | 6.9 GB | 291 | 11 | 0 |
| tsc 7.0.2 | 10.4-11.1 s | 53-58 s | 9.8-10.5 GB | 291 | 0 | 0 |
| tsc 6.0.2 (JS) | 133.91 s | | 11.29 GB | | | |

The first four rows come from five interleaved rounds of the finished T12 build; tsc 6.0.2 from an earlier sitting. An earlier, quieter set of five rounds on the T11 build gave stator-ts 2.11-2.39 s, tsc-rs `--fast` 2.72-2.75 s with one run at 3.98 s, tsc-rs 4.92-4.99 s and tsc 7 9.51-9.80 s. Diagnostics compare file, line and code against tsc 7. tsc-rs comes from npm, source https://github.com/pingdotgg/ts-rust; `--fast` reports the same set.

So stator-ts is the fastest of the four on VS Code: about 1.3x ahead of tsc-rs `--fast`, 2.3x ahead of its default mode and 4.5x ahead of tsc 7, and it reports exactly tsc 7's 291 errors. Diagnostics are the same at `-j` 1, 2, 4, 8 and 16. It spends more CPU than tsc-rs's default mode, 22-23 s against 18-19 s, and a little less than `--fast`.

Memory is level with tsc 7 and still behind tsc-rs: 9.8 GB against 9.8-10.5 GB and 6.9-7.8 GB. T12 took it down from 15.7 GB. One checker alone takes 8.7 GB (`-j 1`, 17.01 s, 14.41 s user), and sixteen cost only 1.1 GB and about 6 s of CPU more than one, so T10's sharing can win little of either. What is left is real data: about 3.2 GB of AST and symbols, then the properties, types, objects and signatures a checker builds, with no allocation site above 6%. Going lower needs something new, not a local change: see `ideas.md`.

TS7 suite (`microsoft/TypeScript` at 6161772c1370bdd4a82f808e6823bd755eb1870d, `tsc/testdata`): 13,737 tests, 8,136 pass (59.2%), 18,753 expected diagnostics missed, 9,949 extra. The largest gaps are unimplemented features: JS checking, JSX, node16 resolution modes, unused-symbol reports. A failing test often differs in one diagnostic, so the percentage understates the checker on ordinary code and says nothing about emit.

Facts from upstream at that commit: TS7's tests moved from the archived `microsoft/typescript-go` to `tsc/` in `microsoft/TypeScript`; `v7.0.2` has the older layout, which is why the pin is a commit. TS7 defaults differ from 5.9 (`strict`, `types: []`) and its messages put missing-property text on TS2345 and TS2344.

