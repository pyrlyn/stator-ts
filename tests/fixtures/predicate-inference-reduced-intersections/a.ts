type A = { t: "a"; u: string };
type B = { t: "b"; u: string };
type C = { t: "c" };
declare function isC(x: A | B | C): x is C;
declare const list: (A | B | C)[];
const l2 = list.filter(x => !isC(x)).map(x => x.u);
const l3 = ["a", null].filter(x => x !== null).map(x => x.length);
const l4 = [1, "a"].filter(x => typeof x === "string");
const z4: "zz" = l4;
const n1 = list.filter(x => { return !isC(x); });
const z1: "zz" = n1;
function nn(x: string | null) { return x !== null; }
const z2: "zz" = nn;
const fn2 = (x: A | C) => x.t === "a";
const z3: "zz" = fn2;
function partial(x: string | number) { return typeof x === "string" && x.length > 0; }
const z5: "zz" = partial;
function twoRet(x: string | number) { if (typeof x === "string") return true; return false; }
const z6: "zz" = twoRet;
function assigned(x: string | null) { x = "s"; return x !== null; }
const z7: "zz" = assigned;
function ok(x: boolean) { return x === true; }
const z8: "zz" = ok;
function truth(x: string | undefined) { return !!x; }
const z9: "zz" = truth;
function truth2(x: object | undefined) { return !!x; }
const z10: "zz" = truth2;
class K { m(x: string | null) { return x !== null; } }
const z11: "zz" = new K().m;
const obj = { f(x: string | null) { return x !== null; }, g: (x: A | C) => !isC(x) };
const z12: "zz" = obj;
function rest(...xs: (string | null)[]) { return xs.length > 0; }
const z13: "zz" = rest;
function thisp(this: A | C, x: A | C) { return "u" in x; }
const z14: "zz" = thisp;
function two(a: string | null, b: number | null) { return b !== null; }
const z15: "zz" = two;
async function asy(x: string | null) { return x !== null; }
const z16: "zz" = asy;
function* gen(x: string | null) { return x !== null; }
const z17: "zz" = gen;
