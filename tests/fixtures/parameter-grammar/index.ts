// Parameter checks from tsc's `checkParameter` and `checkGrammarIndexSignatureParameters`.
var v = (public x: string) => { };
function f(private y: number) {}
class C {
    constructor(public z: number);
    constructor(public a: number, readonly b?: string) {}
    m(protected z: number) {}
    set s(this: C, v: number) {}
    get g(this: C) { return 1; }
}
declare class D { constructor(public a: number); }
interface I { new (public a: number): I; m(readonly q: number): void; }
type F = (override a: number) => void;
type G = new (this: any) => void;
function h(a: number, this: any) {}
const ar = (this: any) => 1;
function r(...xs: number) {}
function r2(...xs: string[]) {}
function r3<T>(...xs: T) {}
function r4<T extends any[]>(...xs: T) {}
function r5(...xs: any) {}
function r6(...xs: readonly number[]) {}
function op({ a }?: { a: number }) {}
declare function op2({ a }?: { a: number }): void;
class E { constructor(public constructor: number) {} }
enum En { A, B }
enum S { X = "x" }
interface I1 { []: string }
interface I2 { [a: string, b: number]: string }
interface I3 { [...a: string[]]: string }
interface I4 { [public a: string]: string }
interface I5 { [a ?: string]: string }
interface I7 { [a: "x"]: string }
interface I8<T extends string> { [a: T]: string }
interface I9 { [a: boolean]: string }
interface I10 { [a: string] }
interface I11 { [a: `x${string}`]: string }
interface I12 { [a: En]: string }
interface I13 { [a: S]: string }
interface I14 { [a: string & { _b: 1 }]: string }
interface I15 { [a: Uppercase<string>]: string }
interface I16 { [a: object]: string }
interface I17 { [a: string | number]: string }
interface I18 { [a: string | boolean]: string }
type T1 = { [a: symbol]: 1 };
declare const u: unique symbol;
interface I19 { [a: typeof u]: string }
export {};
