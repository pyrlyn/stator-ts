import { lib } from './b';
export const C = { ...lib, y: 1 };
export function f1(x: { main?: unknown; d?: string }) {
  let main: string | undefined;
  if (x.d) { main = x.d; } else {
    main = typeof x.main === 'string' ? x.main : undefined;
  }
  if (!main) { main = 'index.js'; }
  if (!main.endsWith('.js')) { main += '.js'; }
  return main.endsWith('.mjs');
}
export function f2(parent: Node, children: Node[]) {
  let cursor = parent.firstChild;
  for (const child of children) {
    if (cursor === child) { cursor = cursor.nextSibling; } else { parent.insertBefore(child, cursor); }
  }
}
export function f3(o: Record<string, string | number | undefined>, q: { [k: string]: boolean }) {
  for (const [k, v] of Object.entries(o)) { v?.toString(); k.length; }
  for (const [k, v] of Object.entries({ a: 1, b: 'x' })) { v.toString(); }
  for (const [k, v] of Object.entries(q)) { v.valueOf(); }
}
export abstract class N<T> { constructor(public x: T) {} }
export class W<T extends string = string> extends N<T> { }
export function mk<T extends string>(t: T) { return new W(t); }
class I { private s = 0; protected a = 1; toggles: { w(): number }[] = []; go() { return 1 + this.toggles.reduce((r, t) => r + t.w(), 0); } }
export const i = new I()['s'];
export function nb(a: boolean) { let vis: number; if (a) vis = 1; return vis!; }
const enum E { A, B, C }
class St { private _s = E.A; go() { this.ini(); if (this._s === E.C) return 1; return 2; } ini() { this._s = E.B; } }
const enc = { '437': 'x', '850': 'y' };
export const ks = Object.keys(enc) as Array<keyof typeof enc>;
const ob = { hook(a: string) {}, res(spec: string, ctx: { z: number }) { } };
interface H { resolve?(spec: string, ctx: number, next: (a: string) => void): void; }
const hk: H = { resolve(s, c, n) { n(s); } };
function reg(h: H | string) {}
reg({ resolve(s, c, n) { n(s); } });
declare class Em<T> { fire(e: T): void; }
new Em<void>().fire();
interface Ob<T, C = void> { set(v: T, tx: number | undefined, c: C): void }
declare const ob2: Ob<boolean>; ob2.set(true, undefined);
function aw<T>(p: Promise<T>) { return (async () => { const v = await p; const w = await v; return w; })(); }
export async function ms() { const m = JSON.parse(process.env['X'] ?? ''); return m; }
