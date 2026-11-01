# T11. Closing report

Done: `check` on VS Code takes 2.48-2.57 s, against 5.3-5.4 s for tsc-rs's default mode and 3.0-3.8 s for `--fast`, measured in five interleaved rounds. It reports exactly tsc 7's 291 errors, where tsc-rs reports those 291 plus 11 false ones.

Commit: none, the project has no git repository of its own.

## Before and after

VS Code at `-j 16`, ReleaseFast. Wall times of the rows are from single runs and vary with load, so only the final interleaved rounds compare compilers.

| Step | Wall | User + sys | RSS | False positives | Missed |
| --- | --- | --- | --- | --- | --- |
| Start | 6.4-7.3 s | 51-56 s | 21-28 GB | 519 | 91 |
| Array shortcut in inference, `definitelyUnrelated` | 4.3-4.9 s | 34-35 s | 25-26 GB | 507 | |
| First answer stands on `call` and `new` | 3.33-3.41 s | 29 s | 22.8 GB | 504 | |
| Relation stops on deep nesting (limit 3) | 2.67 s | 22.5 s | 16 GB | 501 | |
| Fresh stacks, array identity, generator channels | 3.04 s | 24.4 s | 20.6 GB | 495 | |
| Variance `Unknown`, `in`/`out` | 2.81 s | 22.3 s | 15.7 GB | 492 | |
| Narrowing, apparent types, loop tracking | 2.61-2.76 s | 22.9 s | 15.7 GB | 464 | |
| Literal returns, tuples, destructuring, mapped access | 2.72 s | 22.4 s | 15.6 GB | 354 | |
| Discriminated relation, conditional constraints, rest context | 2.32-2.38 s | 22.6 s | 15.6 GB | 298 | |
| Excess checks, spreads, enums, aliases, modifiers | 2.44 s | 22.7 s | 16.1 GB | 100 | |
| Auto-typed variables, `t_unresolved`, TS7034/TS7005, overrides | 2.34 s | 23 s | 16.2 GB | 65 | 0 |
| Skip pass, type queries, unions and predicates | 2.53-2.69 s | 23.4 s | 15.9 GB | 22 | 0 |
| Setter annotation, common supertype, base signatures | 2.40-2.69 s | 23.4 s | 16.1 GB | 13 | 0 |
| `super`, generic mapped sources, reduced intersections | 2.68 s | 23.4 s | 16.1 GB | 4 | 0 |
| Array literal candidates, truthiness on intersections, `typeof` on objects | 2.51-2.70 s | 23.5 s | 16.1 GB | 0 | 0 |

The plan said temporary lists first. The order turned out otherwise: profiling showed the time in inference and relation walks that never needed to run, so those went first, and no separate pass over temporary lists was made. The cost fell because the work went away, and memory fell with it, but that item stays in `ideas.md`.

## Final measurement

| Compiler | Wall | User + sys | Peak RSS |
| --- | --- | --- | --- |
| stator-ts | 2.48-2.57 s | 23-24 s | 15.7 GB |
| tsc-rs 0.8.0 `--fast` | 3.0-3.8 s | 24 s | 7.8 GB |
| tsc-rs 0.8.0 | 5.3-5.4 s | 19 s | 6.9 GB |
| tsc 7.0.2 | 10.6-10.8 s | 50-56 s | 9.9-10.5 GB |

Not reached: memory. stator-ts uses about twice tsc-rs's memory, and more CPU than tsc-rs's default mode. `plan/README.md` has the conclusions.

## Checked

- VS Code: 291 errors at each of `-j` 1, 2, 3, 4, 6, 8, 12, 16, the same set of file, line and code as tsc 7 every time.
- `zig build test` clean.
- `tests/differential.sh`: 879 expected, 876 matched, 0 false, 3 missed, exact column on 872. The 3 are old: `private-name-in-type-query`, `constraint-position-narrowing` line 19 TS2536, `mapped-known-keys-generic-index` line 10 TS2339.
- `tests/ts7/run.mjs`: 0 lost against the ratchet, which rose from 7,826 to 8,136 known passing.

One step has no fixture of its own: the fresh stacks. Its effect shows only at VS Code's size.
