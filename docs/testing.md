# Testing

```bash
zig build test                      # unit tests
bash tests/differential.sh          # fixtures against the real tsc
bash tests/ts7/sync.sh              # fetch TypeScript 7's tests at the pinned commit
bash tests/ts7/sync.sh main         # move the pin to a newer commit
node tests/ts7/run.mjs              # run them, fail if a passing test stopped passing
node tests/ts7/run.mjs --update-passing   # record newly passing tests
```

`run.mjs` also takes `--filter <regex>`, `--limit <n>`, `--jobs <n>`, `--verbose` and `--keep`, and `STATOR_TS` picks the binary. Results land in the ignored `tests/ts7/results/`.

## Rules for changes

- Every fixed bug gets a fixture in `tests/fixtures/` or a unit test, checked against the real `tsc`.
- Compatibility claims come from `tests/differential.sh`, not from reading the code.
- Run `tests/differential.sh` with `STATOR_TS` set; without it the script rebuilds `zig-out`.

See [AGENTS.md](../AGENTS.md) for the full list.
