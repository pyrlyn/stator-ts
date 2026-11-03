import d, { a } from "./b.cjs";
import * as ns from "./b.cjs";
const x: string = d.a;
const y: string = ns.default.a;
const z: string = a;
