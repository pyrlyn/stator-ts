# T6. Closing report

`tests/ts7/sync.sh` fetches upstream's cases and `.errors.txt` baselines at the commit in `tests/ts7/upstream.lock`, and `sync.sh <ref>` moves the pin. `tests/ts7/run.mjs` runs each test and baseline variant as its own project and compares `(file, line, column, code)`. `tests/ts7/passing.txt` is the ratchet: a test that stops passing fails the run, and `--update-passing` raises it.

Commit: none, the project has no git repository of its own. Upstream's tests are not vendored.

Checked: at pin 6161772c1370bdd4a82f808e6823bd755eb1870d, 13,737 tests, 7,826 pass (57.0%), 5,911 fail, 0 crashes, 0 timeouts, 284 skipped by upstream, about 53 s; a plain run exits 0. Moving the pin was tried both ways: `sync.sh main` resolves to the same commit, and moving 30 commits back to c58faddd97051725bb27ee5e22da2d4cc3e0ec15 gave 13,716 tests, 7,799 pass, 0 lost, then back again.

Not covered: message text, emit, `.types`, `.symbols`, fourslash and transpile baselines.
