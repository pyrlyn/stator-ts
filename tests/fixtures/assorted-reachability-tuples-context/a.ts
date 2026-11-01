// tuple or array out of a ternary in a destructuring
interface D { a: 1 }
declare const chunks: (D | [D, number])[];
for (const item of chunks) {
	const [p, h] = Array.isArray(item) ? item : [item];
	const q: D = p;
	const r: string = h;
}

// assert(false) ends the flow
declare function ok(value: unknown): asserts value;
declare function fin(): never;
class P { constructor(f: () => Promise<number>) { } }
new P(() => { ok(false); });
new P(() => { ok(0); });
new P(() => { fin(); });
function nr(): number { ok(false); }
function nr2(): number { ok(null); }

// intersection of optional properties
interface J { oneOf?: J[]; snip?: S[]; props?: { [k: string]: J } }
interface S { body?: string }
interface W extends J { snip: S[] }
type C = J & { props: { [n: string]: { oneOf: [W, J] } } };
declare const cs: C;
declare const k: string;
cs.props[k].oneOf[0].snip[0].body = 'x';

// the static side of a mixin is also the base
type Ctor<T> = new (...args: any[]) => T;
class Base { b = 1; }
function mix<TBase extends Ctor<Base>>(B: TBase): TBase {
	return class X extends B {
		x = 1;
	};
}

// typeof on a discriminant
type E = { ok: true; i: number } | { ok: false; i: undefined };
declare const es: E[];
const fine: { i: number }[] = es.filter(x => typeof x.i === 'number');
for (const e of es) if (typeof e.i === 'number') { const t: true = e.ok; }

// predicates infer
interface Def<T> { is(v: unknown): v is T; run(p: T): void }
declare function reg<T>(d: Def<T>): void;
function w<T, U extends Def<T>>(l: U) {
	reg({
		is: (v): v is T => l.is(v),
		run: p => l.run(p),
	});
}

// earlier lambdas of a literal count for later ones
class MI { id = ''; n = 0; }
interface Inf { id: string }
interface Prov<I extends Inf> { get(r: number): I[]; make(i: I, t: string): I }
declare class G<I extends Inf = Inf> { constructor(a: number, p: Prov<I>); it: I }
declare const mis: MI[];
declare function mk(i: MI, t: string): MI;
const g = new G(1, {
	get: r => mis,
	make: (i, t) => mk(i, t),
});
const gi: number = g.it;

// parameters past the context
type Fac = (a: string, b: number, c?: boolean, d?: string) => void;
function fac({ f = (a, b, c, d) => { const s: number = d; }, d }: { f?: Fac; d?: number } = {}) { }
