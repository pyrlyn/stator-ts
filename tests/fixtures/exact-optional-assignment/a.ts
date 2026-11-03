type O = { a?: number; b?: string | undefined };
const o1: O = { a: undefined };
const o2: O = { b: undefined };
const o3: O = {};
function g(o: O) {}
g({ a: undefined });
type R = Required<O>;
const r1: R = { a: 1, b: undefined };
type M = { [K in keyof O]-?: O[K] };
const m1: M = { a: undefined, b: "" };
const t1: [number, string?] = [1, undefined];
const t2: [number, (string | undefined)?] = [1, undefined];
function h(o: O) {
  switch (o.a) {
    case undefined:
      return 0;
    default:
      return o.a + 1;
  }
}
