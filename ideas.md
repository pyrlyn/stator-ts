# Ideas

- Native backend.
- Report TS5056 when `foo.ts` and `foo.tsx` map to one output file.
- Cut scratch allocation in the checker: temporary lists are about a quarter of what one checker holds on VS Code.
- Find out why evaluating conditional types over mapped types that mention only `this` breaks `this is` narrowing on VS Code; `isGeneric` still treats them as generic for that reason.
- Bring peak memory on VS Code down to tsc-rs's level: 15.7 GB against 7 GB, 13.4 GB of it in a single checker.
- Print aliases, index parameter names and method members as tsc does, so message text matches and not just the code.
