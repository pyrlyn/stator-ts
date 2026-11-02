# T19 follow-up: project discovery and syntax diagnostics

The 30% target remains unmet on the originally selected projects. This follow-up fixes repeated traversal through directory symlinks, avoids walking excluded directory trees, and reports an invalid private name in a type query. On an additional excluded-output stress case, peak RSS falls 41.2% and wall time falls 80.1%; the original workloads are essentially unchanged.

## Changes and regression evidence

- Project discovery now prunes exclusions that cover an entire directory subtree before reading that directory. Final file filtering still handles other patterns. An explicitly imported file remains loadable even inside an excluded directory. The new `excluded-subtree` fixture checks both imported and unimported excluded files against TypeScript 7.0.2: exactly one TS2322 is expected and reported.
- The shared directory walker records canonical directory identities while preserving lexical file paths. A link back to its parent previously yielded 32 copies of one source file before the operating system stopped resolving the growing symlink chain. The fixed walker and native `tsc --listFilesOnly` each return one file. Directory sorting makes the selected alias deterministic. A unit test covers the cycle, exclusion pruning without populating the excluded directory cache, descendant exclusion, and the filesystem-root exclusion.
- `typeof this.#a` now reports TS1003 at the same position as native TypeScript. The existing `private-name-in-type-query` fixture previously missed this diagnostic. Public entity names retain their existing parsing path.

The public `walkDirs` entry point and file-filtering rules are preserved; project discovery passes its exclusions to a shared private walker. No dependency or compiler-option changes were made.

## Measurements

Baseline: merged commit `69986bfe5fb02b44d8a640a74554ce4157213fe7`. Both binaries use Zig 0.17.0, ReleaseFast, no PGO, and `-j 16`. Each measurement has three warmup pairs and 30 alternating measured pairs. Every run preserved its exit status and stdout SHA-256. Wall time includes process launch. CPU counters have 10 ms precision, limiting their usefulness on small fixtures. MB means decimal megabytes.

| Workload | Wall before → after | Peak RSS before → after |
| --- | --- | --- |
| `stator/packages/compiler` | 116.26 → 115.91 ms | 116.48 → 116.76 MB |
| `function-body-across-files` | 24.85 → 24.52 ms | 23.23 → 23.25 MB |
| `settled-visits` | 37.65 → 37.31 ms | 24.38 → 24.40 MB |
| Additional excluded-output stress case | 131.53 → 26.11 ms | 39.41 → 23.18 MB |

The stress case also reduces median CPU time from 680 to 20 ms. It exposes unnecessary filesystem traversal; it does not establish a 30% improvement for normal checking or replace the original acceptance workloads. The previous iteration's measurements remain in [report.md](report.md). Do not combine timings from separate measurement sessions into a cumulative percentage.

[followup-benchmark.json](followup-benchmark.json) contains binary hashes, exact commands, all raw samples, and medians. Reproduce the extra workload from the checked-in fixture:

```sh
python3 - <<'PY'
from pathlib import Path
import shutil, tempfile
root = Path(tempfile.mkdtemp(prefix="stator-excluded-"))
shutil.copytree("tests/fixtures/excluded-subtree", root, dirs_exist_ok=True)
for i in range(500):
    directory = root / "generated" / f"bundle-output-{i:04d}"
    directory.mkdir()
    for j in range(100):
        (directory / f"generated-declaration-artifact-{j:04d}.d.ts").touch()
print(root)
PY
node scripts/benchmark.mjs /path/to/baseline /path/to/candidate -- \
  check -p /printed/temporary/path \
  --lib-dir tests/node_modules/@typescript/typescript-darwin-arm64/lib -j 16
```

The generated files are empty because the defect is walking and retaining their paths despite their exclusion. Native TypeScript and both benchmark binaries report the same single diagnostic on this workload.

Other measured experiments were rejected: recycling smaller allocator blocks slightly reduced memory but increased wall time; limiting loading to four workers reduced CPU time but increased wall time about 11%; smaller resolver scratch chunks improved neither memory nor time. The existing allocator and worker configuration are retained.

## Verification

- `zig build test` passes on the final source, including the new filesystem regression.
- Full differential suite: 1200 reference diagnostics, **1198 matches, zero false positives, two pre-existing misses**, with exact columns on 1194 matches. The remaining misses are `constraint-position-narrowing` and `mapped-known-keys-generic-index`.
- Full TS7 suite: **8249 pass, 5488 fail, zero crashes or timeouts** out of 13,737 tests. The passing ratchet loses no tests and gains none. Existing unsupported tests were not suppressed or reclassified.
- Focused differential checks on the two affected fixtures and the 50,000-file stress case match all three diagnostics and columns exactly.
- ReleaseSafe matches all 23 diagnostics and columns on the two affected fixtures plus `settled-visits`; the directory-cycle scan returns one file with no syntax errors. `git diff --check` passes.

T19 stays open because the requested 30% RAM and time reduction on the selected original workloads is not demonstrated.
