interface A { kind: 'a'; from: string; self: boolean }
interface B { kind: 'b'; x: number; self: boolean }
type U = A | B;
function f1(us: readonly U[]) {
  const e = us.filter((r): r is A => r.kind !== 'b' && !r.self);
  for (const r of e) r.from;
  const q = new Map<string, string[]>();
  for (const r of e) q.set(r.from, [...(q.get(r.from) ?? []), r.from]);
}
type R<T> = { ok: true; value: T } | { ok: false; error: string };
function f2<T>(r: R<T>): T {
  if (!r.ok) throw new Error(r.error);
  return r.value;
}
function f3(xs: string[]) {
  const m = new Map(xs.map((x, i) => [x, i]));
  const n: number | undefined = m.get('a');
  const s = new Map(xs.map((x) => [x, { v: x }]));
  s.get('a')?.v;
}
function f4(m: Map<string, { a: number }>) {
  const v = [...m.values()].filter((e) => e.a > 1);
  v[0]?.a;
  for (const e of m.values()) e.a;
}
function f5(e: unknown) {
  return (e as { code?: unknown }).code?.toString().startsWith('x');
}
function f6(add: (a: string, at?: { model?: string; field?: string }) => void, at?: { model?: string; field?: string }) {
  add('x', at);
}
type K = 'scalar' | 'enum';
interface F { kind: K; list: boolean }
function f7(xs: string[]): F[] {
  return xs.map((x) => ({ kind: 'scalar', list: false }));
}
function f8(xs: string[], b: boolean): F {
  const kind = b ? 'scalar' : 'enum';
  return { kind, list: b };
}
const arr: readonly (readonly string[])[] = [['a']].map((x) => x);
function f9(xs: string[]): readonly (readonly string[])[] { return xs.map((u) => [u]); }
const big: ((string | boolean | null)[] | (string | boolean)[])[] = [['a', false, null], ['a', true]];
interface PR { set_message: (m: string) => void }
const reg: PR | undefined = { set_message(m: string) {} };
const reg2: { r?: PR } = {}; reg2.r = { set_message(message: string) { message.length; } };
function f10(idents: (string | undefined)[]) {
  const z: string[] | null = idents.every((i): i is string => i !== undefined) ? idents : null;
}
function f11(args: readonly (string | { a: string })[]) {
  const [expression] = args;
  return typeof expression === 'string' ? expression.length : 0;
}
function f12(v: { args: (string | { a: string })[] }, g: (s: string) => void) {
  const [expression] = v.args;
  if (typeof expression === 'string') g(expression);
}
