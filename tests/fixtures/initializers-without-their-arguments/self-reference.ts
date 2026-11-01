declare function user(config: number): { a: number };
class C { count = 0; constructor(public read: () => { a: number }) { } }
class V { count = 0; constructor(public read: () => void) { } }
declare function wrap(f: () => { a: number }): C2;
declare function wrapG<T>(f: () => T): C2;
export function f() {
	const c1 = new C2(() => ({ a: c1.count }));
	const c2 = new C2(() => user(c2.count));
	const c3 = new C2(() => { return user(c3.count); });
	const c4 = wrap(() => user(c4.count));
	const c5 = new V(() => user(c5.count));
	const c6 = new C2(() => ({ a: user(c6.count).a }));
	const c7 = new C2(() => user(1) && { a: c7.count });
	const c8 = (function () { return new C2(() => user(c8.count)); })();
	const c9 = wrapG(() => user(c9.count));
	const c10 = new C2(function () { return user(c10.count); });
	return [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10];
}
export const k2 = new C2(() => user(k2.count));
export const k3 = new C2(() => ({ a: k3.count }));
