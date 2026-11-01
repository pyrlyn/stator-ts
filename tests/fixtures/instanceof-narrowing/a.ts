import assert from 'assert';
class E1 extends Error { constructor(m?: string) { super(m); } }
export function f(err: Error) { if (err instanceof E1) { return err; } return err.message; }
export function g(xs: { a: number; ok: boolean }[], u: { k: 'a'; v: number } | { k: 'b'; w: string }, part: object, runs: string[]) {
  const q = xs.find(r => r.ok)?.a;
  const y = xs.find(r => r.a === 1)?.ok;
  assert.strictEqual(u.k, 'a');
  if (u.k !== 'a') { return; }
  u.v;
  assert.deepStrictEqual(runs, ['x']);
  runs.length = 0;
  if ('id' in part && typeof part.id === 'string') { return part.id; }
  return [q, y];
}
export class Store { add<T extends { dispose(): void }>(o: T): T { return o; } }
type Ctor<T> = new (...a: any[]) => T;
declare function create<C extends new (...args: any[]) => unknown, R extends InstanceType<C>>(ctor: C, ...args: any[]): R;
class W { dispose() {} node = 1; }
export function h(s: Store, rec: Record<string, number>) {
  const w = s.add(create(W));
  const p = { ...rec };
  p.foo = 1;
  delete p.bar;
  return [w.node, p];
}
class G<T> { constructor(public v: T) {} dispose() {} }
export function k(s: Store) {
  const w = s.add(create(G<string>, 'a'));
  const f = G<number>;
  const fn = id<string>;
  return [w.v.length, new f(1).v.toFixed(), fn('x').length];
}
function id<T>(x: T) { return x; }
export class Pa { private _e = 1; on!: (l: (e: this) => void) => void; }
export class Pb extends Pa { more = 2; }
export const pb: Pa = new Pb();
type M = { id: number } & Pick<{ group?: string; order?: number; when: string }, 'group' | 'order'>;
export const m: M = { id: 1, group: 'x', order: 2 };
export const u: { a: 1 } | { b: 2 } = { a: 1, b: 2 };

// batch p15
export function plusAny(n: number, x: any) { let c = 0; c += x; const q: number = n + x; return [c, q]; }
export function asserts1(cb: (x: unknown) => asserts x is string) { return cb; }
asserts1(v => { if (typeof v !== 'string') throw new Error(); });
export async function awaited1() { const s: string = await new Promise(resolve => resolve('a')); return s; }
export const dflt = (a: string | undefined = 'x') => a.length;
export const lam: (a: string | undefined) => number = (a = 'x') => a.length;
export function spreadT(f: (a: string, b?: number) => void, args: [string, number?]) { f(...args); }
export function destr(xs: readonly (readonly [string, number] | readonly [string, boolean])[]) { for (const [a, b] of xs) { const n: string = a; const m: number | boolean = b; console.log(n, m); } }
export function un(a: unknown) { if (a && typeof a === 'object') { const o: object = a; return o; } return null; }
