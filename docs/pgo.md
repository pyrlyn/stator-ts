# Profile-guided builds

On macOS, `scripts/pgo.sh` builds `zig-out/bin/stator-ts-pgo` with profile-guided optimization, which needs clang and a project to train on. On VS Code it runs 26% fewer instructions and takes 16-19% less time at `-j 16`, with the same output.

Train on a representative project, then use the generated binary for subsequent checks or builds:

```bash
mise exec conda:clang@23.1.4 conda:llvm-tools@23.1.4 -- \
  bash scripts/pgo.sh -p /path/to/project --lib-dir /path/to/typescript/lib -j 16
zig-out/bin/stator-ts-pgo build -p /path/to/project --lib-dir /path/to/typescript/lib -j 16
```

The PGO binary is optimized for the build machine. Training is a one-time build step, repeated when rebuilding after source changes; it is not part of each project compilation. Reproducible instruction-count comparisons on the existing test projects are recorded in [the T19 report](plan/T19/instructions-report.md).
