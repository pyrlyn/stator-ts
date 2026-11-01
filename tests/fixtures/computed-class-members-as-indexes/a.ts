declare const str: string;
declare const num: number;
declare const sym: symbol;
declare const tpl: `data-${string}`;
declare const lit: "a" | "b";
class A {
    n = 1;
    [str]() { return "s"; }
}
const a1: boolean = new A().anything;
class B {
    constructor() {}
    [str]!: string;
}
const b1: boolean = new B().anything;
class C {
    static [str]: string;
    static other = 1;
    inst = true;
}
const c1: symbol = C.anything;
class D {
    [sym]() { return 0; }
    [num]!: boolean;
    [tpl] = "x";
    plain = 1;
    2 = "two";
}
const d1: string = new D()[sym]();
const d2: string = new D()[0];
const d3: boolean = new D()["x"];
class E {
    [lit]!: number;
    [x: string]: number | string;
}
const e1: boolean = new E().q;
class F extends A {
    [sym]() { return super[sym]; }
}
interface H { [str]: number; a: string }
declare const h: H;
const h1: boolean = h.zz;
const h2: boolean = h[0];
