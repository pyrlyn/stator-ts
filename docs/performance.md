# Performance

A two-file project, `tests/fixtures/function-body-across-files`, at default threads. Medians of 150 interleaved rounds on an Apple M3 Max:

| Compiler | Wall | Cycles | Instructions | Peak RSS |
| --- | --- | --- | --- | --- |
| stator-ts | 19.7 ms | 68 M | 186 M | 22.4 MiB |
| tsrs `--fast` | 39.5 ms | 327 M | 939 M | 58.5 MiB |
| tsc-rs `--fast` | 53.1 ms | 262 M | 900 M | 79.8 MiB |
| tsc 7.1.0-beta | 131.2 ms | 795 M | 2,362 M | 91.9 MiB |

All four report 11 errors. Native binaries: stator-ts `0a38da8` built with ReleaseFast and no PGO, tsrs 0.20.1-ts7.1.0-beta, tsc-rs 0.8.0, typescript 7.1.0-beta.
