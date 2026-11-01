---
status: todo
priority: P2
complexity: 5
readiness: 0%
agent:
---

# T10. Shared type layer across checkers

`todo.md` item 1. Each of the 16 checkers rebuilds lib and shared types: about 7-9 s of the 46 s of user and sys time on VS Code, with no memory gain expected.

Options: a frozen base plus side tables, fork after warming up (needs a Windows fallback), or partitioning by imports (unmeasured). The choice is the creator's.

Done means one option measured on VS Code against the same diagnostics.
