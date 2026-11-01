---
status: in progress
priority: P2
complexity: 4
readiness: 95%
agent: Claude Code / claude-opus-5-5
---

# T14. Close the tsc gaps found in T13's fixtures

Writing T13's fixtures turned up places where stator-ts and tsc 7 disagree. They were left out of the fixtures so T13 stayed about memory. A crash belongs on the same list: `var a;` over a parameter panics in `autoTyped`.

Done means each gap below has a fixture that matches tsc 7, and nothing else moved.

- `let`, `const` or `class` over a parameter gives TS2300, not TS2451.
- A `var` or `let` in a body is out of scope for a parameter initializer: TS2304, not TS2454.
- TS2403 for a later `var` of another type, over a parameter, a `var` or a global.
- `var a;` over a parameter does not crash.
- A function declaration or class method that only throws infers `void`; a bare call to itself contributes nothing.
- TS7023 and TS7022 for return types and initializers that reach themselves.
- TS2451 and TS2300 reported in `lib.dom.d.ts` too for a script's `top`, `name`, `self`.
- Grammar: TS1184, TS1232, TS1234, TS1235, and with them TS1231, TS1233, TS1258, TS1147, TS1194, TS1319.
- An import in a body is not a module reference of the file, so its alias gives TS2307 when used, even for a module that exists.

Check: `tests/differential.sh` has no extra errors and its match count only rises; `tests/ts7/run.mjs` loses none of the 8136; VS Code stays at 291 of 291 with none extra at `-j` 1 and 16; a ReleaseSafe build panics on none of them.

## Execution plan

1. Fix the binder's duplicate message, keyed on the symbol already there, as tsc does (`src/binder.zig`).
2. Make `resolveName` hide a function's variables from its parameters (`src/decls.zig`).
3. Add TS2403, and fix `autoTyped` for a value declaration that is a parameter (`src/checker.zig`, `src/expr.zig`).
4. Add `mayReturnNever` and the bare self-call rule to `returnTypeFromBody` (`src/expr.zig`).
5. Add a resolution stack shared by `returnOf` and `typeOfSymbol`, so every member of a cycle reports (`src/decls.zig`, `src/types.zig`).
6. Report global conflicts in lib files (`src/project.zig`, `src/driver.zig`).
7. Add the module element checks and modifier checks (`src/checker.zig`).
8. Stop body imports from reaching the file's module list (`src/binder.zig`, `src/parser.zig`).
9. One fixture per group, then the full check above.

Files: `src/binder.zig`, `src/parser.zig`, `src/decls.zig`, `src/checker.zig`, `src/expr.zig`, `src/types.zig`, `src/project.zig`, `src/driver.zig`, `tests/fixtures/`, `ideas.md`.
