# Ideas

- Native backend.
- Report TS5056 when `foo.ts` and `foo.tsx` map to one output file.
- Find out why evaluating conditional types over mapped types that mention only `this` breaks `this is` narrowing on VS Code; `isGeneric` still treats them as generic for that reason.
- Build members of instantiated generics on demand. tsrs instantiates 1,287,137 of 8,810,354 declared members on VS Code. Diagnostics must stay the same at every `-j`.
- Try profile-guided optimization for release binaries: tsrs measures -13.5% instructions. Find out first whether Zig can do it.
- Follow TypeScript 7.1: it reports 11 more errors on VS Code, all around `IConfigurationResolverService`, where a distributed `T` no longer relates to a non-distributed one.
- Close the tsc gaps found while writing T13's fixtures: `let` over a parameter gives TS2451 where tsc gives TS2300; a `var` in a body is visible to a parameter initializer, TS2454 where tsc gives TS2304; TS2403 is missed for a `var` redeclaring a parameter with another type; a function declaration that only throws infers `never` where tsc infers `void`; TS7023 is missed for a self-referencing return; TS2451 is not reported in `lib.dom` for a script's `top`; grammar errors TS1184, TS1232, TS1234 and TS1235 are missed; TS2307 is not reported for `import c = require` in a body.
- Print aliases, index parameter names and method members as tsc does, so message text matches and not just the code.
- Share work between checkers at `-j 16`: they spend 156 G instructions on VS Code against 132 G for one, which is most of what is left to tsrs there after T15.
- Find out why one checker per file prints `Type '{}'` where a normal run prints `Type 'PermissionRequestHandler'` in a TS2344 on VS Code: the file, line and code match, the text depends on the run.
- Close the tsc gaps found while writing T15's fixture: `take(pick("a", over(false)))` misses TS2345 on the outer call, and a statement call with a failing overload narrows by the last overload where tsc does not.
