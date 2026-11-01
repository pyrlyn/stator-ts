# T8. Closing report

Output directories are now created once. Memory-mapped reads and the barrier-free queue were dropped.

Commit: none, the project has no git repository of its own.

Checked on VS Code, ReleaseFast, 16 threads: emit fresh about 830 ms before and 850 ms after, so no gain; emit rerun about 767 ms before and 717 ms after. `mmap` for files of 64 KiB or more made it worse (parse 325-418 ms became 446-552 ms, sys 1.4 s became 2.3 s). Batched writes were not done and `copyAssets` stays serial.
