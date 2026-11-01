export const a1 = a1;
export const a2 = [a2];
export const a3 = { x: a3 };
export const a4 = { f: () => a4 };
export const a5 = { f() { return a5; } };
export let a6 = function () { return a6; };
export const a7 = [1].map((x) => a7);
export const a8 = [1].map(function (x) { return a8; });
export function id<T>(x: T) { return x; }
export const a9 = id(() => a9);
export const a10 = id(a10);
export var v1: typeof v1;
export function an1(): ReturnType<typeof an1> { return an1(); }
export class K {
	s: typeof this.s;
	get g() { return this.g; }
	get h() { return this.i; }
	get i() { return this.h; }
	m() { return this.m(); }
	n() { return this.o(); }
	o() { return this.n(); }
	w = () => this.w();
}
export const ob = {
	x() { return ob.y(); },
	y() { return ob.x(); },
	get z() { return ob.z; },
	u: () => ob.u(),
};
export const anon = (function () { return anon2(); });
function anon2() { return anon(); }
export function gen() { return gen; }
export function gen2() { return [gen2]; }
export function ga<T>(x: T) { return ga(x); }
export function gb<T>(x: T) { return [gb(x)]; }
export function gc<T>(x: T) { return gd(x); }
export function gd<T>(x: T) { return gc(x); }
export async function as1() { return await as1(); }
export async function as2() { return [await as2()]; }
export function* g1() { yield* g1(); }
export const cb = (f: () => void) => f;
export const c1 = cb(() => c1);
export const tern: number = tern;
export function narrowed(x: unknown) { let y = x; y = y; return y; }
let lp = 0;
for (let i = 0; i < 3; i++) { const z = lp; lp = z + 1; }
export function looper() { let t = 1; while (t) { const u = t; t = u - 1; } return t; }
export function closure() { const f = () => g(); const g = () => f(); return f; }
export function closure2() { const f = () => { return f; }; return f; }
export function overl(x: string): string;
export function overl(x: number): number;
export function overl(x: any) { return overl(x); }
