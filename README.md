# stator-ts

A TypeScript compiler written in Zig: it type-checks TypeScript, emits JavaScript, scans projects
in parallel and runs their tests on Node or Bun.

## Quick start

Needs Zig 0.17.0 (pinned in `mise.toml`).

```bash
zig build -Doptimize=ReleaseFast   # -> zig-out/bin/stator-ts
zig-out/bin/stator-ts check -p path/to/tsconfig.json
```

```bash
stator-ts check            # type-check the project
stator-ts build            # type-check and emit JavaScript
stator-ts scan             # parse the whole project in parallel, print stats
stator-ts test             # compile and run *.test.ts files in parallel on Node or Bun
```

The TypeScript libs come from `--lib-dir`, `STATOR_TS_LIB`, or the project's
`node_modules/typescript`.

## Documentation

- [Usage](docs/usage.md): commands, options, lib lookup, output and exit codes.
- [Architecture](docs/architecture.md): the pipeline and how it runs in parallel.
- [Testing](docs/testing.md): unit, differential and TypeScript 7 test suites.
- [Profile-guided builds](docs/pgo.md): `scripts/pgo.sh`.
- [Performance](docs/performance.md): benchmark against tsc and Rust ports.
