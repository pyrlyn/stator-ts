---
status: in progress
priority: P1
complexity: 3
readiness: 90%
agent: Claude Code / claude-opus-5-5
---

# T18. Fix false positives on apps/stator

`stator-ts check` reports errors on `apps/stator` where `tsc` reports none, which breaks the rule that a checker error must be a real error. Done means `check` matches `tsc` on `packages/compiler`, `node`, `std`, `tests`, `vite-stator` and `site`, with a fixture for each cause.

Causes:

1. Parser: a conditional type is allowed again below the type operator level, not only in an index or parentheses (`parser.zig`).
2. `[...Values]`: an element gets `Values[number]` as its context, so it keeps its literal type (`expr.zig`, `elemOfCtx`).
3. A module namespace or an enum has an inferable index; a type with call or construct signatures does not (`relate.zig`).
4. Under `exactOptionalPropertyTypes`, a property added by widening an object literal is absent, so an index signature ignores it (`types.zig`, `expr.zig`, `relate.zig`).
5. `moduleDetection`: `force` by default for `node16` to `nodenext`, and `.mts`, `.cts`, `.mjs`, `.cjs` are modules under `auto` (`project.zig`).
6. An assertion reached through `export { ok }` in a namespace resolves the alias first (`expr.zig`, `explicitType`).
7. `switch (typeof x)` can be exhaustive (`expr.zig`, `isExhaustive`).
8. `export { x }` in a namespace instantiates it unless `x` is only a type (`binder.zig`).
9. A module augmentation of an interface exported as `export { X }` reaches the interface (`project.zig`).

Steps: fix each cause, add its fixture in `tests/fixtures/`, raise `tests/ts7/passing.txt`.

Check: `check` and `tsc` both print 0 errors on the six packages; `zig build test` and `tests/differential.sh` pass; `node tests/ts7/run.mjs` loses nothing.
