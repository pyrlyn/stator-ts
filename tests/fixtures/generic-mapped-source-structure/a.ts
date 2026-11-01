type Value<T> = T | { read(): T };
type Attrs<T> = Partial<{
	[K in keyof T]: T[K] extends Function ? never : T[K] extends object ? Attrs<T[K]> : Value<number | T[K] | undefined | null>;
}>;
type Plain<T> = { [K in keyof T]: T[K] };
type PlainP<T> = { [K in keyof T]?: T[K] };
class N<T extends HTMLElement | SVGElement> {
	constructor(attributes: Attrs<T>, plain: Plain<T>, p2: PlainP<T>, p3: Partial<T>, r: Readonly<T>) {
		const e1 = Object.entries(attributes);
		const zz1: "zz" = e1;
		const e2 = Object.entries(plain);
		const zz2: "zz" = e2;
		const e3 = Object.entries(p2);
		const zz3: "zz" = e3;
		const e4 = Object.entries(p3);
		const zz4: "zz" = e4;
		const e5 = Object.entries(r);
		const zz5: "zz" = e5;
	}
}
function f<T extends { a: number }>(m: Plain<T>, k: Partial<T>) {
	const e1 = Object.entries(m);
	const zz1: "zz" = e1;
	const e2 = Object.entries(k);
	const zz2: "zz" = e2;
	const v1 = Object.values(m);
	const zz3: "zz" = v1;
	const s: { [x: string]: number } = m;
	const u: { [x: string]: unknown } = m;
	const u2: { [x: string]: unknown } = k;
}
function g1<T>(m: Plain<T>) { const e = Object.entries(m); const zz: "zz" = e; }
function g2<T extends object>(m: Plain<T>) { const e = Object.entries(m); const zz: "zz" = e; }
function g3<T extends { a: number }>(m: Plain<T>) {
	const a: { a: number } = m;
	const b: { b: number } = m;
	const c: { a: string } = m;
	const o: { a?: string } = m;
	const o2: { b?: string } = m;
	const arr: ArrayLike<number> = m;
}
function g4<T extends { a: number }>(m: Partial<T>) {
	const a: { a: number } = m;
	const b: { a?: number } = m;
	const u: { a: number | undefined } = m;
}
function g5<T extends number[]>(m: Plain<T>) {
	const a: number[] = m;
	const l: { length: number } = m;
}
function g6<T extends { a: number }, K extends "a">(p: Pick<T, K>) {
	const x: { a: number } = p;
	const y: { [s: string]: unknown } = p;
	const z: { [s: string]: number } = p;
}
function g7<T>(m: Record<keyof T, number>) {
	const r: { [s: string]: number } = m;
	const r2: { [s: string]: string } = m;
}
function g8<K extends string>(m: Record<K, number>) {
	const r: { [s: string]: number } = m;
	const r2: { [s: string]: string } = m;
	const e = Object.entries(m);
	const zz: "zz" = e;
}
function r1<T extends Record<string, number>>(v: T[keyof T]) { const n: number = v; }
function r2<T extends { [k: string]: string; a: "x" }>(v: T[keyof T]) { const n: string = v; }
function r3<T extends string[]>(v: T[keyof T]) { const n: unknown = v; }
