enum V { S, M, L }
class Fn<K, R> { constructor(public fn: (k: K) => R) { } get(k: K): R { return this.fn(k); } }
declare function strip(u: string): string;
export class B {
	url = 'x';
	name() { return this.titles.get(this.url)[V.S]; }
	private readonly titles = new Fn((url: string) => {
		let _s: string | undefined = undefined;
		let _m: string | undefined = undefined;
		const m = () => {
			if (_m === undefined) { _m = strip(url); }
			return _m;
		};
		return {
			get [V.S]() {
				if (_s === undefined) { _s = strip(url); }
				return _s;
			},
			get [V.M]() { return m(); },
			get [V.L]() { return m(); },
		};
	});
}
