---
status: in progress
priority: P1
complexity: 4
readiness: 90%
agent: Claude Code / claude-opus-5-5
---

# T20. Library API for embedding the checker

Stator's compiler moves to Zig on top of stator-ts, so the checker has to work as a library: one
long-lived checker over a loaded program, questions about any node, and a way to tell a type the
checker gave up on from a real one. Done means `Session` answers what Stator's lowering asks of
`ts.TypeChecker`, and `stator-ts types` dumps each expression's type for comparison with `tsc`.

## Plan

1. Export `src/lib.zig` as the `stator_ts` module.
2. `src/session.zig`: `Session` with types, symbols, signatures and flags at a node.
3. `types` command printing path, span, kind, degraded and type.
4. Fix what Stator's type differential finds, each fix with a fixture checked against `tsc`.

Check: `zig build test`, `tests/differential.sh` and `node tests/ts7/run.mjs` pass and
`tests/ts7/passing.txt` does not drop.
