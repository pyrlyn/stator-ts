const x: number = "hello";
function f(a: string, b?: number): string { return a + b; }
f(1);
f("a", 2, 3);
let y = [1, 2, 3].map(v => v * 2);
y.push("x");
interface P { name: string; age: number }
const p: P = { name: "a" };
const q: P = { name: "a", age: 1, extra: 2 };
class A { private x = 1; m() { return this.x; } }
new A().x;
function g(z: string | null) { return z.length; }
foo();
const ty: string = y;
const m1 = [1,2].map(v => v);
const m2: string = m1;
function id<T>(x: T): T { return x; }
const i1: string = id(1);
const i2 = id("a");
const i3: number = i2;
type U = { kind: "a"; a: number } | { kind: "b"; b: string };
function h(u: U) {
  if (u.kind === "a") return u.a;
  const s: number = u.b;
  return s;
}
enum E { A, B = 5, C = "x".length }
const e: E = E.A;
const e2: string = E.B;
async function af() { const r = await Promise.resolve(1); const s: string = r; return s; }
for (const k of [1, 2]) { const s: string = k; }
const o = { a: 1, b: "x", c: { d: true } };
const o2: { a: string } = o;
o.c.d = 1;
const tpl = `a${1}`;
const nn: number = tpl;
function ov(a: string): string;
function ov(a: number): number;
function ov(a: any) { return a; }
ov(true);
class B<T> { constructor(public v: T) {} get(): T { return this.v; } }
const bb = new B(1);
const bs: string = bb.get();
class C extends B<string> { override get() { return 1; } }
abstract class D { abstract m(): void; }
new D();
class F extends D {}
const fn = (a, b: number) => a;
let un;
un = 1;
const arr: readonly number[] = [1];
arr.push(1);
const t2: [number, string] = [1, 2];
t2[5];
const kk: keyof P = "nope";
type M = { [K in keyof P]?: P[K] };
const mm: M = { name: 1 };
type R = ReturnType<typeof f>;
const rr: number = "x" as R;
const pp: Partial<P> = { nope: 1 };
const pk: Pick<P, "name"> = { name: 1 };
const rec: Record<string, number> = { a: "x" };
function ng(x: string | number) { if (typeof x === "string") { return x.length; } return x.toFixed(); const z = 1; }
console.log(1);
