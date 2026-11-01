// A fresh `{}` is closed under subtyping: the declared type wins whatever the order.
interface Meta { cost?: number; latest?: { a: number } }
declare function pair<T>(a: T, b: T): T;
declare function rd(): Meta;
declare function matrix<T>(title: string, read: (meta: string) => T, absent: T, cases: { name: string; expected: T }[]): T;
declare const m: Meta;

const r1 = matrix('u', x => rd(), {}, [
	{ name: 'a', expected: { cost: 0 } },
	{ name: 'b', expected: { latest: { a: 1 } } },
	{ name: 'c', expected: {} },
]);
const n1: number = r1;
const n3: number = pair(m, {});
const n4: number = pair({}, m);
const n5: number = pair({ cost: 1 }, m);
const n6: number = pair({}, { cost: 1 });

// A type parameter goes by its constraint, which relates to `{}`.
function make<T extends object>(handler: { get(target: T): unknown }): T {
	const raw = new Proxy({}, { get(_target: T, key: PropertyKey) { return handler.get(_target); } });
	return raw as T;
}
