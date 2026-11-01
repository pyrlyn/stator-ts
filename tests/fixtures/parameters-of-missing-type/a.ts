export {};
type F = Parameters<Electron.Session['a']>[0];
declare const f0: F;
const f1: number = f0;
type P0 = Parameters<any>;
const p0: number = null! as P0;
type P1 = Parameters<Electron.Session['a']>;
const p1: number = null! as P1;
type NN = NonNullable<F>;
const nn: number = null! as NN;
type G = Parameters<NonNullable<F>>[0];
const g: number = null! as G;
declare const fn: F;
fn!();
declare const sp: G;
const o = { a: 1, ...sp };
declare const sp2: unknown;
const o2 = { a: 1, ...sp2 };
declare const sp3: {};
const o3 = { a: 1, ...sp3 };
class A extends (null! as new () => Electron.Session) {
	override a() {}
}
