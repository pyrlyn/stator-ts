import { x, y } from "./values";
import { z } from "./values";
import * as ns from "./values";
import type { T } from "./values";
import { _skipped } from "./values";
import type { Linked } from "./values";

/** See {@link Linked}. */
export interface Documented {}

const a = 1, b = 2;
let assigned = 3;
assigned = 4;
let bumped = 0;
bumped++;
let compound = 0;
compound += 1;
const { e, f } = { e: 1, f: 2 };
const { g, ...rest } = { g: 1, h: 2 };
export const used = [rest, z, bumped, compound];

function unusedFn(p: number, _u: number, q: string) { return q; }
function noParams<A, B>() {}
function oneParam<C>(value: C) { return value; }
class Unused {}
interface Shape {}
type Alias = number;
enum Kind { A }
for (const k of [1]) {}
for (const _k of [1]) {}
function recursive() { recursive(); }
const [h1, h2] = [1, 2];
export const first = h1;
export type Inferred<V> = V extends Array<infer U> ? number : never;
export const named = function inner(this: number) { return this; };

class Merged<M> {}
interface Merged<M> { m: M }
export { Merged };

let b2 = 0;
let b3 = 0;
b2 = b3 = 1;

export class Members {
    private never = 1;
    private written = 1;
    private bumped = 1;
    #hidden = 1;
    #read = 1;
    private self() { this.self(); }
    private called() {}
    private get pair() { return 1; }
    private set pair(v: number) { }
    private set onlySet(v: number) { }
    private destructured = 1;
    constructor(private unusedProp: number, private readProp: number) { this.readProp; }
    run() {
        this.written = 2;
        this.bumped++;
        this.#read;
        this.called();
        this.onlySet = 3;
        const { destructured } = this;
        return destructured;
    }
}
