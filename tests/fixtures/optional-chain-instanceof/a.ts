class A { kind = 'a'; }
class B { other = 1; }

export function f(p: { root: A | B } | undefined) {
	if (p?.root instanceof A && p.root.kind) {
		return p.root.kind;
	}
	// A real error: outside the check `p` may be missing.
	return p.root;
}
