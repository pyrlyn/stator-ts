---
status: in progress
priority: P1
complexity: 5
readiness: 100%
agent: Claude Code / claude-opus-5-5
---

# T15. Catch tsrs on check time

T13 left VS Code at 1.89-2.03 s against 1.29-1.41 s for tsrs `--fast`, alternating the two on a quiet machine. The gap is the same on one thread, so it is work per thread, and `plan/README.md` puts it in the check phase: about 14 s against 8.4 s.

Done means `check` on VS Code at `-j 16` is level with tsrs `--fast` in interleaved rounds on a quiet machine, and `-j 1` is level with tsrs `--singleThreaded --fast`. If level cannot be reached, the closing report says what was gained and what stands in the way.

Check: VS Code stays at 291 of 291 by file, line and code with none extra at `-j` 1, 2, 4, 8 and 16; `tests/differential.sh` keeps 911 of 914 with none extra; `tests/ts7/run.mjs` loses none of the 8136; a small project is not slower; peak memory stays below tsrs `--fast`.

## Execution plan

1. Baseline: this tree, 189 G instructions and 18.7 s at `-j 1`, 215 G and 2.1-2.2 s at `-j 16`. Instructions are the measure while working, since wall is noisy; interleaved rounds against tsrs at the end.
2. Profile `-j 1` over the whole run with symbols and call stacks, and count what the hash maps are asked.
3. Cut the largest costs in order, one change at a time, each measured: expressions evaluated twice first, then what the profile shows, then flow and inference-walk memos.
4. A memo must not make a result depend on what ran before it: compare the diagnostics of VS Code after every step, and at the end with one checker per file.
5. Full check, race tsrs, record the numbers in `plan/README.md` and `ideas.md`.

Files: `src/relate.zig`, `src/types.zig`, `src/checker.zig`, `src/decls.zig`, `src/expr.zig`, `src/flow.zig`, `build.zig`, `plan/README.md`, `ideas.md`.
