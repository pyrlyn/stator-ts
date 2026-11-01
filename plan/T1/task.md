---
status: in progress
priority: P0
complexity: 4
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T1. Lexer, parser, emitter

Parse all of TypeScript including TSX and emit JavaScript.

Done: real-world TypeScript and every vendored lib.d.ts parse with no false syntax errors, and emitted code runs on Node.

Plan: `src/lexer.zig`, `src/ast.zig`, `src/parser.zig`, `src/emit.zig`. Verify on the stator compiler sources and the TypeScript lib files.
