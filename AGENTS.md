# stator-ts

A TypeScript compiler written in Zig 0.16: parses TypeScript, type-checks it, emits JavaScript, scans projects in parallel and runs their tests on Node or Bun.

If an `AGENTS.md` or `CLAUDE.md` exists higher in the tree, follow it too; on conflict, ask the creator.

## Commands

- `zig build` builds `zig-out/bin/stator-ts`.
- `zig build test` runs the unit tests.
- `tests/differential.sh` compares diagnostics with the real `tsc`: tsc 7, the compiler stator-ts follows, pinned in `tests/package.json`.
- `bash tests/ts7/sync.sh [ref]` fetches TypeScript 7's tests at `tests/ts7/upstream.lock`, or moves the pin.
- `node tests/ts7/run.mjs` runs them against `tests/ts7/passing.txt`; `--update-passing` raises the ratchet.

## Rules

- A checker error must be a real error. When the checker cannot model something it degrades to `any` and stays silent; it never guesses.
- Compatibility claims come from `tests/differential.sh`, not from reading the code.
- Every fixed bug gets a fixture in `tests/fixtures/` or a unit test, checked against the real `tsc`.
- Run `tests/differential.sh` with `STATOR_TS` set: without it the script rebuilds `zig-out`.
- Everything mutable during checking lives in `Checker`. The AST and symbols are read-only after binding, which is what makes parallel checking safe.
- A checker lasts one run of files. Nothing it allocates outlives `runFiles` but the diagnostics that copies out, and a function body it parses and binds is its own, so `bindBody` writes nothing outside the block.
- `check` leaves function bodies unparsed; anything that needs one goes through `decls.bodyOf`, not `Func.body`.
- Whatever a visit skips under `c.silent` goes through `expr.quiet`: a later visit stands for the open one only if the debt did not move.
- Whatever returns a stand-in at a cycle or a depth limit calls `c.metCycle`, so the answer built on it is not kept.
- The emitter rewrites source text through edits. It never reprints the AST.
