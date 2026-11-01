---
status: in progress
priority: P0
complexity: 2
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T2. Parallel project scanning

Find a project's files from tsconfig or a directory and parse them in parallel.

Done: `scan` and `build` use all cores and report timings.

Plan: `src/scan.zig`, `src/tsconfig.zig`, CLI in `src/main.zig`. Verify on a large tree.
