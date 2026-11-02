// `type: module` does not make this file ESM under `--module commonjs` with bundler resolution.
import { fromCjs } from "#dep";
// A `null` target excludes the path instead of falling through to `types`.
import { fromEsm } from "#blocked";
// A key with two `*` is no pattern, and matches nothing as written.
import {} from "#stars/*/and/*";
// Folder keys still map, but an export target must name its extension.
import { fromEsm as viaFolder } from "#lib/esm.js";
import {} from "#lib/esm";
import {} from "#noext";

export const all = [fromCjs, fromEsm, viaFolder];
