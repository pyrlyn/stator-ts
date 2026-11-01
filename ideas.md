# Ideas

- Native backend.
- Report TS5056 when `foo.ts` and `foo.tsx` map to one output file.
- Find out why evaluating conditional types over mapped types that mention only `this` breaks `this is` narrowing on VS Code; `isGeneric` still treats them as generic for that reason.
- Bring peak memory on VS Code down to tsc-rs's level: 9.8 GB against 7 GB, 8.7 GB of it in a single checker. The cuts left are building members of instantiated generics on demand, and freeing checker memory file by file, which needs an owner for every cached type.
- Print aliases, index parameter names and method members as tsc does, so message text matches and not just the code.
