interface E { id: string }
interface Base<F, T> { readonly kind: number; extract(from: F): T }
interface TV<F, T> extends Base<F, T> { readonly kind: 0; equals(a: T, b: T): boolean }
interface TA<F, T> extends Base<F, T> { readonly kind: 1; item: unknown }
interface TO<F, T> extends Base<F, T> { readonly kind: 2; children: unknown[] }
type Tr<F, T> = TV<F, T> | TA<F, T> | TO<F, T>;
declare function array<T, R>(s: TO<T, R> | TV<T, R>): TA<readonly T[], R[]>;
declare function t<T, O, R>(g: (o: T) => O, s: Tr<O, R>): Tr<T, R>;
declare const es: TO<E, E>;
interface M { events?: E[]; list?: string[] }
const a1: Tr<M, E[]> = t((m: M) => m.events, array(es));
const a2: Tr<M, E[]> = t(m => m.events, array(es));
declare function pick<T>(a: T, b: T): T;
declare const opt: string[] | undefined;
declare const ro: readonly string[];
const a3: number = pick(opt, ro);
const a4: number = pick(ro, opt);
declare const nul: string[] | null;
const a5: number = pick(nul, ro);
const a6: number = pick(opt, nul);
const a7: number = pick(undefined, ro);
const a8: number = pick(opt, 1);
declare function one(a: string[] | undefined): void;
one(1);
const a9: number = pick<string[] | undefined>(opt, 1);
declare const lit: "x" | "y";
const a10: number = pick(lit, "z");
declare const litu: "x" | undefined;
const a11: number = pick(litu, "z");
declare const bu: boolean | undefined;
const a12: number = pick(bu, false);
const a13: number = pick(null, undefined);
