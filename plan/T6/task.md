---
status: in progress
priority: P1
complexity: 3
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T6. Run the TypeScript 7 test suite against stator-ts

The creator asked to take TypeScript 7's own tests with a script, run them here, and
keep the ability to sync. The fixtures in `tests/fixtures` only cover what we already
thought of; upstream's compiler and conformance suites cover the language.

Done means: one command fetches the tests and baselines at a pinned commit, one command
moves the pin, and one command runs them and reports exact-position diagnostic parity
per test, failing when a test that used to pass stops passing.

Plan:

1. `tests/ts7/sync.sh`: sparse checkout of `microsoft/TypeScript` into the ignored
   `tests/ts7/upstream/`, at the commit in `tests/ts7/upstream.lock`. With a ref
   argument it moves the pin. Takes cases, `.errors.txt` baselines, the bundled libs of
   the same commit, and a list of every baseline name.
2. `tests/ts7/run.mjs`: same unit splitting as upstream's `test_case_parser.go`, one
   project per test and per baseline variant, compare `(file, line, column, code)`.
3. `tests/ts7/passing.txt`: the tests that pass now, as a ratchet against regressions.
4. Record the results in `plan/README.md`, the commands in `README.md` and `AGENTS.md`.

Check: `bash tests/ts7/sync.sh` then `node tests/ts7/run.mjs` exits 0 and prints totals.
