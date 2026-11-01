interface CP<T> extends Promise<T> { cancel(): void }
declare function mk<T>(f: (t: number) => Promise<T>): CP<T>;
function timeout(m: number): CP<void>;
function timeout(m: number, t: string): Promise<void>;
function timeout(m: number, t?: string): CP<void> | Promise<void> {
	if (!t) {
		return mk(x => timeout(x, 'a'));
	}
	return new Promise((resolve, reject) => {
		setTimeout(() => {
			resolve();
		}, m);
	});
}
interface Bind { item: string }
interface Tmpl<B extends Bind> { bind(i: string, o: { f: (x: number) => void }): B; cur(): B | undefined }
function mkb<TB extends Bind>(t: Tmpl<TB>, ctx?: { run(x: number): void }) {
	let nb: TB | undefined;
	try {
		nb = t.bind('a', {
			f: (x) => {
				if (!ctx) { throw new Error('x'); }
				ctx.run(x);
			},
		});
		if (nb.item !== 'a' || t.cur() !== nb) {
			throw new Error('y');
		}
	} catch (e) {
		throw e;
	}
	return nb.item;
}
declare const kk: string[];
declare const ok: boolean;
const changed = ok ? kk.filter(k => k) : (o => kk.filter(k => !o.has(k)))(new Set(['a'].flatMap(l => Object.keys(l))));
const n1: number = changed;
const iife = (a => { const x: boolean = a; return a; })(1);
const iife2 = ((a, b) => { const x: boolean = b; return a; })('a');
const iife3 = ((...a) => { const x: boolean = a; return a; })('a', 2);
class W {
	h = new Map<string, Set<{ p: number }>>();
	async wait(id: string): Promise<void> {
		let turns: Set<{ p: number }> | undefined;
		while ((turns = this.h.get(id))?.size) {
			await Promise.all([...turns].map(t => t.p));
		}
		let u: string | undefined;
		if ((u = this.h.get(id)?.size ? 'a' : undefined)?.length) {
			const z: number = u;
		}
	}
}
