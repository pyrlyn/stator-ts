function isThenable<T>(value: T | Promise<T>): value is Promise<T> {
	return typeof value === 'object' && value !== null && 'then' in value && typeof value.then === 'function';
}
interface Tr<S> { create?: () => S; handle?: (ctx: number, s: S) => boolean }
declare function auto<S>(o: { tracker: Tr<S> }, fn: (r: number, s: S) => void): void;
export function t2<D>() {
  auto({ tracker: { create: () => ({ deltas: [] as D[], did: false }), handle: (ctx, s) => { s.deltas.length; s.did = true; return true; } } }, (r, s) => { s.did; });
}
export type CW = Window & typeof globalThis & { readonly id: number };
export function t3(w: Window) { const cw = w as Partial<CW>; return cw.id; }
type Val<T> = T;
type EK<T> = Partial<{ [K in keyof T]: T[K] extends Function ? never : T[K] extends object ? EK<T[K]> : Val<number | T[K] | undefined | null> }>;
export function t4(attributes: EK<HTMLElement>) {
  for (const [key, value] of Object.entries(attributes)) {
    if (key === 'style') {
      for (const [cssKey, cssValue] of Object.entries(value)) { }
    }
    const n: number = value;
  }
}
declare function findLast<T>(a: T[], p: (x: T) => boolean): T | undefined;
export function t5(diffs: { a: number }[], up: boolean) {
  let diff: { a: number } | undefined;
  if (up) { diff = diffs.find(d => d.a > 1) ?? diffs[0]; } else { diff = findLast(diffs, d => d.a < 2) ?? diffs[diffs.length - 1]; }
  return diff.a;
}
export function t6(g: any, channelId: string) {
  (g.x ?? (g.x = {}))[channelId] = (host) => { return host; };
}
interface GG { $$ch?: Record<string, (host: number) => void> }
export function t7(g: GG, channelId: string) {
  (g.$$ch ?? (g.$$ch = {}))[channelId] = (host) => { return host; };
}
