# Architecture

A run goes through these stages, each in its own file under `src/`:

| Stage | File | Role |
| --- | --- | --- |
| CLI | `main.zig` | Parses arguments, loads the config, dispatches the command. |
| Project | `project.zig` | Loads tsconfig (with `extends`), finds root files, resolves modules and libs, builds the `Program`. |
| Lexer, parser | `lexer.zig`, `parser.zig`, `ast.zig` | Tokens and the syntax tree. `check` parses function bodies lazily (`parseLazily`, `parseBody`). |
| Binder | `binder.zig` | Symbols, scopes and the control-flow graph, one file at a time, in parallel. |
| Checker | `checker.zig`, `types.zig`, `decls.zig`, `expr.zig`, `relate.zig`, `flow.zig`, `print.zig` | Statements, declaration types, expression types, type relations and inference, narrowing, type printing. |
| Driver | `driver.zig` | Collects and prints diagnostics; for `build`, runs the emitter. |
| Emitter | `emit.zig` | Produces JavaScript by editing the source text; it never reprints the AST. |
| Test runner | `testrun.zig`, `harness.mjs` | The `test` command. |
| Support | `pool.zig`, `pool/`, `bump.zig`, `spelling.zig` | Thread pool and scheduling, the per-thread bump allocator, "Did you mean" suggestions. |

## Parallelism

Parsing, binding, checking and emitting all run on a `ThreadPool` (`-j`). Each checker worker owns
one `Checker` and every type it creates; types are never shared across threads. The AST and
symbols are read-only after binding, which is what lets files be checked in parallel without
locks. Files are partitioned up front, so results do not depend on timing.
