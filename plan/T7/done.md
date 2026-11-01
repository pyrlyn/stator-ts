# T7. Closing report

One `ThreadPool` is created in `main.zig` and reused; `src/pool/threads.zig` and `src/pool/schedule.zig` hold the threads and the static partition. Work stealing was left out: the partition is already even and the serial part is 38 ms of about 5 s.

Commit: none, the project has no git repository of its own.

Checked: diagnostics on VS Code are identical before and after. There is no real wall-time gain, so this is a cleanup, not a speedup.
