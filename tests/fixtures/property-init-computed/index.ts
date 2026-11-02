import * as keys from "./keys";
const k = "key";
declare const u: unique symbol;
namespace Foo {
    export const key = Symbol();
}
export class C {
    [Symbol.iterator]: number;
    [Symbol.unscopables]: number;
    [k]: string;
    [u]: string;
    [Foo.key]: string;
    [keys.key]: string;
    [keys.E.A]: string;
    ["lit"]: string;
    "quoted": number;
    0: number;
    #p: number;
    q: number;
    r: number;
    constructor() {
        this[Symbol.unscopables] = 1;
        this[u] = "";
        this[(Foo.key)] = "";
        this[keys.key] = "";
        this[keys.E.A] = "";
        this["lit"] = "";
        this.r = 1;
    }
}
