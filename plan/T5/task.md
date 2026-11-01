---
status: in progress
priority: P1
complexity: 2
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T5. Differential suite against tsc

Compare diagnostics with the real tsc so compatibility is a number and not an opinion.

Done: `tests/differential.sh` prints false positives and missed errors per fixture and overall.

Plan: script plus fixtures in `tests/fixtures/`.
