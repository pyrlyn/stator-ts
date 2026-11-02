const a;
const b: number;
const c = 1, e;
let f;
var { g };
let [h];
const { i } = { i: 1 };
declare const j: number;
declare const { k }: { k: number };

for (const x of [1]) {}
for (const y in {}) {}
for (const [p, q] of [[1, 2]]) {}

export function f2() {
    using u;
}

let m!: number;
let n! = 1;
let o!;
declare let r!: number;

export class C {
    t!: number;
    u!: number = 1;
    v!;
    static w!: number;
    declare x2!: number;
}

export abstract class D {
    abstract y!: number;
}

declare class E {
    z!: number;
}

export {};
