# Usage

```
stator-ts <command> [options]
```

| Command | What it does |
| --- | --- |
| `check` | Type-check the project. |
| `build` | Type-check and emit JavaScript. |
| `scan` | Parse every project file in parallel and print counts (files, lines, bytes, syntax errors, threads, walk and parse time). |
| `test [filter...]` | Compile and run `*.test.*`, `*.spec.*` and `*_test.*` files in parallel on Node or Bun. Each `filter` is a substring a test file's path must contain. |
| `help` | Print the usage text. |

## Options

| Option | Meaning |
| --- | --- |
| `-p`, `--project <p>` | A `tsconfig.json`, or a directory. A directory uses its `tsconfig.json`, or, without one, all source files under it. Defaults to the current directory. |
| `-j`, `--jobs <n>` | Worker threads and test processes. Default: the CPU count. |
| `--outDir <d>` | Output directory for `build`; overrides `outDir` in tsconfig. |
| `--lib-dir <d>` | Directory holding `lib.*.d.ts`. |
| `--all-diagnostics` | Also report semantic errors when the project has syntax errors. By default, like the tsc command line, they are held back. |
| `--runtime <r>` | `node` (default) or `bun`, for `test`. |
| `-t`, `--test-name <re>` | For `test`: run only tests whose name matches the regex. |

## Finding the TypeScript libs

`check` and `build` need TypeScript's `lib.*.d.ts` files (unless `noLib` is set). They are looked
up in this order:

1. `--lib-dir`;
2. the `STATOR_TS_LIB` environment variable;
3. `node_modules/typescript/lib` in the project root or any directory above it, or TypeScript 7's
   per-platform package next to it (`node_modules/@typescript/typescript-<platform>-<arch>/lib`).

Without any of them the run stops with `error: cannot find lib.d.ts`.

## Output and exit codes

Diagnostics are printed as `file(line,col): error TS<code>: <message>`, sorted by file and
position, with paths relative to the current directory. `@ts-ignore` and `@ts-expect-error`
silence semantic diagnostics on the next code line.

| Exit code | Meaning |
| --- | --- |
| 0 | No diagnostics. |
| 1 | Usage error, project that cannot be loaded, missing libs, or output that could not be written. |
| 2 | Diagnostics were reported (for `scan`: syntax errors or unreadable files). |

`build` writes output only when `noEmit` is not set. Output goes under `outDir` (or next to the
sources), mirroring the source tree from `rootDir`, or else from the deepest directory that holds
all emitted files. `.ts` becomes `.js`, `.mts` `.mjs`, `.cts` `.cjs`, and `.tsx` becomes `.jsx`
when `jsx` is `preserve`, else `.js`.

## Examples

```bash
stator-ts check -p tsconfig.json
stator-ts build -p . --outDir dist -j 8
STATOR_TS_LIB=/path/to/typescript/lib stator-ts check
stator-ts test src/parser --runtime bun -t "parses generics"
```
