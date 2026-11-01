declare function a<T>(f: (s: { n: number }) => T): T;
const x = a(s => s.n);
const y: string = x;
interface I<T> { p: { v: number }; q: (x: { w: string }) => T }
declare const i: I<string>;
const v: string = i.p.v;
const w = i.q({ w: 's' });
const u: number = w;
type Keep<T> = { fixed: number };
const k: Keep<string> = { fixed: 1 };
const l: Keep<number> = k;
function outer<T>(x: T) {
  type L = { v: T };
  const y: { l: L } = { l: { v: x } };
  const z: { l: { v: number } } = y;
  return y;
}
class C<T> { m(x: { a: number }) { return x.a; } t: T = null!; }
const n: string = new C<string>().m({ a: 1 });
