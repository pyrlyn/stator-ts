// Each block pins one narrowing or relation rule of tsc that the checker got wrong once.

// A `switch` on an optional chain removes `undefined` from the base once a case matched.
type Leaf = { kind?: 'a' | 'b' };
function switchChain(o: Leaf | undefined) {
	switch (o?.kind) {
		case 'a':
			o.kind;
			break;
		case 'b':
			o.kind;
			break;
	}
}

// `typeof x === 'object'` on a type parameter implies `object`, null is excluded by the check below.
function typeofObject<T>(x: T) {
	if (typeof x === 'object' && x !== null) {
		const o: object = x;
		return o;
	}
	return undefined;
}

// `in` filters every member of the union, also the non-object ones through their apparent type.
function inOnUnion(x: string[] | { size: number }) {
	if ('size' in x) {
		x.size;
	} else {
		x.length;
	}
}

// Comparability skips the weak type check unless the source is a unit type.
interface Weak { a?: string; b?: number }
declare const other: { c: boolean };
function weak(w: Weak) {
	return w === (other as Weak | { c: boolean });
}

// Mapped types are never empty, and an index signature makes an object type non-empty.
function emptiness(m: Partial<Record<'a', string>>, ix: { [k: string]: string }) {
	if (m) m.a;
	if (ix) ix.b;
}

// An access of a generic mapped type substitutes the template.
function mappedAccess<T, K extends keyof T>(m: { [P in keyof T]: T[P] | undefined }, k: K) {
	const v: T[K] | undefined = m[k];
	return v;
}

// `r?.ok` proves `r` present and then still discriminates it.
type Outcome = { ok: true; value: string[] } | { ok: false; error: string };
function chainDiscriminant(r: Outcome | undefined) {
	return r?.ok ? r.value : [];
}

// `typeof globalThis` lists `var`s only.
var hostVar = 1;
const seen = globalThis.hostVar;
