# T15. Closing report

Level was not reached. `check` on VS Code went from 188.6 G to 131.9 G instructions at `-j 1` and from 215 G to 156 G at `-j 16`, with the same diagnostics, and tsrs `--fast` is still ahead on both: 19% in wall time on one thread, and at `-j 16` about 20% between best runs, though the medians of a loaded race came out level.

Commit: the commit that adds this report.

## Before and after

VS Code, ReleaseFast, `/usr/bin/time -l`. The machine was busy with other sessions, load average 8 to 14, so the race is not the quiet machine the task asked for. Instructions and cycles are the working measure; wall in this table is the same sitting, interleaved.

| Build | Wall | User + sys | Instructions | Cycles | Peak |
| --- | --- | --- | --- | --- | --- |
| T13 `-j 1` | 18.72 s | | 188.6 G | 59.0 G | 1.60 GB |
| T15 `-j 1` | 14.26-14.35 s | 13.6 s | 131.9 G | 48.4-48.7 G | 1.76-1.89 GB |
| tsrs `--singleThreaded --fast` | 11.89-12.17 s | 12.0 s | 99.9-100.0 G | 42.4-43.0 G | 2.18-2.20 GB |
| T13 `-j 16` | 2.08-2.23 s | | 215 G | 76 G | 2.22 GB |
| T15 `-j 16` | 1.61-2.09 s, median 1.68 s | 17.4-18.5 s | 154.9-156.7 G | 59.3-62.7 G | 2.43-2.56 GB |
| tsrs `--fast` | 1.33-2.22 s, median 1.71 s | 13.8-15.0 s | 111.0-113.0 G | 46.5-51.0 G | 2.71-2.74 GB |

So stator-ts is 1.19 times behind tsrs in wall on one thread, down from 1.48 at T13, and spends 1.14 times its cycles there and about 1.2 times on sixteen. Peak stays below tsrs `--fast`; it rose from T13 with the memos and with 16 runs per worker instead of 24.

At each job count, final build:

| `-j` | Wall | Instructions | Cycles | Peak | Match of 291 |
| --- | --- | --- | --- | --- | --- |
| 1 | 14.66 s | 131.8 G | 48.4 G | 1.76 GB | 291, none extra |
| 2 | 7.67 s | 135.9 G | 49.2 G | 1.80 GB | 291, none extra |
| 4 | 4.13 s | 141.3 G | 51.1 G | 1.92 GB | 291, none extra |
| 8 | 2.54 s | 148.3 G | 54.5 G | 2.05 GB | 291, none extra |
| 16 | 1.87 s | 156.6 G | 59.7 G | 2.28 GB | 291, none extra |

A small project is not slower: `tests/fixtures/function-body-skip` takes 253-254 M instructions against 254-263 M on HEAD, in 30 MB.

Runs per worker at `-j 16`, instructions and peak: 4, 145 G, 3.5 GB; 8, 150 G, 2.8 GB; 12, 154 G, 2.5 GB; 16, 157 G, 2.25 GB; 24, 165 G, 2.1 GB. Sixteen is the choice: more runs rebuild lib types more often, fewer hold more at once and pass the peak of tsrs.

## What changed

Most of the time went on visiting one expression again. A call visits its arguments on every overload and every inference pass, and the same initializer was visited for a declaration's type and again on its turn. Repeat evaluation fell from 5.48 s to 1.68 s of `-j 1`.

- `src/expr.zig`, `src/types.zig`: `quiet_debt` counts what quiet visits left undone, errors held back and work only the open visit does. Everything that skips work under `c.silent` goes through `quiet()`. A visit that left the debt alone can stand for the open one, and `quiet_funcs` lists the lambdas it met, to be queued when the open visit does not happen.
- `src/expr.zig`: `checkRef` keeps the type of a reference, `checkCall` and `keepAnswer` the answer of a call, `settleArgs` skips arguments the chosen signature need not visit again, `checkInit` and `settled_inits` skip an initializer on its own turn.
- `c.cycles` counts cycles and depth limits through `metCycle`. What a visit got past one is a stand-in, so it is not kept. The four guards in `src/decls.zig`, both depth limits in `src/flow.zig`, `resolving_calls` and a running `effectsSig` all count.
- `src/expr.zig`: a statement-level call read for its effects runs `checkCall`, so its turn finds the answer ready.
- `src/flow.zig`: `matchingRef` compares names before looking up symbols.
- `src/project.zig`: `readFile` is one read into a buffer of the file's size.
- `src/checker.zig`: 16 runs per worker instead of 24, which took 8 G instructions off `-j 16`.

## How it was checked

- `zig build test`.
- `tests/differential.sh`: 932 of 935 with none extra, the same three missed as T12 and T13, exact column on 928 of 932. The rise from 911 is the new `settled-visits` fixture.
- `tests/ts7/run.mjs`: 8136 known passing, 0 lost, 1 gained, `compiler/exhaustiveSwitchTupleLengthFallthrough`, added to `passing.txt`.
- VS Code at `-j` 1, 2, 4, 8 and 16: output identical to T13 at every count.
- One checker per file over all of VS Code, in a throwaway build with `runs_per_worker` and `least_run_bytes` off: 291 of 291 with none extra. One message text differs from a normal run, `Type '{}'` for `Type 'PermissionRequestHandler'` in `browserSessionTrust.test.ts`, on HEAD built the same way too; that output is identical to this one.
- VS Code on a ReleaseSafe build at `-j 8`: identical output, no panic.
- `tests/fixtures/settled-visits` covers each skip, and matches `tsc` on all 21 errors. Each of ten mutations of the skips, in a scratch copy, breaks it: dropping the lambda replay of an argument or an initializer, ignoring the debt or the lambdas in a call, a reference or an initializer, leaving `narrowableRef` out of the debt, and leaving the depth limit out of the cycles. The last one reproduces the 20 false TS18048 this task hit on VS Code, which take a function called before its turn, so that the search for its return type reads the assertions from the end.
- Five interleaved rounds at `-j 16` and three at `-j 1` against tsrs: the table above.

## What stopped it

The curve is flat: what is left of the self time at `-j 1` is spread out, `openat` 8.5% of samples, `relate.cached` 6.6%, property lookup 4.6%, the lexer 7%, the arena 3.5%. These were tried and gave nothing: a semaphore on file reads (worse at 2 and 4, no change at 6 and 8), a memo of an argument per parameter and answer, a small table in front of `relation_cache` (131.6 G, cycles flat), and answering `FsCache.isFile` from the root files.

At `-j 16` two things stand between it and tsrs. Checkers repeat each other's work, 156 G against 132 G, and only a shared type store or fewer runs would cut that, the second at the price of memory. And file reads do not scale: at 4 threads or more the machine reads VS Code in about 300 ms however it is asked, so cumulative read time goes from 1.05 s at `-j 1` to 5.76 s at `-j 16`.

Instantiating members lazily, as tsrs does, is the largest piece left and would give at most about 5%: `resolveIface` is 698 of 12.4 k samples. PGO is untried.

## Merging with T14

`t14-tsc-gaps` adds a resolution stack with `closeCycle` and changes `typeOfSymbol` and `returnOf`, which conflicts with the `metCycle` lines in `src/decls.zig`. `closeCycle` has to bump `c.cycles`, or a stand-in from a closed cycle gets kept. T14's TS7022 and TS7023 are why `settled-visits` has no cycle case: add one there after the merge.
