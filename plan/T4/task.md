---
status: in progress
priority: P0
complexity: 5
readiness: 70%
agent: Claude Code / claude-opus-5-5
---

# T4. Binder and type checker core

Symbols, declaration merging, lib.d.ts, structural types, generics, inference, narrowing, conditional and mapped types, and diagnostics in tsc format.

Done: common code is checked with the same error codes as tsc and no known false positives on the corpus.

Plan: `src/binder.zig`, `src/types.zig`, `src/checker.zig`, `src/program.zig`. Verify with T5.

Execution plan: take the largest group of remaining false positives from VS Code, reduce it to a fixture in `tests/fixtures/`, fix it in `src/expr.zig`, `src/relate.zig`, `src/flow.zig` or `src/decls.zig`, then rerun `tests/differential.sh` and `tests/ts7/run.mjs`. Every fixed bug keeps its fixture. Open until the false positives on the corpus reach zero; current numbers are in `plan/README.md`.
