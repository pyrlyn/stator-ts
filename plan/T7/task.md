---
status: in progress
priority: P2
complexity: 3
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T7. Persistent thread pool and split pool modules

`todo.md` items 4 and 7: `src/pool.zig` spawned threads per call and mixed three concerns.

Done means one pool per process and separate thread and scheduling modules, with diagnostics unchanged.
