declare function isObject(obj: unknown): obj is Object;
interface V<T> { user?: { value?: T } }
declare function inspect<T>(k: string): Readonly<V<Readonly<T>>>;
let e = inspect('a').user?.value;
const t0: number = e;
if (!isObject(e)) {
  e = {};
}
const t1: number = e;
const a = { ...e, b: 1 };
const n = Object.keys(e).length;
function f(o: unknown) {
  if (!isObject(o)) { return; }
  const u = { ...o, b: 1 };
  const m: number = o;
}
function g(o: {} | undefined) {
  if (!isObject(o)) { o = {}; }
  const u = { ...o, b: 1 };
  const m: number = o;
}
