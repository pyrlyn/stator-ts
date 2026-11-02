---
status: in progress
priority: P1
complexity: 5
readiness: 71%
agent: Claude Code / claude-opus-5-5
---

# T21. Pass every TypeScript 7 test

The creator asked for stator-ts to pass all of TypeScript 7's compiler and conformance tests run by `tests/ts7/run.mjs`. At the start 8233 of 13737 pass, 5503 fail and one crashes. The task stays open until every test passes; each iteration lands as its own PR that raises `tests/ts7/passing.txt`.

Order: the crash first, then extra diagnostics (errors tsc does not report break the rule that a checker error is a real error), then missed diagnostics, taking the causes that fix the most tests.

## Execution plan

1. Run the suite with `node tests/ts7/run.mjs --jobs 3` and group failures by cause from `tests/ts7/results/latest.json`.
2. Fix the crash, with a fixture.
3. Remove the largest groups of extra diagnostics (`TS2307`, `TS2304`, `TS2339`, `TS7006`, `TS1005`, ...) in `src/`, each fix with a fixture or unit test checked against tsc.
4. Then the largest groups of missed diagnostics.
5. Per iteration: `zig build test`, `tests/differential.sh` with no new extra or missed diagnostics, the TS7 run losing nothing from `passing.txt`, then `--update-passing`.

Check: `node tests/ts7/run.mjs --jobs 3` reports every test as passing, `zig build test` passes and `tests/differential.sh` keeps its counts.
