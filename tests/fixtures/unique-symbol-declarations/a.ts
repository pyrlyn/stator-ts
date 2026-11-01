// `const K = Symbol()` has a type of its own, so comparing against it removes it from a union.
const NO = Symbol('no');
let slot: string | undefined | typeof NO;
declare function use(s: string): void;
if (slot !== NO) {
	if (slot !== undefined) {
		use(slot);
	}
}
class K { static readonly S = Symbol('s'); }
declare const ks: string | typeof K.S;
if (ks !== K.S) use(ks);

// Copying it to anything mutable widens it again.
let y = NO;
y = Symbol('x');
const o = { a: NO };
o.a = Symbol('y');
