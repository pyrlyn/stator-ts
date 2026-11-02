// Keyword modifiers checked like tsc's `checkGrammarModifiers`.
export {};
class A {
    public public a = 1;
    static public b = 1;
    readonly static c = 1;
    private protected d = 1;
    export e = 1;
    declare m(): void;
    abstract f: number;
    async constructor() {}
    accessor h() {}
    public #j = 1;
    declare #k: number;
    override readonly l = 1;
    async static n() {}
    public accessor o = 1;
    accessor readonly p = 1;
}
abstract class B {
    static abstract a(): void;
    private abstract b(): void;
    abstract public c(): void;
    abstract override d(): void;
    abstract #e(): void;
}
public function f1() {}
static var v1 = 1;
declare export function f2(): void;
async export function f3() {}
interface I {
    public a: number;
    static m(): void;
    readonly r: number;
}
class C2 { constructor(static x: number, export y: number, declare z: number, async w: number, public { q }: any, public ...rest: any[]) {} }
function g<in X>() {}
const enum E1 { A }
declare namespace N { declare const x: number; export async function f(): Promise<void>; }
namespace M { export default class X {} }
declare import fs = require("fs");
abstract interface I2 {}
function outer() {
    export function inner() {}
    abstract class Inner {}
    const enum E2 { A }
    async function ok() {}
    declare var dv: number;
}
async class C4 {}
readonly var rv = 1;
class C5 { static constructor() {} }
class C6 { override constructor() {} }
abstract class C7 { abstract async m(): Promise<void>; async abstract m2(): Promise<void>; }
let o = { async m() {} };
type T3<in out X> = { x: X };
type T4<out in X> = { x: X };
class C8 {
    static static
    m() {}
}
