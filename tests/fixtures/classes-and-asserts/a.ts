import assert from 'assert';
export interface I { m?(): number; p?: () => string; }
export class Impl implements I { m(): number { return 1; } p() { return ''; } }
export const a1: I = new Impl();
export function useI(i: I) { return i; }
useI(new Impl());
export interface IReq { m(): number | undefined }
const opt: I = {};
if (opt.m) { const r: number = opt.m(); void r; }

// aliased condition
export class Box { count = 1; items: string[] = []; }
export function al(state: Box | undefined): number {
	const isVisible = !!state && state.count > 0;
	if (!isVisible) { return 0; }
	return state.items.length;
}

// exhaustive switch
export enum Dir { H, V }
export function sw(d: Dir) {
	let keys: number[];
	switch (d) {
		case Dir.H: keys = [1]; break;
		case Dir.V: keys = [2]; break;
	}
	return keys.length;
}
export function sw2(d: 'a' | 'b'): number {
	switch (d) {
		case 'a': return 1;
		case 'b': return 2;
	}
}

// assertions
export function ass(x: { y: number } | undefined | null) {
	assert.ok(x);
	return x.y;
}
export function ass2(x: { y: number } | undefined) {
	assert(x);
	return x.y;
}
export function ass3(x: { y: number } | undefined) {
	assert.ok(x?.y);
	return x.y;
}
export function ass4(x: { y: number } | undefined) {
	assert.strictEqual(x, undefined);
	return x;
}

// any and Object predicate
declare function isObject(o: unknown): o is Object;
export function ob(obj: any) {
	if (isObject(obj)) {
		for (const k in obj) { return obj[k]; }
	}
}

// optional chain discriminant
type Tok = { type: 'text'; text: string } | { type: 'br' };
export function oc(ts: Tok[]) {
	const f = ts[0] as Tok | undefined;
	if (f?.type !== 'text') { return ''; }
	return f.text;
}

// equality with non-literal removes null
export function eq(parent: { first: { next: object | null } | null }, child: { next: object | null }) {
	let cur = parent.first;
	if (cur === child) { cur = cur.next as any; }
}

// string enum
export enum Prov { Local = 'local', Remote = 'remote' }
export function se(p: Prov): string { const s: string = p; return s; }
export function se2(p: Prov, q: string) { return p === q; }
export function se3(p: Prov) { return p !== 'local'; }
const sm = new Map<string, number>();
sm.set(Prov.Local, 1);
export function se4(p: Prov) { return sm.get(p); }
export function se5(x: { k: 'local' | 'remote' }) { const s: 'local' | 'remote' = Prov.Local; x.k = s; }

// overload with lambdas in an object
interface V { left(s: number): number; h?: string }
interface H { top(s: number): number; w?: string }
declare class Sash { constructor(c: string, v: V, o: { o: Dir.V }); constructor(c: string, h: H, o: { o: Dir.H }); }
export const opts = { z: 1 };
export const s1 = new Sash('', { top: s => s + 1 }, { ...opts, o: Dir.H });
export const s2 = new Sash('', { left: s => s + 1 }, { ...opts, o: Dir.V });

// inferred predicate
export const fl = [1, undefined, 2].filter(x => x !== undefined).map(x => x + 1);
export const fl2 = ['a', null].filter(x => !!x).map(x => x.length);
export const fd = [1, undefined].find(x => x !== undefined);

// Pick and optional
interface Inp { resource: string; label?: string; desc?: string }
type P1 = Pick<Inp, 'resource' | 'label'>;
export const p1: P1 = { resource: '' };
type O1 = Omit<Inp, 'desc'>;
export const o1: O1 = { resource: '' };
type U1 = Omit<Inp | { other: 1 }, 'desc'>;
type Fn<T> = { [K in keyof T]?: T[K] };
export const f1: Fn<Inp> = {};
export type { U1 };
