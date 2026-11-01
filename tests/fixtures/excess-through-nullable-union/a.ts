// `undefined` in a union says nothing about the names an object literal may use, and tsc drops
// it from the target it reports.
interface Elem { tag: string }
interface Other { id: number }
interface Both { id: number; name: string }
declare const e: Elem;
declare const ee: Elem & { more: string };
declare function f(x: Other | undefined): void;
declare function g(x: string | undefined): void;
declare function b(x: Both | null | undefined): void;
declare function p(x: boolean | undefined): void;
declare function o(x: string | Object | Promise<any>): void;

const c1: Other | undefined = e;
const c2: string | null = e;
const c4: Both | null | undefined = e;
const c5: { id: number } | undefined = ee;
const c7: Other | undefined = { id: 1, extra: 2 };
const c8: Other | null | undefined = { id: 1, extra: 2 };
const c9: boolean | undefined = e;
const c10: string | { id: number } = { id: 1, extra: 2 };
f(e); g(e); b(e); p(e);
f({ id: 1, extra: 2 });
function r1(): Other | undefined { return e; }

// `Object` takes anything, whatever else is in the union.
o({ readable: 1 });

// A fresh literal is no subtype of a type without its names, so these stay apart.
declare function id<T>(expected: T): T;
const r3 = id([['x', { a: 1, b: 2 }], ['y', { a: 1 }]]);
const n3: number = r3[0];
