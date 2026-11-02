const a = (): { d: string } | undefined => undefined;
(({ [a()?.d]: c = "" }) => {})();
const k: string = "x";
(({ [k]: e = "" }) => {})();
function g({ [k]: h = 1 }) { return h; }
const { [k]: i = 1 } = { a: 1 };
const { [k]: j = 1 } = {} as { a: number };
function f3<T, K1 extends keyof T>(obj: T, k1: K1) {
  let { [k1]: a1, ...r1 } = obj;
}
