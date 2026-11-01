# T14. Closing report

Done: every gap on the task's list now matches tsc 7, each with a fixture, and `var a;` over a parameter no longer crashes.

Commit: the commit that adds this report.

## What changed

- The binder words a duplicate by the symbol already there, so `let` over a parameter gives TS2300, and import or export specifiers are module references only at top level or in an ambient module. A body import's alias gives TS2307 when used.
- `resolveName` hides a function's variables from its parameters, including under the target rule that moves parameters into the body.
- `checkRedeclared` adds TS2403. It stays off under `exactOptionalPropertyTypes`, because stator-ts has no type for a missing property.
- `returnTypeFromBody` follows tsc for a body that only throws and for a bare call to itself, which it finds by the callee's type, not its name.
- `Checker.resolution` is tsc's `pushTypeResolution`: `returnOf`, `typeOfSymbol` and `typeFromNode` share it, and a cycle fails every entry from its start to the top. A null key is a wall: wherever stator-ts reads something earlier than tsc would, a cycle closing past the wall stays silent. Walls stand in `flowType`, around type relation of fresh literals, in messages, around pattern defaults, and around a function expression whose context does not compare its return.
- `checkInit` has tsc's quick path. A cycle depends on which initializers are read without their arguments: a call or `new` with one non-generic signature, a non-const assertion, and `await` of those. It skips parentheses only, so `binder.skipParens` now stands beside `stripParens`, which also drops assertions.
- A signature relation reads a return under resolution as `any`, a target property of `any` or `unknown` does not read the source, widening leaves accessors alone, and coming back to a function whose return is being read reads nothing.
- Accessors have no contextual signature. Their property can be what the context got from the very same literal.
- Object literal elaboration blames methods and accessors at their name.
- `reportConflict` reports in lib files, finding each declaration's file from its root, and `skipDefaultLibCheck` filters those diagnostics as the harness does.
- `checkStatementMods` and the module element checks add TS1184, TS1232, TS1234, TS1235 and the neighbours on the task's list.

Fixtures: `parameter-scope-duplicates`, `parameter-initializer-moved-to-body`, `inferred-returns`, `script-conflicts-with-lib`, `import-in-body-fails-on-use`, `import-in-body-after-dynamic-import`, `module-elements-in-bodies`, `module-elements-in-namespaces`, `circular-declarations`, `circular-typeof`, `circular-initializer-context`, `initializers-without-their-arguments`.

## How it was checked

- `zig build test` passes.
- `tests/differential.sh`: 1125 of 1128, 0 extra, exact column on 1121. The 3 misses are old.
- `tests/ts7/run.mjs`: 0 lost, 86 gained, on top of the 8136. The ratchet is raised to match.
- VS Code at commit c198526d, ReleaseSafe, `-j` 16 and 1: 388 of 388, none extra, no panic. The task's Check says 291, but tsc 7.0.2 gives 388 on this checkout with this tsconfig, so tsc's own output is what the run was compared with, by file, line, column and code.

VS Code caught what the fixtures did not: dropping `as` in the quick path gave 796 false errors, and 13 false cycles came from `new` initializers, methods reading their literal for `this`, and getters taking context from their own literal. All three now have fixture lines.

What was left out went to `ideas.md`: TS7022 through flow analysis stays silent, TS7032, `this` without `noImplicitThis`, and the codes that the fixtures showed but the task did not list.
