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

