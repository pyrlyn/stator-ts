# T3. Closing report

`stator-ts test` finds test files, compiles them and runs one process per file on Node or Bun, with describe, test, expect, hooks, filters, exit codes and crash reporting. Path filters now see the path inside the project, and the harness's result line no longer shows up in a failed file's output.

Commit: none, the project has no git repository of its own.

Checked: a scratch project with a passing, a failing and a crashing test file on both runtimes: `files: 1 passed, 2 failed, 3 total`, `tests: 1 passed, 1 failed, 0 skipped`, exit code 1, crash shown as `exit code 3`. The two fixes have unit tests in `src/testrun.zig`; `zig build test` passes 24 of 24.
