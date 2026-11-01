class Base<T, F = void> {
	constructor(readonly v: T[], readonly f: (x: T) => F, readonly o?: { p: T }) {}
}
class Group { g = 1; }
class Sub extends Group { s = 1; }
const groupOpts: { p: Group } = { p: new Group() };
class Tree extends Base<Sub> {
	constructor() {
		super([new Sub()], () => undefined, { p: new Sub() });
	}
}
class Wrong extends Base<Sub> {
	constructor() {
		super([new Group()], () => undefined, groupOpts);
	}
}
class Dflt<T = string> {
	constructor(x: T) {}
}
class D1 extends Dflt {
	constructor() { super(1); }
}
class D2 extends Dflt<number> {
	constructor() { super(1); }
}
class D3 extends Dflt<number> {
	constructor() { super(""); }
}
class Pair<A, B = A[]> { constructor(a: A, b: B) {} }
class P1 extends Pair<number> {
	constructor() { super(1, [2]); }
}
class P2 extends Pair<number> {
	constructor() { super(1, ["x"]); }
}
