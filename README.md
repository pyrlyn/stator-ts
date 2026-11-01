# stator-ts

A TypeScript compiler written in Zig.

```bash
stator-ts check            # type-check the project
stator-ts build            # type-check and emit JavaScript
stator-ts scan             # parse the whole project in parallel, print stats
stator-ts test             # compile and run *.test.ts files in parallel on Node or Bun
```

Build with Zig 0.17.0: `zig build -Doptimize=ReleaseFast`.

On macOS, `scripts/pgo.sh` builds `zig-out/bin/stator-ts-pgo` with profile-guided optimization, which needs clang and a project to train on. On VS Code it runs 26% fewer instructions and takes 16-19% less time at `-j 16`, with the same output.

`--all-diagnostics` also shows semantic errors when the project has syntax errors, which the default, like the tsc command line, holds back.

## Performance

A two-file project, `tests/fixtures/function-body-across-files`, at default threads. Medians of 150 interleaved rounds on an Apple M3 Max:

| Compiler | Wall | Cycles | Instructions | Peak RSS |
| --- | --- | --- | --- | --- |
| stator-ts | 19.7 ms | 68 M | 186 M | 22.4 MiB |
| tsrs `--fast` | 39.5 ms | 327 M | 939 M | 58.5 MiB |
| tsc-rs `--fast` | 53.1 ms | 262 M | 900 M | 79.8 MiB |
| tsc 7.1.0-beta | 131.2 ms | 795 M | 2,362 M | 91.9 MiB |

All four report 11 errors. Native binaries: stator-ts `0a38da8` built with ReleaseFast and no PGO, tsrs 0.20.1-ts7.1.0-beta, tsc-rs 0.8.0, typescript 7.1.0-beta.

## Tests

```bash
zig build test                      # unit tests
bash tests/differential.sh          # fixtures against the real tsc
bash tests/ts7/sync.sh              # fetch TypeScript 7's tests at the pinned commit
bash tests/ts7/sync.sh main         # move the pin to a newer commit
node tests/ts7/run.mjs              # run them, fail if a passing test stopped passing
node tests/ts7/run.mjs --update-passing   # record newly passing tests
```

`run.mjs` also takes `--filter <regex>`, `--limit <n>`, `--jobs <n>`, `--verbose` and `--keep`, and `STATOR_TS` picks the binary. Results land in the ignored `tests/ts7/results/`.

