# T2. Closing report

`scan`, `check` and `build` find files from tsconfig, read and parse them on one persistent thread pool and print timings.

Commit: none, the project has no git repository of its own.

Checked: `stator-ts scan -p src/tsconfig.json` on VS Code ran on 16 threads: walk 112 ms, parse 416 ms, 175,822,664 bytes.
