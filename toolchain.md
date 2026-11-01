# Toolchain

| Program | How to install | Why here | Source |
| --- | --- | --- | --- |
| zig 0.17.0 | mise, pinned in `mise.toml` | Compiler and build system | https://github.com/ziglang/zig |
| node | mise | Default test runtime, differential tests | https://github.com/nodejs/node |
| bun | mise | Alternative test runtime | https://github.com/oven-sh/bun |
| git | system | `tests/ts7/sync.sh` fetches upstream's tests | https://github.com/git/git |
| clang 23.1.4 | mise, `conda:clang`, through `mise exec` | `scripts/pgo.sh` optimizes Zig's bitcode with a profile, which Zig cannot do | https://github.com/llvm/llvm-project |
| llvm-profdata 23.1.4 | mise, `conda:llvm-tools`, through `mise exec` | `scripts/pgo.sh` merges the raw profile | https://github.com/llvm/llvm-project |

## Zig

| Package | Where | Source | Why here |
| --- | --- | --- | --- |
| coroutines | local, `build.zig.zon` | https://github.com/pyrlyn/coroutines | `state_machine.runParallel` runs the parallel passes |

## npm

| Package | Where | Source | Why here |
| --- | --- | --- | --- |
| typescript | `tests/package.json` (7.0.2); checked project's `node_modules`, or `--lib-dir` | https://github.com/microsoft/TypeScript | `lib.*.d.ts` read at run time, from `@typescript/typescript-<platform>/lib` on TypeScript 7; reference `tsc` for differential tests |
| @types/node | `tests/package.json` | https://github.com/DefinitelyTyped/DefinitelyTyped | Ambient types for the fixtures in `tests/differential.sh` |
