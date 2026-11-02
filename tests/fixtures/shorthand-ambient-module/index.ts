import fs = require("foo");
import * as ns from "foo";
import def, { named } from "foo";
fs.readFile;
ns.readFile;
def.x; named.y;
export async function main() {
    const { readFile } = await import("foo");
    const m = await import("foo"); m.z;
}
type T = typeof import("foo"); declare const t: T; t.w;
import { known, unknown } from "bar";
const k: string = known;
