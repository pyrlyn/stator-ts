`stator-ts check` matches tsc on `apps/stator`: 0 errors on `packages/compiler`, `node`, `std`, `tests`, `vite-stator` and `site`. Before it printed 11, 0, 0, 234, 6 and 0 on the base commit, with `type-fest` no longer stopping `check` since T17.

Commit d67b14e fixes the nine causes listed in `task.md`, with 16 fixtures. T17's reset of `no_cond_type` in tuples went too: the type operator level covers it.

Checked: `zig build test` passes; `tests/differential.sh` gives 0 false positives over all fixtures and 3 misses, the same 3 as before this task; the TS7 suite passes 8232 of the ratchet with 0 lost, 10 of them new. The VS Code corpus was not run: it is not on this machine.

`tests/differential.sh` fails on Node 26 when `TSC` is set: its `node -e` has a top-level `return`. Not changed here.
