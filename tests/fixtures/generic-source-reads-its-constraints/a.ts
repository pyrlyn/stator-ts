interface ZT<O, I = unknown> {
    output: O;
    input: I;
    refine<Ch extends (a: O) => unknown>(c: Ch): Ch extends (a: any) => a is infer R ? this & ZT<R, I> : this;
    twice<N extends number>(n: N): N extends string ? ZT<unknown> : this;
}
interface ZS extends ZT<string, string> { email(): this }
declare function zinf<T>(x: ZT<T>): T;
declare const s: ZS;
const a1: number = zinf(s);
declare function ov<T>(x: { f(a: string): T; f(a: number): T }): T;
declare const both: { f<X extends string>(a: X): X extends number ? 1 : 2; f(a: number): 3 };
const a2: "zz" = ov(both);
declare function apply<R, A extends any[]>(fn: (x: string, ...a: A) => R, ...a: A): R;
declare function gen<T, U extends T[]>(x: string, u: U): { u: U };
const a3: "zz" = apply(gen, null as any).u;
