declare const xs: string[];
declare function mk<K, V>(x: Iterable<readonly [K, V]>): [K, V];
const a1 = mk(xs.flatMap(c => [[c, 1] as const]));
const a2 = mk(xs.flatMap(c => c ? [[c, 1] as const] : []));
const z1: "z" = a1;
const z2: "z" = a2;
declare function mk2<K>(x: Iterable<readonly [K]>): K;
const a3 = mk2(xs.flatMap(c => c ? [[c] as const] : []));
declare function ar<U>(x: U[] | U): U;
const a4: readonly [string] = ar(xs.length ? [["a"] as const] : []);
const r1: "z" = [[1, 2] as const];
const r2: "z" = [] as (readonly number[])[];
function gk<T>(x: (keyof T)[]) { const z: "z" = x; }
