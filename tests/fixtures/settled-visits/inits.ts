export {};

declare function pick<T>(a: T, b: T): T;

// The search for the return type of `ending` reads `before` for its effects, in silence, and that
// reads the variables below before their own turn, whose errors must still come.
const read = ending();
function ending() {
	before();
}
function before() {
	return later.length + quietly.length + owing + early();
}
const later = [1].map(x => {
	const s: string = x;
	return s;
});
const quietly = pick([1], ["a"]);
const early = pick(() => {
	const s: string = 3;
	return 1;
}, () => 2);
declare function plain(n: number): number;
const owing = pick(plain("no"), 1);

// With an annotation, the turn of the declaration still relates the initializer.
const typed: string = [1].map(x => x + 1);

// A name that only reaches itself through a body deferred until later has no cycle.
const a = () => b;
const b = pick(1, 2);

class Node_ {
	constructor(public next: { run(f: (n: number) => unknown): void }, public size = 0) {}
	grow(n: Node_, by: number) {
		return n.size + by;
	}
	add(view: Node_["next"]) {
		const seen = view.run(n => this.grow(item, n));
		const item = new Node_(view);
		return item;
	}
}
