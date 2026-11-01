// A unique symbol stored in a property survives when the context asks for it.
const legacy = Symbol('x');
interface M { y?: typeof legacy; }
export const a: M = { y: legacy };
export function f(v: typeof legacy | undefined): M { return { y: v }; }
export function g(o: { p?: boolean }): M { const v = o.p ? legacy : undefined; return { y: v }; }
export const widened = { y: legacy };
export const n: M = widened;
