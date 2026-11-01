declare function f1(a: string | undefined): void;
declare function f2(a: string[] | undefined): void;
declare function f3(a: string[] | null): void;
declare function f4(a: string[] | number[] | undefined): void;
declare function f5(a: { x: 1 } | undefined): void;
declare function f6(a: { x: 1 } | null | undefined): void;
declare function f7(a: (() => void) | undefined): void;
declare function f8(a: string[] | boolean | undefined): void;
declare function f9(a: string | number | undefined): void;
declare function f10(a: 'x' | undefined): void;
declare function f11(a: number[] | undefined): void;
f1(1); f2(1); f3(1); f4(1); f5(1); f6(1); f7(1); f8(1); f9(true); f10(1);
f1(true); f2(true); f3('a'); f5('a'); f7(null);
f2({}); f5({}); f7({}); f1({}); f10({});
declare const o: { y: 2 };
f1(o); f2(o); f3(o); f4(o); f5(o); f6(o); f7(o); f8(o); f9(o); f10(o);
f11(['x']);
declare const s: string;
const v1: string[] | undefined = 1;
const v2: { x: 1 } | undefined = s;
const v3: string | undefined = 1;
function g<T>(x: T, y: T & { a: 1 }, z: string | number, e: 'a' | 'b', u: string | undefined) {
    const v4: number | undefined = x;
    const v5: number | undefined = y;
    const v6: boolean[] | undefined = z;
    const v7: number | undefined = e;
    const v8: number | undefined = u;
    const v9: { q: 1 } | undefined = u;
    const v10: number | null = u;
    const v11: number[] | undefined = ['x'];
    const v12: [number] | undefined = ['x'];
    const v13: number[] | string = ['x', 1, true];
    const v14: { p: number[] } | undefined = { p: ['x'] };
}
declare function pick<T>(a: T, b: T): T;
function h<T extends string>(t: T) {
    const a: number | undefined = t;
}
type Al = string[] | undefined;
const v15: Al = 1;
enum En { A, B }
interface M2 { a: 1 }
declare const en: En; declare const un: unknown; declare const vv: void; declare const bb: boolean; declare const k: keyof M2; declare const tl: `a${string}`;
declare const nv: never; declare const sy: symbol; declare const big: bigint;
f1(en); f1(un); f2(vv); f2(bb); f2(k); f2(tl); f2(sy); f2(big); f2(En.A);
function gg<K extends keyof M2, T>(a: K, b: keyof T, c: T[keyof T], d: T extends string ? 1 : 2) { f2(a); f2(b); f2(c); f2(d); }
const vb: boolean = 1;
const vb2: boolean | undefined = 1;
const v16: number[] = ['x', 1, true];
const v17: number[] = [{ a: 1 }, 'x'];
const v18: { a: number }[] = [{ a: 'x' }, { a: 1 }];
const v19: [number, string] = ['x', 1];
