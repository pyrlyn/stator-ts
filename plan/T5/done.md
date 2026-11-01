# T5. Closing report

`tests/differential.sh [-v] [project-dir...]` compares diagnostics with the real `tsc` per fixture and overall by file, line and code, and counts exact columns. A crash counts as a failure, not as zero false positives. `TSC`, `STATOR_TS` and `STATOR_TS_LIB` pick what is compared.

Commit: none, the project has no git repository of its own.

Checked: 101 fixtures. Against TypeScript 7.0.2: tsc 180, ours 170, match 169, false positives 1, missed 11. Against the pinned 5.9.3: tsc 174, ours 170, match 163, false positives 7, missed 11. It exits 1 until false positives reach zero, so it exits 1 today. The 5.9.3 gap comes from messages TS7 changed; the pin needs the creator's permission to move.
