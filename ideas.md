# Ideas

- Native backend.
- Report TS5056 when `foo.ts` and `foo.tsx` map to one output file.
- Find out why evaluating conditional types over mapped types that mention only `this` breaks `this is` narrowing on VS Code; `isGeneric` still treats them as generic for that reason.
- Build members of instantiated generics on demand. tsrs instantiates 1,287,137 of 8,810,354 declared members on VS Code. Diagnostics must stay the same at every `-j`.
- Try profile-guided optimization for release binaries: tsrs measures -13.5% instructions. Find out first whether Zig can do it.
- Follow TypeScript 7.1: it reports 11 more errors on VS Code, all around `IConfigurationResolverService`, where a distributed `T` no longer relates to a non-distributed one.
- Close the tsc gaps left after T14. Missed: TS2448 for a destructuring default that reads itself, TS2729, TS2372, TS2373, TS7057, TS1202, TS1344, TS2664, TS2666, TS2667, TS2303 for `export { local }` in a namespace, TS2300 for `import { c }` next to `export { c }` in a body, and TS1473 and TS1474 in checked JavaScript. tsc's "did you mean to call this" elaboration is missing too, so `run(() => f)` gets TS2322 inside the arrow where tsc gives TS2345 on it. TS7032 is missing, for a set accessor with no type and no getter. TS7022 through flow analysis stays silent: `let t; while (true) { const u = t; t = u; if (!t) break; }`. Without `noImplicitThis` `this` in an object literal method should be `any`, and stator-ts gives TS2339 for a property the literal lacks. `import y = require("./b")` next to `import("./b")` in a namespace gets no TS2307, since tsc keys resolution by mode.
- Print aliases, index parameter names and method members as tsc does, so message text matches and not just the code.
- Share work between checkers at `-j 16`: they spend 156 G instructions on VS Code against 132 G for one, which is most of what is left to tsrs there after T15.
- Find out why one checker per file prints `Type '{}'` where a normal run prints `Type 'PermissionRequestHandler'` in a TS2344 on VS Code: the file, line and code match, the text depends on the run.
- Close the tsc gaps found while writing T15's fixture: `take(pick("a", over(false)))` misses TS2345 on the outer call, and a statement call with a failing overload narrows by the last overload where tsc does not.
