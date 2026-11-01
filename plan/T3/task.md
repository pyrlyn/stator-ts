---
status: in progress
priority: P0
complexity: 3
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T3. Test runner on Node and Bun

`stator-ts test` finds test files, compiles them and runs them in a process pool.

Done: describe, test, expect, hooks, filters, exit code, and crash handling work on both runtimes.

Plan: `src/testrun.zig`, `runtime/harness.mjs`. Verify with fixtures that pass, fail and crash.
