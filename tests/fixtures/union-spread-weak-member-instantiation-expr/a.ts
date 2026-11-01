const sy = Symbol('s');
function f1(v: boolean): Record<string, unknown> { return { [sy]: v }; }
const r1: Record<string, number> = { [sy]: 'x' };
interface M { kind: 1; content: string; id: string }
interface R { kind: 2; content: string; id: string; startedAt?: number }
interface O { kind: 3; x: number }
type RP = M | R | O;
function f3(parts: RP[]) {
  const m = new Map<string, M | R>();
  for (let part of parts) {
    if (part.kind === 1 || part.kind === 2) {
      part = { ...part };
      m.set('a', part);
    }
  }
}
type Cu = { type: 'a'; enablement?: readonly string[]; x: number } | { type: 'b'; y: string };
function f4<T extends Cu>(c: T) {
  const next: T & { enablement?: readonly string[] } = { ...c };
  return next;
}
interface IR { sourceId: string; time: number }
class SL<T extends IR> {
  static cast<T extends IR>(): typeof SL<T> { return this as typeof SL<T>; }
  constructor(readonly k: string) {}
  log(d: T) {}
}
declare function ci<C extends new (...a: any[]) => any>(c: C, ...a: any[]): InstanceType<C>;
class X {
  private readonly l;
  constructor() { this.l = ci(SL.cast<{ a: 1 } & IR>(), 'k'); }
  f(e: { a: 1 } & IR) { this.l.log(e); }
}
